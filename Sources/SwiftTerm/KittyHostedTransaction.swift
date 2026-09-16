//
//  KittyHostedTransaction.swift
//  SwiftTerm
//
//  Two-phase hosted Kitty graphics transaction.
//
//  Hosted renderers (for example a daemon-backed terminal whose bytes arrive
//  from another process) feed the terminal on the main thread, so the legacy
//  inline path synchronously decodes payloads and rasterizes image stripes
//  while the event loop cannot process input. This file adds a narrow, opt-in
//  alternative that keeps every terminal/view mutation on the calling (main)
//  thread while moving payload decode, scaling, and stripe slicing to any
//  background executor:
//
//  Phase 1 (calling thread, typically main): the parser records
//  cursor-anchored placement, attaches headless placeholder rows, advances
//  the cursor exactly like the inline path, and enqueues an immutable
//  `HostedKittyRenderRequest`. The ticket captures every piece of
//  terminal/view geometry preparation needs (cell pixels, anchor, crops), so
//  preparation never consults terminal or view state. No image bytes are
//  decoded and no stripes are created.
//
//  Phase 2 (any thread): `prepareHostedKittyRender` validates admission
//  limits, decodes the payload, and rasterizes the fully scaled canvas plus
//  one bounded RGBA stripe buffer per placement row. It never touches
//  `Terminal`, buffers, delegates, or views. Stripe byte cost is carried in
//  the prepared value so installation can pre-admit rendered memory.
//
//  Phase 3 (calling thread): `Terminal.installHostedKittyPreparedImages`
//  atomically validates epoch, placement survival, and source-plus-rendered
//  cache admission, commits payloads, and asks the delegate to build view
//  objects from the precomputed stripe bytes. The delegate performs AppKit
//  object creation, placeholder validation, and attachment only: no
//  PNG-decode, scaling, or stripe generation runs on the install path.
//
//  The legacy inline path is unchanged and remains the default. Set
//  `TerminalOptions.hostedKittyTwoPhaseRendering` to opt a terminal in.
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Admission limits for two-phase hosted Kitty graphics work.
public struct HostedKittyGraphicsLimits: Sendable, Equatable {
    /// Maximum accepted size of one decoded payload, in bytes. Defaults to
    /// 8 MiB to align with bounded authoritative-graphics transfer budgets.
    public var maxPayloadBytes: Int
    /// Maximum accepted decoded image dimension, in pixels per side.
    public var maxImageDimension: Int
    /// Maximum accepted placement area, in cells. Bounds parse-time line
    /// creation so a hostile `c=`/`r=` pair cannot stall the calling thread.
    public var maxPlacementCells: Int
    /// Maximum base64 bytes accumulated for one chunked (`m=1`) transfer, and
    /// the ingress bound for any single complete ticket. Defaults to 12 MiB
    /// (8 MiB payload at 4/3 base64 expansion plus margin).
    public var maxPartialEncodedBytes: Int
    /// Maximum completed decode tickets queued inside the terminal.
    public var maxPendingJobs: Int
    /// Maximum total base64 bytes held by completed decode tickets.
    public var maxPendingBytes: Int
    /// Maximum aggregate source-plus-rendered bytes retained across one
    /// prepared batch (`prepareHostedKittyBatch`). Checked with overflow-safe
    /// arithmetic before the batch result is retained.
    public var maxPreparedBatchBytes: Int
    /// Maximum live anonymous (untagged `a=T` without `i=`/`I=`) placements.
    /// Anonymous placements cannot be addressed for deletion, so the oldest
    /// is evicted past this bound to keep the lifecycle strictly bounded.
    public var maxAnonymousPlacements: Int
    /// Maximum live placement records. Scrollback-dead records are reaped
    /// first; past the cap, records without surviving line presence
    /// (virtual/store-only) are evicted oldest-first. Line-backed records
    /// are never torn: admission fails instead.
    public var maxHostedPlacements: Int

    public init(maxPayloadBytes: Int = 8 * 1024 * 1024,
                maxImageDimension: Int = 10000,
                maxPlacementCells: Int = 65536,
                maxPartialEncodedBytes: Int = 12 * 1024 * 1024,
                maxPendingJobs: Int = 32,
                maxPendingBytes: Int = 64 * 1024 * 1024,
                maxPreparedBatchBytes: Int = 64 * 1024 * 1024,
                maxAnonymousPlacements: Int = 16,
                maxHostedPlacements: Int = 1024) {
        self.maxPayloadBytes = maxPayloadBytes
        self.maxImageDimension = maxImageDimension
        self.maxPlacementCells = maxPlacementCells
        self.maxPartialEncodedBytes = maxPartialEncodedBytes
        self.maxPendingJobs = maxPendingJobs
        self.maxPendingBytes = maxPendingBytes
        self.maxPreparedBatchBytes = maxPreparedBatchBytes
        self.maxAnonymousPlacements = maxAnonymousPlacements
        self.maxHostedPlacements = maxHostedPlacements
    }

    public static let `default` = HostedKittyGraphicsLimits()
}

/// Immutable decode work produced by the parser for one displayed image.
/// Carries no terminal, buffer, delegate, or view references and is safe to
/// move across threads. All geometry preparation needs (cell pixels, anchor,
/// crops) is captured here on the feeding thread.
public struct HostedKittyRenderRequest: Sendable, Equatable {
    /// Value of `Terminal.hostedGraphicsEpoch` when the parser recorded this
    /// placement. Install rejects the request when the epoch moved.
    public var epoch: UInt64
    /// Value of `buffer.linesTop` when the parser recorded the placement.
    /// Combined with the surviving placeholder lines, this anchors stripe
    /// indices exactly even when scrollback trimming moved the buffer.
    public var originLinesTop: Int
    public var imageId: UInt32
    public var imageNumber: UInt32?
    public var placementId: UInt32
    public var columns: Int
    public var rows: Int
    public var zIndex: Int
    public var pixelOffsetX: Int
    public var pixelOffsetY: Int
    /// Kitty `f=` format (100 = PNG, 24/32 = raw RGB/RGBA).
    public var format: Int
    /// Kitty `s=`/`v=` raw dimensions. Meaningful only for raw formats.
    public var rawWidth: Int
    public var rawHeight: Int
    public var compression: Character?
    /// Raw base64 payload bytes exactly as received in the APC sequence.
    /// Base64 decoding and decompression happen in `prepare`, off-thread.
    public var base64Payload: [UInt8]
    public var isAlternateBuffer: Bool
    /// View cell size in pixels captured on the feeding thread. Nil for
    /// headless terminals (no delegate cell size): preparation then produces
    /// a validated source raster with no stripes, which the headless delegate
    /// accepts without rendering.
    public var cellWidthPx: Int?
    public var cellHeightPx: Int?
    /// Parse-time placement anchor: column and absolute row
    /// (`buffer.y + buffer.yBase`) of the placement origin. Used for stripe
    /// attachment and for rebuilding placeholders if an install rolls back.
    public var anchorCol: Int
    public var anchorRow: Int
    /// Kitty `U=` virtual (unicode placeholder) display: no rows, no stripes;
    /// preparation only decodes and validates the stored payload.
    public var isVirtual: Bool
    /// Anonymous display (`a=T` with neither `i=` nor `I=`): an ephemeral
    /// internal image id backs the placement, but install stores no payload
    /// and the parser sends no reply, matching the inline path.
    public var isAnonymous: Bool
    /// Kitty crop rectangle (`x=`, `y=`, `w=`, `h=`). Applied to the decoded
    /// RGBA in `prepare`. All zeros means no crop.
    public var cropX: Int
    public var cropY: Int
    public var cropWidth: Int
    public var cropHeight: Int
    /// Parent linkage for relative placements. The origin is resolved to
    /// `anchorCol`/`anchorRow` at parse time; these fields are retained so
    /// the committed placement record preserves relative-update behavior.
    public var parentImageId: UInt32?
    public var parentPlacementId: UInt32?
    public var parentOffsetH: Int
    public var parentOffsetV: Int
    /// Feeding-thread timestamp used for oldest-job-age queue metrics.
    public var enqueuedAt: Date

    public init(epoch: UInt64,
                originLinesTop: Int,
                imageId: UInt32,
                imageNumber: UInt32?,
                placementId: UInt32,
                columns: Int,
                rows: Int,
                zIndex: Int,
                pixelOffsetX: Int,
                pixelOffsetY: Int,
                format: Int,
                rawWidth: Int,
                rawHeight: Int,
                compression: Character?,
                base64Payload: [UInt8],
                isAlternateBuffer: Bool,
                cellWidthPx: Int? = nil,
                cellHeightPx: Int? = nil,
                anchorCol: Int = 0,
                anchorRow: Int = 0,
                isVirtual: Bool = false,
                isAnonymous: Bool = false,
                cropX: Int = 0,
                cropY: Int = 0,
                cropWidth: Int = 0,
                cropHeight: Int = 0,
                parentImageId: UInt32? = nil,
                parentPlacementId: UInt32? = nil,
                parentOffsetH: Int = 0,
                parentOffsetV: Int = 0,
                enqueuedAt: Date = Date()) {
        self.epoch = epoch
        self.originLinesTop = originLinesTop
        self.imageId = imageId
        self.imageNumber = imageNumber
        self.placementId = placementId
        self.columns = columns
        self.rows = rows
        self.zIndex = zIndex
        self.pixelOffsetX = pixelOffsetX
        self.pixelOffsetY = pixelOffsetY
        self.format = format
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.compression = compression
        self.base64Payload = base64Payload
        self.isAlternateBuffer = isAlternateBuffer
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.anchorCol = anchorCol
        self.anchorRow = anchorRow
        self.isVirtual = isVirtual
        self.isAnonymous = isAnonymous
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.parentImageId = parentImageId
        self.parentPlacementId = parentPlacementId
        self.parentOffsetH = parentOffsetH
        self.parentOffsetV = parentOffsetV
        self.enqueuedAt = enqueuedAt
    }
}

/// One precomputed placement-row stripe: a slice of the fully scaled canvas,
/// exactly `cellHeightPx` tall and `scaledWidth` wide. The install path builds
/// view objects directly from these bytes without scaling or slicing.
public struct HostedKittyPreparedStripe: Sendable, Equatable {
    /// Zero-based stripe index (0 is the placement's first row).
    public var stripeIndex: Int
    public var width: Int
    public var height: Int
    /// Premultiplied-last RGBA bytes, `width * height * 4` long.
    public var rgba: Data

    public init(stripeIndex: Int, width: Int, height: Int, rgba: Data) {
        self.stripeIndex = stripeIndex
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// A fully validated, rasterized image ready for main-thread installation.
/// Still carries no terminal or view references. Stripes are precomputed, so
/// installation is a short commit: validate, store, attach.
public struct HostedKittyPreparedImage: Sendable, Equatable {
    public var epoch: UInt64
    public var originLinesTop: Int
    public var imageId: UInt32
    public var imageNumber: UInt32?
    public var placementId: UInt32
    public var columns: Int
    public var rows: Int
    public var zIndex: Int
    public var pixelOffsetX: Int
    public var pixelOffsetY: Int
    /// Decoded (and cropped) source raster, premultiplied-last RGBA.
    public var rgba: Data
    public var width: Int
    public var height: Int
    public var isAlternateBuffer: Bool
    /// Precomputed per-row stripes of the scaled canvas. Empty for virtual or
    /// store-only (zero-grid) placements, and for tickets captured without a
    /// view cell size (headless terminals render no stripes).
    public var stripes: [HostedKittyPreparedStripe]
    /// Scaled canvas size in pixels (`columns * cellWidthPx` by
    /// `rows * cellHeightPx`).
    public var scaledWidth: Int
    public var scaledHeight: Int
    public var cellWidthPx: Int?
    public var cellHeightPx: Int?
    public var anchorCol: Int
    public var anchorRow: Int
    /// Total stripe bytes (`scaledWidth * scaledHeight * 4` when stripes are
    /// present). Pre-admitted at install and tracked with stripe lifecycle.
    public var renderedByteCost: Int
    public var isVirtual: Bool
    public var isAnonymous: Bool
    public var parentImageId: UInt32?
    public var parentPlacementId: UInt32?
    public var parentOffsetH: Int
    public var parentOffsetV: Int

    public init(epoch: UInt64,
                originLinesTop: Int,
                imageId: UInt32,
                imageNumber: UInt32?,
                placementId: UInt32,
                columns: Int,
                rows: Int,
                zIndex: Int,
                pixelOffsetX: Int,
                pixelOffsetY: Int,
                rgba: Data,
                width: Int,
                height: Int,
                isAlternateBuffer: Bool,
                stripes: [HostedKittyPreparedStripe] = [],
                scaledWidth: Int = 0,
                scaledHeight: Int = 0,
                cellWidthPx: Int? = nil,
                cellHeightPx: Int? = nil,
                anchorCol: Int = 0,
                anchorRow: Int = 0,
                renderedByteCost: Int = 0,
                isVirtual: Bool = false,
                isAnonymous: Bool = false,
                parentImageId: UInt32? = nil,
                parentPlacementId: UInt32? = nil,
                parentOffsetH: Int = 0,
                parentOffsetV: Int = 0) {
        self.epoch = epoch
        self.originLinesTop = originLinesTop
        self.imageId = imageId
        self.imageNumber = imageNumber
        self.placementId = placementId
        self.columns = columns
        self.rows = rows
        self.zIndex = zIndex
        self.pixelOffsetX = pixelOffsetX
        self.pixelOffsetY = pixelOffsetY
        self.rgba = rgba
        self.width = width
        self.height = height
        self.isAlternateBuffer = isAlternateBuffer
        self.stripes = stripes
        self.scaledWidth = scaledWidth
        self.scaledHeight = scaledHeight
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.anchorCol = anchorCol
        self.anchorRow = anchorRow
        self.renderedByteCost = renderedByteCost
        self.isVirtual = isVirtual
        self.isAnonymous = isAnonymous
        self.parentImageId = parentImageId
        self.parentPlacementId = parentPlacementId
        self.parentOffsetH = parentOffsetH
        self.parentOffsetV = parentOffsetV
    }
}

/// Terminal-state-free outcome of preparing one hosted graphics request.
public enum HostedKittyPrepareError: Error, Sendable, Equatable {
    case emptyPayload
    case badEncoding
    case unsupportedFormat(Int)
    case unsupportedCompression
    case badDimensions
    case exceedsPayloadLimit(bytes: Int, limit: Int)
    case exceedsRenderedLimit(bytes: Int, limit: Int)
    case exceedsBatchLimit(bytes: Int, limit: Int)
    case undecodableImage
}

/// Subtractive encoded-size admission: true when `additional` bytes fit
/// after `current` within `limit`, with no addition that could trap near
/// `Int.max`. Used before every parser-side copy or append.
func hostedEncodedFits(current: Int, additional: Int, limit: Int) -> Bool {
    guard current >= 0, additional >= 0, limit >= 0, current <= limit else {
        return false
    }
    return additional <= limit - current
}

/// Overflow-saturating queue accounting for untrusted internal lengths.
func hostedSaturatingAdd(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
}

/// Typed admission rejection for two-phase hosted graphics queueing. Returned
/// before any parser or placement mutation, so hosts can implement
/// stop-and-reattach watermarks with exact accounting.
public enum HostedKittyAdmissionRejection: Sendable, Equatable {
    /// One chunked (`m=1`) transfer accumulated more base64 than allowed.
    /// The partial transfer is dropped; nothing is queued.
    case partialTransferTooLarge(bytes: Int, limit: Int)
    /// A complete ticket's estimated decoded size exceeds the payload limit.
    case payloadTooLarge(bytes: Int, limit: Int)
    /// The completed-ticket queue already holds the maximum job count.
    case pendingQueueFull(jobs: Int, limit: Int)
    /// The completed-ticket queue already holds the maximum byte count.
    case pendingQueueBytesFull(bytes: Int, limit: Int)
}

/// Admission verdict for one hosted render request. Checked before image-id
/// assignment, placement registration, placeholder creation, and enqueue.
public enum HostedKittyAdmission: Sendable, Equatable {
    case admitted
    case rejected(HostedKittyAdmissionRejection)
}

/// Point-in-time hosted graphics queue accounting for host watermarks.
public struct HostedKittyQueueMetrics: Sendable, Equatable {
    /// Base64 bytes accumulated in the in-progress chunked transfer (0 when
    /// no partial transfer is open).
    public var partialEncodedBytes: Int
    /// Completed decode tickets waiting for the host to drain.
    public var pendingJobs: Int
    /// Total base64 bytes held by completed decode tickets.
    public var pendingBytes: Int
    /// Age of the oldest queued ticket in seconds. Nil when the queue is
    /// empty.
    public var oldestJobAge: TimeInterval?

    public init(partialEncodedBytes: Int, pendingJobs: Int, pendingBytes: Int, oldestJobAge: TimeInterval?) {
        self.partialEncodedBytes = partialEncodedBytes
        self.pendingJobs = pendingJobs
        self.pendingBytes = pendingBytes
        self.oldestJobAge = oldestJobAge
    }
}

/// Terminal-state-free outcome of installing prepared hosted graphics.
public enum HostedKittyInstallOutcome: Sendable, Equatable {
    /// Every committed placement stored its payload and swapped its
    /// placeholders for precomputed stripes. Duplicate placement keys in one
    /// batch are de-duplicated (last wins); `placements` counts unique
    /// committed placements, including store-only (virtual/zero-grid) items.
    case installed(placements: Int)
    /// Nothing was mutated: the epoch moved, a placement was deleted or
    /// replaced, or the buffer switched. The caller must drop the batch.
    case stale
    /// Nothing was mutated: a prepared raster failed validation, the batch
    /// exceeds the terminal image-cache limit (source plus rendered bytes),
    /// or a stripe attach failed after a full rollback. Placeholders are
    /// restored on attach failure so the caller may retry with a fresh batch.
    case rejected(reason: String)
}

/// Pure, thread-safe preparation of one hosted render request. Never touches
/// `Terminal`, buffers, delegates, or views, so callers may run it on any
/// background executor. Decodes the payload, applies crops, and rasterizes
/// the fully scaled canvas plus one bounded RGBA stripe per placement row.
public func prepareHostedKittyRender(_ request: HostedKittyRenderRequest,
                                     limits: HostedKittyGraphicsLimits = .default) -> Result<HostedKittyPreparedImage, HostedKittyPrepareError> {
    // Zero grids are store-only (headless auto-size, mirroring the inline
    // path which registers nothing without a cell size): decode and validate
    // the payload for storage, but produce no stripes.
    guard request.columns >= 0, request.rows >= 0,
          request.columns <= limits.maxImageDimension,
          request.rows <= limits.maxImageDimension else {
        return .failure(.badDimensions)
    }
    // Checked cell-area product: untrusted ticket geometry must never trap
    // near Int.max (prepare is public API and tickets can be hand-built).
    let (placementCells, cellsOverflow) = request.columns.multipliedReportingOverflow(by: request.rows)
    guard !cellsOverflow, placementCells <= limits.maxPlacementCells else {
        return .failure(.badDimensions)
    }
    guard !request.base64Payload.isEmpty else {
        return .failure(.emptyPayload)
    }
    guard let decoded = Data(base64Encoded: Data(request.base64Payload), options: .ignoreUnknownCharacters) else {
        return .failure(.badEncoding)
    }
    guard decoded.count <= limits.maxPayloadBytes else {
        return .failure(.exceedsPayloadLimit(bytes: decoded.count, limit: limits.maxPayloadBytes))
    }
    let rawData: Data
    if let compression = request.compression {
        guard compression == "z" else {
            return .failure(.unsupportedCompression)
        }
        // Bounded inflation: the cap is enforced while appending, so a
        // hostile sub-limit zlib payload can never expand to gigabytes.
        guard let inflated = HostedKittyImageDecoder.decompressZlib(decoded, maxOutputBytes: limits.maxPayloadBytes),
              inflated.count <= limits.maxPayloadBytes else {
            return .failure(.exceedsPayloadLimit(bytes: Int.max, limit: limits.maxPayloadBytes))
        }
        rawData = inflated
    } else {
        rawData = decoded
    }
    guard rawData.count <= limits.maxPayloadBytes else {
        return .failure(.exceedsPayloadLimit(bytes: rawData.count, limit: limits.maxPayloadBytes))
    }

    let raster: (rgba: Data, width: Int, height: Int)
    switch request.format {
    case 100:
        // Dimensions are verified from the header before any ImageIO decode
        // or RGBA allocation, so a small 10000x10000 header is rejected
        // without allocating its 400MB raster.
        guard let headerSize = HostedKittyImageDecoder.pngPixelSize(data: rawData),
              HostedKittyImageDecoder.validateDimensions(width: headerSize.width, height: headerSize.height, maxDimension: limits.maxImageDimension) else {
            return .failure(.badDimensions)
        }
        let rgbaCost = Int64(headerSize.width) * Int64(headerSize.height) * 4
        guard rgbaCost <= Int64(limits.maxPayloadBytes) else {
            return .failure(.exceedsPayloadLimit(bytes: Int(min(rgbaCost, Int64(Int.max))), limit: limits.maxPayloadBytes))
        }
        guard let decoded = HostedKittyImageDecoder.rasterizePNG(rawData, maxDimension: limits.maxImageDimension, maxRGBABytes: limits.maxPayloadBytes) else {
            return .failure(.undecodableImage)
        }
        raster = decoded
    case 24:
        guard HostedKittyImageDecoder.validateDimensions(width: request.rawWidth, height: request.rawHeight, maxDimension: limits.maxImageDimension) else {
            return .failure(.badDimensions)
        }
        let pixelCount = Int64(request.rawWidth) * Int64(request.rawHeight)
        guard pixelCount * 3 == Int64(rawData.count) else {
            return .failure(.badDimensions)
        }
        // Checked expansion cost before allocating the RGBA buffer.
        guard pixelCount * 4 <= Int64(limits.maxPayloadBytes) else {
            return .failure(.exceedsPayloadLimit(bytes: Int(min(pixelCount * 4, Int64(Int.max))), limit: limits.maxPayloadBytes))
        }
        var rgba = Data(count: Int(pixelCount * 4))
        rgba.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            rawData.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                let db = d.assumingMemoryBound(to: UInt8.self)
                let sb = s.assumingMemoryBound(to: UInt8.self)
                var si = 0
                var di = 0
                while si < rawData.count {
                    db[di] = sb[si]
                    db[di + 1] = sb[si + 1]
                    db[di + 2] = sb[si + 2]
                    db[di + 3] = 255
                    si += 3
                    di += 4
                }
            }
        }
        raster = (rgba, request.rawWidth, request.rawHeight)
    case 32:
        guard HostedKittyImageDecoder.validateDimensions(width: request.rawWidth, height: request.rawHeight, maxDimension: limits.maxImageDimension) else {
            return .failure(.badDimensions)
        }
        guard Int64(request.rawWidth) * Int64(request.rawHeight) * 4 == Int64(rawData.count) else {
            return .failure(.badDimensions)
        }
        raster = (rawData, request.rawWidth, request.rawHeight)
    default:
        return .failure(.unsupportedFormat(request.format))
    }

    var sourceRGBA = raster.rgba
    var sourceWidth = raster.width
    var sourceHeight = raster.height
    if request.cropX != 0 || request.cropY != 0 || request.cropWidth != 0 || request.cropHeight != 0 {
        guard let cropped = HostedKittyImageDecoder.cropRGBA(bytes: sourceRGBA, width: sourceWidth, height: sourceHeight,
                                                             x: request.cropX, y: request.cropY, w: request.cropWidth, h: request.cropHeight) else {
            return .failure(.badDimensions)
        }
        sourceRGBA = cropped.bytes
        sourceWidth = cropped.width
        sourceHeight = cropped.height
    }

    func storeOnly() -> Result<HostedKittyPreparedImage, HostedKittyPrepareError> {
        return .success(HostedKittyPreparedImage(epoch: request.epoch,
                                                 originLinesTop: request.originLinesTop,
                                                 imageId: request.imageId,
                                                 imageNumber: request.imageNumber,
                                                 placementId: request.placementId,
                                                 columns: request.columns,
                                                 rows: request.rows,
                                                 zIndex: request.zIndex,
                                                 pixelOffsetX: request.pixelOffsetX,
                                                 pixelOffsetY: request.pixelOffsetY,
                                                 rgba: sourceRGBA,
                                                 width: sourceWidth,
                                                 height: sourceHeight,
                                                 isAlternateBuffer: request.isAlternateBuffer,
                                                 anchorCol: request.anchorCol,
                                                 anchorRow: request.anchorRow,
                                                 isVirtual: request.isVirtual,
                                                 isAnonymous: request.isAnonymous,
                                                 parentImageId: request.parentImageId,
                                                 parentPlacementId: request.parentPlacementId,
                                                 parentOffsetH: request.parentOffsetH,
                                                 parentOffsetV: request.parentOffsetV))
    }

    // Virtual and zero-grid placements store the payload without stripes.
    if request.isVirtual || request.columns == 0 || request.rows == 0 {
        return storeOnly()
    }
    // Without a captured view cell size (headless terminals) there is no
    // stripe geometry: keep the validated source raster for storage, with no
    // rendered cost. The headless delegate accepts this without rendering.
    guard let cellWidth = request.cellWidthPx, let cellHeight = request.cellHeightPx,
          cellWidth > 0, cellHeight > 0 else {
        return storeOnly()
    }
    // Checked canvas geometry: delegate-captured cell pixels are untrusted
    // input to this public function and must never trap.
    let (targetWidth, widthOverflow) = request.columns.multipliedReportingOverflow(by: cellWidth)
    let (targetHeight, heightOverflow) = request.rows.multipliedReportingOverflow(by: cellHeight)
    guard !widthOverflow, !heightOverflow else {
        return .failure(.exceedsRenderedLimit(bytes: Int.max, limit: limits.maxPayloadBytes))
    }
    guard let scaled = HostedKittyImageDecoder.scaleToCanvas(source: sourceRGBA, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                                             targetWidth: targetWidth, targetHeight: targetHeight,
                                                             maxBytes: limits.maxPayloadBytes) else {
        return .failure(.exceedsRenderedLimit(bytes: Int.max, limit: limits.maxPayloadBytes))
    }
    guard let stripes = HostedKittyImageDecoder.sliceStripes(canvas: scaled.bytes, canvasWidth: scaled.width, canvasHeight: scaled.height,
                                                             stripeHeight: cellHeight, rowCount: request.rows) else {
        return .failure(.badDimensions)
    }
    let renderedCost = scaled.bytes.count
    return .success(HostedKittyPreparedImage(epoch: request.epoch,
                                             originLinesTop: request.originLinesTop,
                                             imageId: request.imageId,
                                             imageNumber: request.imageNumber,
                                             placementId: request.placementId,
                                             columns: request.columns,
                                             rows: request.rows,
                                             zIndex: request.zIndex,
                                             pixelOffsetX: request.pixelOffsetX,
                                             pixelOffsetY: request.pixelOffsetY,
                                             rgba: sourceRGBA,
                                             width: sourceWidth,
                                             height: sourceHeight,
                                             isAlternateBuffer: request.isAlternateBuffer,
                                             stripes: stripes,
                                             scaledWidth: scaled.width,
                                             scaledHeight: scaled.height,
                                             cellWidthPx: cellWidth,
                                             cellHeightPx: cellHeight,
                                             anchorCol: request.anchorCol,
                                             anchorRow: request.anchorRow,
                                             renderedByteCost: renderedCost,
                                             isVirtual: request.isVirtual,
                                             isAnonymous: request.isAnonymous,
                                             parentImageId: request.parentImageId,
                                             parentPlacementId: request.parentPlacementId,
                                             parentOffsetH: request.parentOffsetH,
                                             parentOffsetV: request.parentOffsetV))
}

/// All-or-nothing preparation of a batch: the first invalid request fails the
/// whole batch without producing partial output, so callers never install a
/// mixture of valid and invalid placements. The aggregate source-plus-
/// rendered bytes are capped with checked arithmetic before the batch result
/// is retained, so one feed cannot pin unbounded in-flight memory.
public func prepareHostedKittyBatch(_ requests: [HostedKittyRenderRequest],
                                    limits: HostedKittyGraphicsLimits = .default) -> Result<[HostedKittyPreparedImage], HostedKittyPrepareError> {
    var prepared: [HostedKittyPreparedImage] = []
    prepared.reserveCapacity(requests.count)
    var inFlight = 0
    for request in requests {
        switch prepareHostedKittyRender(request, limits: limits) {
        case .success(let image):
            let (itemCost, costOverflow) = image.rgba.count.addingReportingOverflow(image.renderedByteCost)
            let (total, totalOverflow) = inFlight.addingReportingOverflow(itemCost)
            guard !costOverflow, !totalOverflow, total <= limits.maxPreparedBatchBytes else {
                return .failure(.exceedsBatchLimit(bytes: Int.max, limit: limits.maxPreparedBatchBytes))
            }
            inFlight = total
            prepared.append(image)
        case .failure(let error):
            return .failure(error)
        }
    }
    return .success(prepared)
}

/// Thread-safe image decoding, scaling, and slicing helpers for the two-phase
/// prepare path. None of these touch terminal or view state. Scaling and
/// slicing are pure Swift over RGBA bytes (no AppKit, no CoreGraphics), so
/// preparation is deterministic and testable on every platform.
enum HostedKittyImageDecoder {
    static func validateDimensions(width: Int, height: Int, maxDimension: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return width <= maxDimension && height <= maxDimension
    }

    static func pngPixelSize(data: Data) -> (width: Int, height: Int)? {
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
#else
        return nil
#endif
    }

    static func validatePNGDimensions(data: Data, maxDimension: Int) -> Bool {
#if canImport(ImageIO)
        guard let size = pngPixelSize(data: data) else { return false }
        return validateDimensions(width: size.width, height: size.height, maxDimension: maxDimension)
#else
        return !data.isEmpty
#endif
    }

    /// Decodes a PNG directly into the returned `Data` buffer (no
    /// intermediate array copy). The caller must verify header dimensions and
    /// the checked RGBA cost before calling, so this never allocates an
    /// unbounded raster.
    static func rasterizePNG(_ data: Data, maxDimension: Int, maxRGBABytes: Int) -> (rgba: Data, width: Int, height: Int)? {
#if canImport(ImageIO) && canImport(CoreGraphics)
        guard validatePNGDimensions(data: data, maxDimension: maxDimension),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard validateDimensions(width: width, height: height, maxDimension: maxDimension) else {
            return nil
        }
        let cost = Int64(width) * Int64(height) * 4
        guard cost > 0, cost <= Int64(maxRGBABytes) else {
            return nil
        }
        let bytesPerRow = width * 4
        var output = Data(count: Int(cost))
        let drawn = output.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (output, width, height)
#else
        return nil
#endif
    }

    /// zlib (RFC1950) inflate with an in-loop output cap: returns nil as soon
    /// as the next bytes would exceed `maxOutputBytes`, before that memory is
    /// retained. Pure Swift over the input bytes (no terminal, view, or OS
    /// decoder state), so preparation stays thread-safe and behaves
    /// identically on every platform, including Linux where the Compression
    /// framework is unavailable.
    static func decompressZlib(_ data: Data, maxOutputBytes: Int) -> Data? {
        KittyZlibInflate.inflate(data, maxOutputBytes: maxOutputBytes)
    }

    /// Pure-RGBA crop mirroring `Terminal.cropRgba` clamping semantics.
    static func cropRGBA(bytes: Data, width: Int, height: Int, x: Int, y: Int, w: Int, h: Int) -> (bytes: Data, width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (expected, expectedOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !areaOverflow, !expectedOverflow, bytes.count == expected else { return nil }
        let startX = max(0, min(x, width))
        let startY = max(0, min(y, height))
        let maxWidth = width - startX
        let maxHeight = height - startY
        let cropWidth = max(0, min(w > 0 ? w : maxWidth, maxWidth))
        let cropHeight = max(0, min(h > 0 ? h : maxHeight, maxHeight))
        if cropWidth == width && cropHeight == height && startX == 0 && startY == 0 {
            return (bytes, width, height)
        }
        guard cropWidth > 0, cropHeight > 0 else { return nil }
        let cost = Int64(cropWidth) * Int64(cropHeight) * 4
        guard cost <= Int64(bytes.count) else { return nil }
        var cropped = Data(count: Int(cost))
        let srcRowBytes = width * 4
        let dstRowBytes = cropWidth * 4
        cropped.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
                guard let d = dstRaw.baseAddress, let s = srcRaw.baseAddress else { return }
                for row in 0..<cropHeight {
                    let src = s.advanced(by: (startY + row) * srcRowBytes + startX * 4)
                    let dst = d.advanced(by: row * dstRowBytes)
                    dst.copyMemory(from: src, byteCount: dstRowBytes)
                }
            }
        }
        return (cropped, cropWidth, cropHeight)
    }

    /// Scales a source raster onto a `targetWidth` by `targetHeight` canvas
    /// with aspect-fill (cover) centering, mirroring the view `scale(image:)`
    /// helper: the source covers the canvas, centered, with edge overflow
    /// clipped. Pure bilinear Swift, safe on any thread. Returns nil (rather
    /// than allocating) when the checked canvas cost exceeds `maxBytes`.
    static func scaleToCanvas(source: Data, sourceWidth: Int, sourceHeight: Int,
                              targetWidth: Int, targetHeight: Int,
                              maxBytes: Int) -> (bytes: Data, width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0,
              source.count == sourceWidth * sourceHeight * 4 else {
            return nil
        }
        // Overflow-safe canvas cost: untrusted dimensions must never trap.
        let (area, areaOverflow) = Int64(targetWidth).multipliedReportingOverflow(by: Int64(targetHeight))
        let (cost, costOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !areaOverflow, !costOverflow, cost > 0, cost <= Int64(maxBytes) else {
            return nil
        }
        var output = Data(count: Int(cost))
        let scale = max(Double(targetWidth) / Double(sourceWidth),
                        Double(targetHeight) / Double(sourceHeight))
        let drawnWidth = Double(sourceWidth) * scale
        let drawnHeight = Double(sourceHeight) * scale
        let offsetX = (Double(targetWidth) - drawnWidth) / 2.0
        let offsetY = (Double(targetHeight) - drawnHeight) / 2.0
        output.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) in
            source.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
                guard let d = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let maxSX = sourceWidth - 1
                let maxSY = sourceHeight - 1
                for y in 0..<targetHeight {
                    let srcY = (Double(y) - offsetY) / scale
                    let y0 = max(0, min(maxSY, Int(floor(srcY))))
                    let y1 = max(0, min(maxSY, y0 + 1))
                    let fy = max(0.0, min(1.0, srcY - Double(y0)))
                    for x in 0..<targetWidth {
                        let srcX = (Double(x) - offsetX) / scale
                        let x0 = max(0, min(maxSX, Int(floor(srcX))))
                        let x1 = max(0, min(maxSX, x0 + 1))
                        let fx = max(0.0, min(1.0, srcX - Double(x0)))
                        let di = (y * targetWidth + x) * 4
                        for c in 0..<4 {
                            let p00 = Double(s[(y0 * sourceWidth + x0) * 4 + c])
                            let p10 = Double(s[(y0 * sourceWidth + x1) * 4 + c])
                            let p01 = Double(s[(y1 * sourceWidth + x0) * 4 + c])
                            let p11 = Double(s[(y1 * sourceWidth + x1) * 4 + c])
                            let top = p00 + (p10 - p00) * fx
                            let bottom = p01 + (p11 - p01) * fx
                            d[di + c] = UInt8(max(0, min(255, Int((top + (bottom - top) * fy).rounded()))))
                        }
                    }
                }
            }
        }
        return (output, targetWidth, targetHeight)
    }

    /// Slices a scaled canvas into `rowCount` stripes of `stripeHeight`
    /// pixels. Requires `canvasHeight == rowCount * stripeHeight`.
    static func sliceStripes(canvas: Data, canvasWidth: Int, canvasHeight: Int,
                             stripeHeight: Int, rowCount: Int) -> [HostedKittyPreparedStripe]? {
        guard rowCount > 0, stripeHeight > 0, canvasWidth > 0 else {
            return nil
        }
        let (tall, tallOverflow) = rowCount.multipliedReportingOverflow(by: stripeHeight)
        guard !tallOverflow, canvasHeight == tall else {
            return nil
        }
        let (rowBytes, rowOverflow) = canvasWidth.multipliedReportingOverflow(by: stripeHeight)
        let (stripeBytes, bytesOverflow) = rowBytes.multipliedReportingOverflow(by: 4)
        let (total, totalOverflow) = canvasWidth.multipliedReportingOverflow(by: canvasHeight)
        let (totalBytes, totalBytesOverflow) = total.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, !bytesOverflow, !totalOverflow, !totalBytesOverflow,
              canvas.count == totalBytes else {
            return nil
        }
        var stripes: [HostedKittyPreparedStripe] = []
        stripes.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let range = (index * stripeBytes)..<((index + 1) * stripeBytes)
            stripes.append(HostedKittyPreparedStripe(stripeIndex: index,
                                                     width: canvasWidth,
                                                     height: stripeHeight,
                                                     rgba: canvas.subdata(in: range)))
        }
        return stripes
    }
}

/// Minimal RFC1950 (zlib wrapper) + RFC1951 (deflate) inflate with a strict
/// output cap. Supports stored, fixed-Huffman, and dynamic-Huffman blocks;
/// validates the zlib header, block structure, distance references, exact
/// input consumption, and the Adler-32 trailer. Any malformed input, or any
/// output that would exceed `maxOutputBytes`, returns nil before the excess
/// memory is retained. Used by both the two-phase prepare path and the
/// legacy inline path so `o=z` behaves identically everywhere.
enum KittyZlibInflate {
    private static let maxBits = 15

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                          257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                          8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static func inflate(_ data: Data, maxOutputBytes: Int) -> Data? {
        guard maxOutputBytes >= 0, data.count >= 6 else { return nil }
        // RFC1950 header: deflate method, valid check bits, no preset dict.
        let cmf = Int(data[data.startIndex])
        let flg = Int(data[data.index(data.startIndex, offsetBy: 1)])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else {
            return nil
        }
        let body = data[data.index(data.startIndex, offsetBy: 2)..<data.index(data.endIndex, offsetBy: -4)]
        var decoder = BitDecoder(bytes: Array(body), maxOutputBytes: maxOutputBytes)
        guard decoder.decodeBlocks() else { return nil }
        // The deflate stream must end on a byte boundary with no trailing
        // garbage inside the wrapped body.
        guard decoder.alignToByte(), decoder.isAtEnd else { return nil }
        // Adler-32 trailer over the inflated output.
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        for byte in decoder.output {
            s1 = (s1 + UInt32(byte)) % 65521
            s2 = (s2 + s1) % 65521
        }
        let expected = (s2 << 16) | s1
        var actual: UInt32 = 0
        for i in 0..<4 {
            actual = (actual << 8) | UInt32(data[data.index(data.endIndex, offsetBy: -4 + i)])
        }
        guard actual == expected else { return nil }
        return Data(decoder.output)
    }

    /// Canonical Huffman table with a 9-bit fast path and a full 15-bit
    /// table, so every symbol decodes with one array lookup.
    private struct HuffmanTable {
        var symbols: [Int]
        var lengths: [Int]

        init?(lengths: [Int]) {
            guard !lengths.isEmpty, lengths.allSatisfy({ $0 >= 0 && $0 <= maxBits }) else {
                return nil
            }
            let wide = 1 << maxBits
            var sym = [Int](repeating: -1, count: wide)
            var len = [Int](repeating: 0, count: wide)
            var blCount = [Int](repeating: 0, count: maxBits + 1)
            for length in lengths where length > 0 {
                blCount[length] += 1
            }
            var nextCode = [Int](repeating: 0, count: maxBits + 1)
            var code = 0
            for bits in 1...maxBits {
                code = (code + blCount[bits - 1]) << 1
                nextCode[bits] = code
            }
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let c = nextCode[length]
                nextCode[length] += 1
                guard c < (1 << length) else { return nil }
                // Codes pack MSB-first; the bit stream feeds LSB-first, so
                // reverse the code bits for table indexing.
                var reversed = 0
                var tmp = c
                for _ in 0..<length {
                    reversed = (reversed << 1) | (tmp & 1)
                    tmp >>= 1
                }
                let fill = maxBits - length
                var k = 0
                while k < (1 << fill) {
                    let index = reversed | (k << length)
                    if sym[index] != -1 { return nil }
                    sym[index] = symbol
                    len[index] = length
                    k += 1
                }
            }
            self.symbols = sym
            self.lengths = len
        }
    }

    private struct BitDecoder {
        let bytes: [UInt8]
        let maxOutputBytes: Int
        var bytePos = 0
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(bytes: [UInt8], maxOutputBytes: Int) {
            self.bytes = bytes
            self.maxOutputBytes = maxOutputBytes
        }

        /// Consumed input position: loaded bytes minus whole buffered bytes.
        /// The loader runs ahead, so stored-block copies and end checks must
        /// use this, never the raw load cursor.
        var consumedPos: Int { bytePos - bitCount / 8 }

        var isAtEnd: Bool { consumedPos >= bytes.count && bitCount % 8 == 0 }

        mutating func fill() {
            while bitCount <= 48, bytePos < bytes.count {
                bitBuffer |= UInt64(bytes[bytePos]) << bitCount
                bytePos += 1
                bitCount += 8
            }
        }

        /// Reads `n` bits (LSB-first). Returns nil when fewer than `n` real
        /// bits remain, which only happens on truncated input.
        mutating func readBits(_ n: Int) -> Int? {
            if n == 0 { return 0 }
            guard n > 0, n <= 16 else { return nil }
            fill()
            guard bitCount >= n else { return nil }
            let value = Int(bitBuffer & ((UInt64(1) << n) - 1))
            bitBuffer >>= n
            bitCount -= n
            return value
        }

        mutating func decodeSymbol(_ table: HuffmanTable) -> Int? {
            fill()
            // Up to 15 bits are indexed; past the true end of input (where
            // encoders emit zero padding) missing high bits read as zero.
            // A match is only accepted when its whole code is real, so
            // truncated input returns nil instead of mis-decoding.
            let have = min(bitCount, maxBits)
            guard have > 0 else { return nil }
            let index = Int(bitBuffer & ((UInt64(1) << have) - 1))
            let symbol = table.symbols[index]
            let length = table.lengths[index]
            guard symbol >= 0, length > 0, length <= have else { return nil }
            bitBuffer >>= length
            bitCount -= length
            return symbol
        }

        mutating func alignToByte() -> Bool {
            let skip = bitCount % 8
            // Padding bits must be zero per RFC1951 (`...` encoders emit
            // zeros); tolerate nonzero padding to stay liberal in what we
            // accept, since only framing matters here.
            bitBuffer >>= skip
            bitCount -= skip
            return true
        }

        mutating func decodeBlocks() -> Bool {
            output.reserveCapacity(min(maxOutputBytes, 64 * 1024))
            while true {
                guard let header = readBits(3) else { return false }
                let isFinal = header & 1 == 1
                switch (header >> 1) & 0x3 {
                case 0:
                    guard decodeStored() else { return false }
                case 1:
                    guard decodeHuffman(litLen: BitDecoder.fixedLitLen, dist: BitDecoder.fixedDist) else {
                        return false
                    }
                case 2:
                    guard let tables = decodeDynamicTables(),
                          decodeHuffman(litLen: tables.0, dist: tables.1) else {
                        return false
                    }
                default:
                    return false
                }
                if isFinal { return true }
            }
        }

        mutating func decodeStored() -> Bool {
            guard alignToByte() else { return false }
            guard let len = readBits(16), let nlen = readBits(16), len ^ 0xFFFF == nlen else {
                return false
            }
            // Subtractive checks: exact-cap (equality admitted) with no
            // addition that could trap near Int.max.
            let start = consumedPos
            guard len >= 0, start >= 0,
                  len <= maxOutputBytes - output.count,
                  len <= bytes.count - start else {
                return false
            }
            output.append(contentsOf: bytes[start..<(start + len)])
            bytePos = start + len
            bitBuffer = 0
            bitCount = 0
            return true
        }

        mutating func decodeHuffman(litLen: HuffmanTable, dist: HuffmanTable) -> Bool {
            while true {
                guard let symbol = decodeSymbol(litLen) else { return false }
                if symbol < 256 {
                    guard 1 <= maxOutputBytes - output.count else { return false }
                    output.append(UInt8(symbol))
                } else if symbol == 256 {
                    return true
                } else if symbol <= 285 {
                    let index = symbol - 257
                    guard let extra = readBits(lengthExtra[index]) else { return false }
                    let length = lengthBase[index] + extra
                    guard let distSymbol = decodeSymbol(dist) else { return false }
                    guard distSymbol < 30, let distExtra = readBits(distExtra[distSymbol]) else {
                        return false
                    }
                    let distance = distBase[distSymbol] + distExtra
                    guard distance >= 1, distance <= output.count else { return false }
                    guard length <= maxOutputBytes - output.count else { return false }
                    let start = output.count - distance
                    for i in 0..<length {
                        output.append(output[start + i])
                    }
                } else {
                    return false
                }
            }
        }

        mutating func decodeDynamicTables() -> (HuffmanTable, HuffmanTable)? {
            guard let hlit = readBits(5), let hdist = readBits(5), let hclen = readBits(4) else {
                return nil
            }
            let litCount = hlit + 257
            let distCount = hdist + 1
            let clenCount = hclen + 4
            guard litCount <= 288, distCount <= 32, clenCount <= 19 else { return nil }
            var clenLengths = [Int](repeating: 0, count: 19)
            for i in 0..<clenCount {
                guard let v = readBits(3) else { return nil }
                clenLengths[codeLengthOrder[i]] = v
            }
            guard let clenTable = HuffmanTable(lengths: clenLengths) else { return nil }
            var lengths: [Int] = []
            lengths.reserveCapacity(litCount + distCount)
            while lengths.count < litCount + distCount {
                guard let symbol = decodeSymbol(clenTable) else { return nil }
                if symbol <= 15 {
                    lengths.append(symbol)
                } else if symbol == 16 {
                    guard let repeatCount = readBits(2), !lengths.isEmpty else { return nil }
                    let last = lengths[lengths.count - 1]
                    let copies = repeatCount + 3
                    guard lengths.count + copies <= litCount + distCount else { return nil }
                    lengths.append(contentsOf: repeatElement(last, count: copies))
                } else if symbol == 17 {
                    guard let repeatCount = readBits(3) else { return nil }
                    let copies = repeatCount + 3
                    guard lengths.count + copies <= litCount + distCount else { return nil }
                    lengths.append(contentsOf: repeatElement(0, count: copies))
                } else if symbol == 18 {
                    guard let repeatCount = readBits(7) else { return nil }
                    let copies = repeatCount + 11
                    guard lengths.count + copies <= litCount + distCount else { return nil }
                    lengths.append(contentsOf: repeatElement(0, count: copies))
                } else {
                    return nil
                }
            }
            // RFC1951 requires at least one end-of-block code; an
            // over-subscribed or incomplete table is rejected by the
            // HuffmanTable builder.
            guard lengths.count == litCount + distCount, lengths[256] > 0 else { return nil }
            guard let litLen = HuffmanTable(lengths: Array(lengths[0..<litCount])),
                  let dist = HuffmanTable(lengths: Array(lengths[litCount...])) else {
                return nil
            }
            return (litLen, dist)
        }

        static var fixedLitLen: HuffmanTable = {
            var lengths = [Int](repeating: 0, count: 288)
            for i in 0..<144 { lengths[i] = 8 }
            for i in 144..<256 { lengths[i] = 9 }
            for i in 256..<280 { lengths[i] = 7 }
            for i in 280..<288 { lengths[i] = 8 }
            return HuffmanTable(lengths: lengths)!
        }()

        static var fixedDist: HuffmanTable = {
            HuffmanTable(lengths: [Int](repeating: 5, count: 32))!
        }()
    }
}

extension Terminal {
    /// Records the calling thread as this terminal's feeding thread on first
    /// use and asserts all later hosted graphics calls share it. Called only
    /// through `assert(...)`, so in release builds the call (including the
    /// store) is compiled out entirely via the autoclosure.
    func recordHostedFeedingThread() -> Bool {
        if let owner = hostedFeedingThread {
            return owner === Thread.current
        }
        hostedFeedingThread = Thread.current
        return true
    }

    /// Limits for two-phase hosted graphics derived from this terminal's
    /// options. Queue and partial-transfer bounds are configurable alongside
    /// the per-payload cap; placement-cell bounds stay at compiled defaults
    /// so a misconfigured option cannot reopen parse-time stalls.
    public func hostedKittyLimits() -> HostedKittyGraphicsLimits {
        HostedKittyGraphicsLimits(maxPayloadBytes: max(1, options.kittyHostedPayloadLimitBytes),
                                  maxPartialEncodedBytes: max(1, options.kittyHostedMaxPartialEncodedBytes),
                                  maxPendingJobs: max(0, options.kittyHostedMaxPendingJobs),
                                  maxPendingBytes: max(0, options.kittyHostedMaxPendingBytes))
    }

    /// Current hosted-graphics queue accounting for host watermarks. Call only
    /// from the thread that feeds the terminal (normally main).
    public func hostedKittyQueueMetrics() -> HostedKittyQueueMetrics {
        assert(recordHostedFeedingThread())
        let pendingBytes = pendingHostedKittyRenders.reduce(0) { hostedSaturatingAdd($0, $1.base64Payload.count) }
        let oldest = pendingHostedKittyRenders.map(\.enqueuedAt).min()
        return HostedKittyQueueMetrics(partialEncodedBytes: kittyGraphicsState.pending?.base64Payload.count ?? 0,
                                       pendingJobs: pendingHostedKittyRenders.count,
                                       pendingBytes: pendingBytes,
                                       oldestJobAge: oldest.map { max(0, Date().timeIntervalSince($0)) })
    }

    /// Total image-memory accounting: retained source payload bytes plus
    /// retained precomputed-stripe bytes. Rendered costs are tracked per
    /// hosted placement and released when the placement is removed, the
    /// buffer is cleared, or the terminal resets.
    public func kittyImageMemoryUsage() -> (sourceBytes: Int, renderedBytes: Int, totalBytes: Int) {
        assert(recordHostedFeedingThread())
        let rendered = kittyGraphicsState.totalRenderedStripeBytes
        return (kittyGraphicsState.totalImageBytes, rendered, kittyGraphicsState.totalImageBytes + rendered)
    }

    /// Admission check for one complete hosted ticket carrying `encodedBytes`
    /// of base64. Must pass before image-id assignment, placement
    /// registration, placeholder creation, or enqueue. Pure accounting: no
    /// mutation.
    public func admitHostedRenderRequest(encodedBytes: Int) -> HostedKittyAdmission {
        assert(recordHostedFeedingThread())
        let limits = hostedKittyLimits()
        if encodedBytes > limits.maxPartialEncodedBytes {
            return .rejected(.partialTransferTooLarge(bytes: encodedBytes, limit: limits.maxPartialEncodedBytes))
        }
        let estimated = encodedBytes / 4 * 3
        if estimated > limits.maxPayloadBytes {
            return .rejected(.payloadTooLarge(bytes: estimated, limit: limits.maxPayloadBytes))
        }
        if pendingHostedKittyRenders.count + 1 > limits.maxPendingJobs {
            return .rejected(.pendingQueueFull(jobs: pendingHostedKittyRenders.count, limit: limits.maxPendingJobs))
        }
        let pendingBytes = pendingHostedKittyRenders.reduce(0) { hostedSaturatingAdd($0, $1.base64Payload.count) }
        // Subtractive comparison: `pending + encoded > max` without an
        // addition that could trap near Int.max. A negative size is rejected
        // fail-closed.
        guard encodedBytes >= 0, pendingBytes <= limits.maxPendingBytes - encodedBytes else {
            return .rejected(.pendingQueueBytesFull(bytes: pendingBytes, limit: limits.maxPendingBytes))
        }
        return .admitted
    }

    /// Drains and returns pending two-phase render requests in FIFO order.
    /// Call only from the thread that feeds the terminal (normally main).
    public func takePendingHostedKittyRenders() -> [HostedKittyRenderRequest] {
        assert(recordHostedFeedingThread())
        let pending = pendingHostedKittyRenders
        pendingHostedKittyRenders.removeAll()
        return pending
    }

    /// Drops queued two-phase work and retires every outstanding ticket.
    /// Install calls carrying the old epoch report `.stale` without mutating
    /// terminal state. Called automatically on image-clearing operations
    /// (reset, buffer switches, manifest install); call it explicitly on
    /// detach or renderer replacement.
    public func invalidateHostedKittyRenders() {
        assert(recordHostedFeedingThread())
        hostedGraphicsEpoch &+= 1
        pendingHostedKittyRenders.removeAll()
    }

    /// Validates and commits a prepared batch. Call only from the thread that
    /// feeds the terminal (normally main): registration, cursor, and buffer
    /// state are shared with the parser and are not locked.
    ///
    /// Validation is all-or-nothing and mutation is atomic:
    /// - Epoch, buffer, placement survival, raster, and stripe shape are
    ///   validated for every item before anything is committed.
    /// - Duplicate placement keys keep the last item; source cache deltas are
    ///   computed once per unique image id (pre-batch size to final staged
    ///   size), so repaint bursts sharing an image id are charged exactly.
    /// - Source plus rendered stripe bytes are admitted against the image
    ///   cache limit together.
    /// - If any stripe attach fails, committed payloads are restored,
    ///   attached stripes are removed, placeholders are rebuilt from the
    ///   pre-install snapshot, and `.rejected` is reported with nothing left
    ///   behind, so a retry cannot duplicate stripes or cache charges.
    public func installHostedKittyPreparedImages(_ prepared: [HostedKittyPreparedImage]) -> HostedKittyInstallOutcome {
        assert(recordHostedFeedingThread())
        guard !prepared.isEmpty else {
            return .installed(placements: 0)
        }
        // Full scrollback lifecycle pass: reap anchor-dead records, release
        // costs for vanished stripes/placeholders, reclaim unused payloads,
        // so validation and admission below see exact retained state.
        reconcileHostedPlacements()
        let epoch = hostedGraphicsEpoch
        // Phase 1: validate everything, snapshot placeholder lines. No
        // mutation here.
        var placeholderLinesByKey: [KittyPlacementKey: [Int]] = [:]
        for item in prepared {
            guard item.epoch == epoch,
                  item.isAlternateBuffer == isCurrentBufferAlternate else {
                return .stale
            }
            let key = KittyPlacementKey(imageId: item.imageId, placementId: item.placementId)
            guard let record = kittyGraphicsState.placementsByKey[key],
                  record.isAlternateBuffer == isCurrentBufferAlternate else {
                return .stale
            }
            // Store-only commits carry no stripes: virtual placements,
            // zero-grid displays, and tickets captured without a view cell
            // size (headless terminals keep their placeholders, exactly like
            // the legacy headless path). Anything with stripes must validate
            // shape, cost, and placeholder survival below.
            if item.stripes.isEmpty {
                guard item.renderedByteCost == 0 else {
                    return .rejected(reason: "invalid prepared stripes")
                }
            } else {
                guard hasHostedPlaceholder(key: key) else {
                    return .stale
                }
                guard item.stripes.count == item.rows,
                      item.renderedByteCost >= 0 else {
                    return .rejected(reason: "invalid prepared stripes")
                }
                // Overflow-safe shape checks: prepared values are untrusted
                // input to this public function and must never trap.
                var stripeBytes = 0
                for stripe in item.stripes {
                    let (stripeArea, stripeAreaOverflow) = stripe.width.multipliedReportingOverflow(by: stripe.height)
                    let (stripeCost, stripeCostOverflow) = stripeArea.multipliedReportingOverflow(by: 4)
                    let (running, runningOverflow) = stripeBytes.addingReportingOverflow(stripe.rgba.count)
                    guard stripe.width > 0, stripe.height > 0,
                          !stripeAreaOverflow, !stripeCostOverflow, !runningOverflow,
                          stripe.rgba.count == stripeCost else {
                        return .rejected(reason: "invalid prepared stripes")
                    }
                    stripeBytes = running
                }
                let cellHeight = item.cellHeightPx ?? 0
                let (expectHeight, heightOverflow) = item.rows.multipliedReportingOverflow(by: cellHeight)
                guard stripeBytes == item.renderedByteCost,
                      item.scaledWidth > 0, !heightOverflow, item.scaledHeight == expectHeight,
                      item.stripes.allSatisfy({ $0.width == item.scaledWidth && $0.height == cellHeight }) else {
                    return .rejected(reason: "invalid prepared stripes")
                }
                placeholderLinesByKey[key] = hostedPlaceholderLines(key: key)
                guard !(placeholderLinesByKey[key]?.isEmpty ?? true) else {
                    return .stale
                }
            }
            let (rasterArea, rasterAreaOverflow) = item.width.multipliedReportingOverflow(by: item.height)
            let (rasterCost, rasterCostOverflow) = rasterArea.multipliedReportingOverflow(by: 4)
            guard item.width > 0, item.height > 0,
                  !rasterAreaOverflow, !rasterCostOverflow,
                  item.rgba.count == rasterCost else {
                return .rejected(reason: "invalid prepared raster")
            }
        }
        // Phase 2: de-duplicate by placement key (last wins), preserving
        // first-seen order for deterministic commits.
        var uniqueKeys: [KittyPlacementKey] = []
        var latestByKey: [KittyPlacementKey: HostedKittyPreparedImage] = [:]
        for item in prepared {
            let key = KittyPlacementKey(imageId: item.imageId, placementId: item.placementId)
            if latestByKey[key] == nil {
                uniqueKeys.append(key)
            }
            latestByKey[key] = item
        }
        let items = uniqueKeys.compactMap { latestByKey[$0] }
        // Phase 3: replacement-aware admission over source plus rendered
        // bytes. Each unique image id contributes its final staged size minus
        // its pre-batch size exactly once; each placement contributes its
        // rendered cost minus any cost already tracked for that key.
        var stagedBytesById: [UInt32: Int] = [:]
        var stagedNumberById: [UInt32: UInt32?] = [:]
        for item in items where !item.isAnonymous {
            stagedBytesById[item.imageId] = item.rgba.count
            stagedNumberById[item.imageId] = item.imageNumber
        }
        // Checked admission sums: any overflow rejects instead of trapping.
        var sourceDelta = 0
        for (id, bytes) in stagedBytesById {
            let (added, addOverflow) = sourceDelta.addingReportingOverflow(bytes)
            guard !addOverflow else {
                return .rejected(reason: "image cache limit")
            }
            sourceDelta = added
            if let existing = kittyGraphicsState.imagesById[id] {
                sourceDelta -= existing.byteSize
            }
        }
        var renderedDelta = 0
        for item in items {
            let key = KittyPlacementKey(imageId: item.imageId, placementId: item.placementId)
            let (added, addOverflow) = renderedDelta.addingReportingOverflow(item.renderedByteCost)
            guard !addOverflow else {
                return .rejected(reason: "image cache limit")
            }
            renderedDelta = added
            renderedDelta -= kittyGraphicsState.renderedStripeBytesByKey[key] ?? 0
        }
        let usage = kittyImageMemoryUsage()
        let (admitted, admitOverflow) = usage.totalBytes.addingReportingOverflow(sourceDelta)
        let (admittedAll, admittedAllOverflow) = admitted.addingReportingOverflow(renderedDelta)
        guard !admitOverflow, !admittedAllOverflow,
              admittedAll <= clampedKittyImageCacheLimitBytes() else {
            return .rejected(reason: "image cache limit")
        }
        // Phase 4: commit payloads without per-item eviction (a single
        // enforcement runs after the batch), snapshotting replaced state for
        // rollback.
        let stagedNumbers = Set(stagedNumberById.values.compactMap { $0 })
        let preBatchNumbers = preBatchNumbersSnapshot(including: stagedNumbers)
        var oldPayloads: [UInt32: KittyGraphicsImage] = [:]
        var createdIds: Set<UInt32> = []
        for id in stagedBytesById.keys.sorted() {
            guard let item = items.last(where: { $0.imageId == id }) else { continue }
            if let existing = kittyGraphicsState.imagesById[id] {
                oldPayloads[id] = existing
            } else {
                createdIds.insert(id)
            }
            let payload = KittyGraphicsPayload.rgba(bytes: Array(item.rgba), width: item.width, height: item.height)
            setKittyImagePayloadStaged(payload: payload, imageId: id, imageNumber: item.imageNumber)
        }
        // Phase 5: attach stripes. Any failure rolls everything back.
        var attachedKeys: [KittyPlacementKey] = []
        for item in items {
            if item.stripes.isEmpty {
                continue
            }
            let ok = tdel?.attachPreparedKittyImage(source: self, prepared: item) ?? true
            if !ok {
                rollbackHostedInstall(stagedIds: Set(stagedBytesById.keys),
                                      oldPayloads: oldPayloads,
                                      createdIds: createdIds,
                                      preBatchNumbers: preBatchNumbers,
                                      attachedKeys: attachedKeys,
                                      placeholderLinesByKey: placeholderLinesByKey,
                                      itemsByKey: latestByKey)
                return .rejected(reason: "stripe attach failed")
            }
            attachedKeys.append(KittyPlacementKey(imageId: item.imageId, placementId: item.placementId))
        }
        // Phase 6: record rendered costs, single cache enforcement, report.
        for item in items {
            let key = KittyPlacementKey(imageId: item.imageId, placementId: item.placementId)
            if item.renderedByteCost > 0 {
                noteRenderedStripeCost(key: key, bytes: item.renderedByteCost)
            } else {
                // Reinstalls that carry no stripes (virtual, store-only, or
                // headless-captured tickets) retain no rendered memory.
                releaseRenderedStripeCost(keys: [key])
            }
        }
        enforceKittyImageCacheLimit()
        return .installed(placements: items.count)
    }

    /// Pre-batch image-number mappings for the numbers in `numbers`.
    /// Captured before commit so rollback can restore displaced mappings.
    private func preBatchNumbersSnapshot(including numbers: Set<UInt32>) -> [UInt32: UInt32?] {
        var snapshot: [UInt32: UInt32?] = [:]
        for number in numbers {
            snapshot[number] = kittyGraphicsState.imageNumbers[number]
        }
        return snapshot
    }

    private func rollbackHostedInstall(stagedIds: Set<UInt32>,
                                       oldPayloads: [UInt32: KittyGraphicsImage],
                                       createdIds: Set<UInt32>,
                                       preBatchNumbers: [UInt32: UInt32?],
                                       attachedKeys: [KittyPlacementKey],
                                       placeholderLinesByKey: [KittyPlacementKey: [Int]],
                                       itemsByKey: [KittyPlacementKey: HostedKittyPreparedImage]) {
        for id in stagedIds {
            if let old = oldPayloads[id] {
                let current = kittyGraphicsState.imagesById[id]
                if let current {
                    kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - current.byteSize)
                }
                kittyGraphicsState.imagesById[id] = old
                kittyGraphicsState.totalImageBytes += old.byteSize
            } else if createdIds.contains(id) {
                if let current = kittyGraphicsState.imagesById.removeValue(forKey: id) {
                    kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - current.byteSize)
                }
                removeKittyImageNumbers(for: id)
            }
        }
        for (number, oldTarget) in preBatchNumbers {
            if let oldTarget {
                kittyGraphicsState.imageNumbers[number] = oldTarget
            } else {
                kittyGraphicsState.imageNumbers.removeValue(forKey: number)
            }
        }
        for key in attachedKeys {
            removeAttachedHostedStripes(key: key)
            if let item = itemsByKey[key] {
                restoreHeadlessPlaceholders(item: item, lines: placeholderLinesByKey[key] ?? [])
            }
        }
    }

    /// Removes non-headless (attached stripe) line images for one placement
    /// key from both buffers. Headless placeholders are never touched.
    private func removeAttachedHostedStripes(key: KittyPlacementKey) {
        for target in [normalBuffer, altBuffer] {
            for rowIndex in 0..<target.lines.count {
                guard let images = target.lines[rowIndex].images else { continue }
                var kept: [TerminalImage] = []
                var removed = false
                for image in images {
                    if let kitty = image as? KittyPlacementImage,
                       !(image is KittyHeadlessPlacementImage),
                       kitty.kittyIsKitty,
                       kitty.kittyImageId == key.imageId,
                       kitty.kittyPlacementId == key.placementId {
                        removed = true
                    } else {
                        kept.append(image)
                    }
                }
                if removed {
                    target.clearImagesFromLine(at: rowIndex)
                    for image in kept {
                        target.attachImage(image, toLineAt: rowIndex)
                    }
                }
            }
        }
    }

    /// Rebuilds headless placeholders for a rolled-back placement at the
    /// pre-install snapshot lines.
    private func restoreHeadlessPlaceholders(item: HostedKittyPreparedImage, lines: [Int]) {
        for line in lines {
            guard line >= 0, line < buffer.lines.count else { continue }
            let placeholder = KittyHeadlessPlacementImage()
            placeholder.kittyImageId = item.imageId
            placeholder.kittyImageNumber = item.imageNumber
            placeholder.kittyPlacementId = item.placementId
            placeholder.kittyZIndex = item.zIndex
            placeholder.kittyCol = item.anchorCol
            placeholder.kittyRow = item.anchorRow
            placeholder.kittyCols = item.columns
            placeholder.kittyRows = item.rows
            placeholder.kittyPixelOffsetX = item.pixelOffsetX
            placeholder.kittyPixelOffsetY = item.pixelOffsetY
            placeholder.col = item.anchorCol
            buffer.attachImage(placeholder, toLineAt: line)
        }
    }

    private func hasHostedPlaceholder(key: KittyPlacementKey) -> Bool {
        !(hostedPlaceholderLines(key: key).isEmpty)
    }

    private func hostedPlaceholderLines(key: KittyPlacementKey) -> [Int] {
        var lines: [Int] = []
        let target = buffer
        for rowIndex in 0..<target.lines.count {
            guard let images = target.lines[rowIndex].images else { continue }
            for image in images {
                if image is KittyHeadlessPlacementImage,
                   let kitty = image as? KittyPlacementImage,
                   kitty.kittyImageId == key.imageId,
                   kitty.kittyPlacementId == key.placementId {
                    lines.append(rowIndex)
                    break
                }
            }
        }
        return lines
    }

    /// Records the retained stripe cost for one hosted placement, replacing
    /// any cost previously tracked for that key.
    private func noteRenderedStripeCost(key: KittyPlacementKey, bytes: Int) {
        if let old = kittyGraphicsState.renderedStripeBytesByKey[key] {
            kittyGraphicsState.totalRenderedStripeBytes = max(0, kittyGraphicsState.totalRenderedStripeBytes - old)
        }
        kittyGraphicsState.renderedStripeBytesByKey[key] = bytes
        kittyGraphicsState.totalRenderedStripeBytes += bytes
    }

    /// Releases retained stripe costs for removed placements.
    func releaseRenderedStripeCost(keys: Set<KittyPlacementKey>) {
        for key in keys {
            if let old = kittyGraphicsState.renderedStripeBytesByKey.removeValue(forKey: key) {
                kittyGraphicsState.totalRenderedStripeBytes = max(0, kittyGraphicsState.totalRenderedStripeBytes - old)
            }
        }
    }

    /// Placement keys with surviving line presence (headless placeholders or
    /// attached stripes) in either buffer.
    func hostedLivePlacementKeys() -> Set<KittyPlacementKey> {
        var live = Set<KittyPlacementKey>()
        for target in [normalBuffer, altBuffer] {
            for rowIndex in 0..<target.lines.count {
                guard let images = target.lines[rowIndex].images else { continue }
                for image in images {
                    if let kitty = image as? KittyPlacementImage,
                       kitty.kittyIsKitty,
                       let imageId = kitty.kittyImageId,
                       let placementId = kitty.kittyPlacementId {
                        live.insert(KittyPlacementKey(imageId: imageId, placementId: placementId))
                    }
                }
            }
        }
        return live
    }

    /// Removes gridded placement records with no surviving line presence:
    /// scrollback trimming, scroll-region drops, or display clears destroyed
    /// their rows, so they are unrenderable and their install would be
    /// stale anyway. Frame-free (presence, not coordinates), so fresh
    /// records can never match. Virtual and zero-grid records never own
    /// lines by design and are exempt here; the count cap bounds them.
    /// Releases rendered costs for reaped keys. Returns them.
    @discardableResult
    func reapDeadHostedPlacements() -> Set<KittyPlacementKey> {
        let live = hostedLivePlacementKeys()
        var dead = Set<KittyPlacementKey>()
        for (key, record) in kittyGraphicsState.placementsByKey {
            guard !record.isVirtual, record.cols > 0, record.rows > 0,
                  !live.contains(key) else {
                continue
            }
            dead.insert(key)
        }
        for key in dead {
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
        }
        releaseRenderedStripeCost(keys: dead)
        return dead
    }

    /// Enforces hosted placement-metadata bounds after queue admission and
    /// before any mutation. Reaps scrollback-dead records, then evicts
    /// records without surviving line presence (virtual/store-only)
    /// oldest-first past the count cap. Line-backed records are never torn:
    /// returns false so the caller rejects instead. Reclaims newly-unused
    /// source payloads on success.
    func enforceHostedPlacementBounds() -> Bool {
        _ = reapDeadHostedPlacements()
        let cap = max(1, hostedKittyLimits().maxHostedPlacements)
        let live = hostedLivePlacementKeys()
        while kittyGraphicsState.placementsByKey.count >= cap {
            let victim = kittyGraphicsState.placementsByKey
                .filter { !live.contains($0.key) }
                .min { $0.value.placementId < $1.value.placementId }
            guard let key = victim?.key else { return false }
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
            releaseRenderedStripeCost(keys: [key])
        }
        cleanupUnusedKittyImages()
        return true
    }

    /// Full scrollback lifecycle pass: reap anchor-dead records, release
    /// costs for placements whose stripes/placeholders vanished, then
    /// reclaim source payloads left unused. Runs at install before
    /// validation so admission sees exact retained state.
    func reconcileHostedPlacements() {
        _ = reapDeadHostedPlacements()
        reconcileRenderedStripeCosts()
        cleanupUnusedKittyImages()
    }

    /// Drops rendered costs for placements with neither stripes nor
    /// placeholders left on any line (for example scrollback trimming
    /// discarded the rows while the record survived). Keys that retain
    /// headless placeholders keep their cost: headless installs never render
    /// bitmaps, and failed attaches roll placeholders back. Only releases;
    /// never adds.
    func reconcileRenderedStripeCosts() {
        var striped = Set<KittyPlacementKey>()
        var placeholder = Set<KittyPlacementKey>()
        for target in [normalBuffer, altBuffer] {
            for rowIndex in 0..<target.lines.count {
                guard let images = target.lines[rowIndex].images else { continue }
                for image in images {
                    if let kitty = image as? KittyPlacementImage,
                       kitty.kittyIsKitty,
                       let imageId = kitty.kittyImageId,
                       let placementId = kitty.kittyPlacementId {
                        let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
                        if image is KittyHeadlessPlacementImage {
                            placeholder.insert(key)
                        } else {
                            striped.insert(key)
                        }
                    }
                }
            }
        }
        let live = striped.union(placeholder)
        let stale = Set(kittyGraphicsState.renderedStripeBytesByKey.keys).subtracting(live)
        releaseRenderedStripeCost(keys: stale)
    }
}
