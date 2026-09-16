//
//  KittyGraphics.swift
//  SwiftTerm
//
//

import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

#if !os(Windows)
@_silgen_name("shm_open")
private func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
#endif

struct KittyPlacementContext {
    var imageId: UInt32?
    var imageNumber: UInt32?
    var placementId: UInt32?
    var parentImageId: UInt32?
    var parentPlacementId: UInt32?
    var parentOffsetH: Int
    var parentOffsetV: Int
    var zIndex: Int
    var widthRequest: ImageSizeRequest
    var heightRequest: ImageSizeRequest
    var preserveAspectRatio: Bool
    var cursorPolicy: Int
    var isRelative: Bool
    var pixelOffsetX: Int
    var pixelOffsetY: Int
}

protocol KittyPlacementImage: TerminalImage {
    var kittyIsKitty: Bool { get set }
    var kittyImageId: UInt32? { get set }
    var kittyImageNumber: UInt32? { get set }
    var kittyPlacementId: UInt32? { get set }
    var kittyZIndex: Int { get set }
    var kittyCol: Int { get set }
    var kittyRow: Int { get set }
    var kittyCols: Int { get set }
    var kittyRows: Int { get set }
    var kittyPixelOffsetX: Int { get set }
    var kittyPixelOffsetY: Int { get set }
}

struct KittyPlacementKey: Hashable {
    let imageId: UInt32
    let placementId: UInt32
}

struct KittyPlacementRecord {
    let imageId: UInt32
    let placementId: UInt32
    let parentImageId: UInt32?
    let parentPlacementId: UInt32?
    let parentOffsetH: Int
    let parentOffsetV: Int
    var pixelOffsetX: Int
    var pixelOffsetY: Int
    var col: Int
    var row: Int
    var cols: Int
    var rows: Int
    var zIndex: Int
    var isVirtual: Bool
    var isAlternateBuffer: Bool
}

struct KittyGraphicsControl {
    let action: Character
    let suppressResponses: Int
    let format: Int
    let transmission: Character
    let width: Int
    let height: Int
    let cropX: Int
    let cropY: Int
    let cropWidth: Int
    let cropHeight: Int
    let dataSize: Int
    let dataOffset: Int
    let imageId: UInt32?
    let imageNumber: UInt32?
    let placementId: UInt32?
    let parentImageId: UInt32?
    let parentPlacementId: UInt32?
    let offsetH: Int
    let offsetV: Int
    let pixelOffsetX: Int
    let pixelOffsetY: Int
    let unicodePlaceholder: Int
    let zIndex: Int
    let more: Int
    let compression: Character?
    let columns: Int
    let rows: Int
    let cursorPolicy: Int
    let deleteMode: Character?
}

enum KittyGraphicsPayload {
    case png(Data)
    case rgba(bytes: [UInt8], width: Int, height: Int)
}

struct KittyGraphicsImage {
    let payload: KittyGraphicsPayload
    let byteSize: Int
    var lastAccessTick: UInt64
}

struct KittyGraphicsPending {
    let control: KittyGraphicsControl
    var base64Payload: [UInt8]
}

/// A bounded, parser-owned snapshot of Kitty image payloads and their exact
/// retained-line placements. Applications can transfer this independently of
/// their text snapshot so image decoding never blocks first paint or input.
public struct TerminalKittyGraphicsSnapshot: Codable, Equatable, Sendable {
    public struct Image: Codable, Equatable, Sendable {
        public enum Payload: Codable, Equatable, Sendable {
            case png(Data)
            case rgba(Data, width: Int, height: Int)
        }

        public let id: UInt32
        public let number: UInt32?
        public let payload: Payload
    }

    public struct Placement: Codable, Equatable, Sendable {
        public let imageID: UInt32
        public let imageNumber: UInt32?
        public let placementID: UInt32
        public let column: Int
        public let relativeRow: Int
        public let columns: Int
        public let rows: Int
        public let zIndex: Int
        public let pixelOffsetX: Int
        public let pixelOffsetY: Int
    }

    public let version: Int
    public let retainedLineCount: Int
    public let images: [Image]
    public let placements: [Placement]

    public init(version: Int = 1, retainedLineCount: Int, images: [Image], placements: [Placement]) {
        self.version = version
        self.retainedLineCount = retainedLineCount
        self.images = images
        self.placements = placements
    }

    public var manifest: TerminalKittyGraphicsManifest {
        TerminalKittyGraphicsManifest(
            retainedLineCount: retainedLineCount,
            placements: placements
        )
    }

    public var payloads: TerminalKittyGraphicsPayloadSnapshot {
        TerminalKittyGraphicsPayloadSnapshot(images: images)
    }
}

/// Small placement-only state installed with the ANSI paint. Synthetic image
/// metadata then participates in ordinary scroll/delete/reflow operations while
/// the potentially large payload remains off the critical path.
public struct TerminalKittyGraphicsManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let retainedLineCount: Int
    public let placements: [TerminalKittyGraphicsSnapshot.Placement]

    public init(
        version: Int = 1,
        retainedLineCount: Int,
        placements: [TerminalKittyGraphicsSnapshot.Placement]
    ) {
        self.version = version
        self.retainedLineCount = retainedLineCount
        self.placements = placements
    }
}

/// Encoded image bytes delivered only after the renderer is interactive.
public struct TerminalKittyGraphicsPayloadSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let images: [TerminalKittyGraphicsSnapshot.Image]

    public init(version: Int = 1, images: [TerminalKittyGraphicsSnapshot.Image]) {
        self.version = version
        self.images = images
    }
}

/// Headless placeholder rows for Kitty placements. Internal (not private)
/// so the two-phase hosted transaction and view stripe installation can
/// recognize and replace them.
final class KittyHeadlessPlacementImage: KittyPlacementImage {
    var kittyIsKitty = true
    var kittyImageId: UInt32?
    var kittyImageNumber: UInt32?
    var kittyPlacementId: UInt32?
    var kittyZIndex = 0
    var kittyCol = 0
    var kittyRow = 0
    var kittyCols = 0
    var kittyRows = 0
    var kittyPixelOffsetX = 0
    var kittyPixelOffsetY = 0
    var col = 0
    var pixelWidth: Int { 0 }
    var pixelHeight: Int { 0 }
}

final class KittyGraphicsState {
    var imagesById: [UInt32: KittyGraphicsImage] = [:]
    var imageNumbers: [UInt32: UInt32] = [:]
    var nextImageId: UInt32 = 1
    var nextPlacementId: UInt32 = 1
    var pending: KittyGraphicsPending?
    var placementsByKey: [KittyPlacementKey: KittyPlacementRecord] = [:]
    var totalImageBytes: Int = 0
    var nextImageAccessTick: UInt64 = 1
    /// Retained precomputed-stripe bytes per hosted placement key. Only the
    /// two-phase install records costs here; legacy inline stripes are not
    /// tracked. Released on placement removal, buffer clears, and reset.
    var renderedStripeBytesByKey: [KittyPlacementKey: Int] = [:]
    var totalRenderedStripeBytes: Int = 0
    /// Live anonymous (untagged `a=T`) placement keys, oldest first.
    /// Anonymous placements carry ephemeral ids the client never learns, so
    /// they cannot be addressed for deletion; the parser evicts the oldest
    /// past the configured bound to keep the lifecycle strictly bounded.
    var anonymousPlacementKeys: [KittyPlacementKey] = []
}

extension Terminal {
    private static let kittyMaxImageBytes = 400 * 1024 * 1024
    private static let kittyMaxImageDimension = 10000
    private static let kittyMaxImageCacheBytes = 4 * 1024 * 1024 * 1024

    func handleKittyGraphics(_ data: ArraySlice<UInt8>) {
        guard let (control, payload) = parseKittyGraphicsControl(data) else {
            return
        }

        // Earliest strict gate for two-phase mode: only effective direct
        // transmit-and-display continues. Every other workflow rejects in
        // order here, before partial payload mutation, reassembly copies,
        // or placement state changes, so a rejection retains zero bytes,
        // jobs, or state. Flag-off behavior is unchanged below.
        if options.hostedKittyTwoPhaseRendering {
            guard control.action == "T", control.transmission == "d" else {
                sendStrictHostedRejection(control: control)
                return
            }
        } else if control.action == "d" || control.action == "D" {
            kittyGraphicsState.pending = nil
        }

        if control.more == 1 {
            // Bounded partial transfers while two-phase rendering is enabled:
            // every chunk append is admitted before mutation so an open m=1
            // transfer cannot retain unbounded bytes inside the terminal.
            // The legacy path is unchanged when the flag is off.
            if options.hostedKittyTwoPhaseRendering {
                let limits = hostedKittyLimits()
                let current = kittyGraphicsState.pending?.base64Payload.count ?? 0
                guard hostedEncodedFits(current: current, additional: payload.count, limit: limits.maxPartialEncodedBytes) else {
                    kittyGraphicsState.pending = nil
                    sendKittyError(control: control, message: "EOVERFLOW: hosted transfer too large")
                    return
                }
            }
            if kittyGraphicsState.pending == nil {
                kittyGraphicsState.pending = KittyGraphicsPending(control: control, base64Payload: Array(payload))
            } else {
                kittyGraphicsState.pending?.base64Payload.append(contentsOf: payload)
            }
            return
        }

        if var pending = kittyGraphicsState.pending {
            // Final reassembly is capped before the copy, using the same
            // subtractive bound as chunk appends; downstream admission then
            // re-checks the total without ever holding an over-limit copy.
            if options.hostedKittyTwoPhaseRendering {
                let limits = hostedKittyLimits()
                guard hostedEncodedFits(current: pending.base64Payload.count, additional: payload.count, limit: limits.maxPartialEncodedBytes) else {
                    kittyGraphicsState.pending = nil
                    sendKittyError(control: pending.control, message: "EOVERFLOW: hosted transfer too large")
                    return
                }
            }
            pending.base64Payload.append(contentsOf: payload)
            kittyGraphicsState.pending = nil
            processKittyGraphics(control: pending.control, base64Payload: pending.base64Payload)
            return
        }

        // Standalone payloads are capped before the Array copy for the same
        // reason; the legacy path is unchanged when the flag is off.
        if options.hostedKittyTwoPhaseRendering {
            let limits = hostedKittyLimits()
            guard hostedEncodedFits(current: 0, additional: payload.count, limit: limits.maxPartialEncodedBytes) else {
                sendKittyError(control: control, message: "EOVERFLOW: hosted transfer too large")
                return
            }
        }
        processKittyGraphics(control: control, base64Payload: Array(payload))
    }

    private func parseKittyGraphicsControl(_ data: ArraySlice<UInt8>) -> (KittyGraphicsControl, ArraySlice<UInt8>)? {
        let separator = data.firstIndex(of: UInt8(ascii: ";"))
        let controlBytes: ArraySlice<UInt8>
        let payload: ArraySlice<UInt8>
        if let separator = separator {
            controlBytes = data[data.startIndex..<separator]
            payload = data[(separator+1)..<data.endIndex]
        } else {
            controlBytes = data
            payload = data[data.endIndex..<data.endIndex]
        }

        var values: [String: String] = [:]
        var start = controlBytes.startIndex
        while start < controlBytes.endIndex {
            let end = controlBytes[start..<controlBytes.endIndex].firstIndex(of: UInt8(ascii: ",")) ?? controlBytes.endIndex
            let chunk = controlBytes[start..<end]
            if let eq = chunk.firstIndex(of: UInt8(ascii: "=")) {
                let keyBytes = chunk[chunk.startIndex..<eq]
                let valueBytes = chunk[(eq+1)..<chunk.endIndex]
                if let key = String(bytes: keyBytes, encoding: .ascii),
                   let value = String(bytes: valueBytes, encoding: .ascii) {
                    values[key] = value
                }
            }
            start = end == controlBytes.endIndex ? end : end + 1
        }

        func intValue(_ key: String, default value: Int = 0) -> Int {
            guard let raw = values[key], let val = Int(raw) else {
                return value
            }
            return val
        }

        func uintValue(_ key: String) -> UInt32? {
            guard let raw = values[key], let val = UInt32(raw), val > 0 else {
                return nil
            }
            return val
        }

        func charValue(_ key: String, default value: Character) -> Character {
            guard let raw = values[key], let ch = raw.first else {
                return value
            }
            return ch
        }

        let action = charValue("a", default: "t")
        let suppressResponses = intValue("q", default: 0)
        let format = intValue("f", default: 32)
        let transmission = charValue("t", default: "d")
        let width = intValue("s", default: 0)
        let height = intValue("v", default: 0)
        let cropX = intValue("x", default: 0)
        let cropY = intValue("y", default: 0)
        let cropWidth = intValue("w", default: 0)
        let cropHeight = intValue("h", default: 0)
        let imageId = uintValue("i")
        let imageNumber = uintValue("I")
        let placementId = uintValue("p")
        let parentImageId = uintValue("P")
        let parentPlacementId = uintValue("Q")
        let offsetH = intValue("H", default: 0)
        let offsetV = intValue("V", default: 0)
        let pixelOffsetX = intValue("X", default: 0)
        let pixelOffsetY = intValue("Y", default: 0)
        let unicodePlaceholder = intValue("U", default: 0)
        let zIndex = intValue("z", default: 0)
        var more = intValue("m", default: 0)
        let compression = values["o"]?.first
        let columns = intValue("c", default: 0)
        let rows = intValue("r", default: 0)
        let cursorPolicy = intValue("C", default: 0)
        let deleteMode = values["d"]?.first
        let dataSize = intValue("S", default: 0)
        let dataOffset = intValue("O", default: 0)

        if transmission != "d" {
            more = 0
        }

        let control = KittyGraphicsControl(action: action,
                                           suppressResponses: suppressResponses,
                                           format: format,
                                           transmission: transmission,
                                           width: width,
                                           height: height,
                                           cropX: cropX,
                                           cropY: cropY,
                                           cropWidth: cropWidth,
                                           cropHeight: cropHeight,
                                           dataSize: dataSize,
                                           dataOffset: dataOffset,
                                           imageId: imageId,
                                           imageNumber: imageNumber,
                                           placementId: placementId,
                                           parentImageId: parentImageId,
                                           parentPlacementId: parentPlacementId,
                                           offsetH: offsetH,
                                           offsetV: offsetV,
                                           pixelOffsetX: pixelOffsetX,
                                           pixelOffsetY: pixelOffsetY,
                                           unicodePlaceholder: unicodePlaceholder,
                                           zIndex: zIndex,
                                           more: more,
                                           compression: compression,
                                           columns: columns,
                                           rows: rows,
                                           cursorPolicy: cursorPolicy,
                                           deleteMode: deleteMode)
        return (control, payload)
    }

    private func processKittyGraphics(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        switch control.action {
        case "q":
            handleKittyQuery(control: control, base64Payload: base64Payload)
        case "t", "T":
            handleKittyTransmit(control: control, base64Payload: base64Payload, display: control.action == "T")
        case "p":
            handleKittyPut(control: control)
        case "d", "D":
            handleKittyDelete(control: control)
        default:
            sendKittyError(control: control, message: "EINVAL: unsupported action")
        }
    }

    /// Typed in-order rejection for workflows the strict hosted profile does
    /// not retain. Known Kitty actions get ENOTSUP (no synchronous decode,
    /// file I/O, scaling, stripe rendering, or placement mutation exists for
    /// them in hosted mode); unknown actions keep the legacy EINVAL.
    /// Called before any payload or placement mutation, so rejections retain
    /// zero bytes, jobs, or state.
    private func sendStrictHostedRejection(control: KittyGraphicsControl) {
        switch control.action {
        case "q", "t", "T", "p", "d", "D":
            sendKittyError(control: control, message: "ENOTSUP: hosted mode supports only direct transmit-and-display (a=T,t=d)")
        default:
            sendKittyError(control: control, message: "EINVAL: unsupported action")
        }
    }

    private func handleKittyQuery(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        guard decodeKittyPayload(control: control, base64Payload: base64Payload) != nil else {
            sendKittyError(control: control, message: "EINVAL: bad payload")
            return
        }
        sendKittyOk(control: control, imageId: control.imageId, imageNumber: control.imageNumber, placementId: control.placementId)
    }

    private func handleKittyTransmit(control: KittyGraphicsControl, base64Payload: [UInt8], display: Bool) {
        guard control.imageId == nil || control.imageNumber == nil else {
            sendKittyError(control: control, message: "EINVAL: i and I are mutually exclusive")
            return
        }
        // Two-phase mode pre-gates at handleKittyGraphics, so reaching here
        // with the flag on always means effective direct transmit-and-display.
        // After validation: the deferred path must accept exactly what the
        // inline path accepts, so shared guards stay above this line.
        if display, options.hostedKittyTwoPhaseRendering {
            handleHostedKittyTransmitDirect(control: control, base64Payload: base64Payload)
            return
        }

        let payloadResult = loadKittyPayload(control: control, base64Payload: base64Payload)
        if let errorMessage = payloadResult.errorMessage {
            sendKittyError(control: control, message: errorMessage)
            return
        }
        guard let payload = payloadResult.payload else {
            sendKittyError(control: control, message: "EINVAL: bad payload")
            return
        }
        handleKittyTransmitPayload(control: control, payload: payload, display: display)
    }

    private func handleKittyTransmitPayload(control: KittyGraphicsControl, payload: KittyGraphicsPayload, display: Bool) {
        let resolved = resolveKittyImageId(control: control)
        if let error = resolved.errorMessage {
            sendKittyError(control: control, message: error)
            return
        }

        if let id = resolved.imageId {
            storeKittyImage(payload: payload, imageId: id, imageNumber: resolved.imageNumber)
        }

        var displayed = true
        if display {
            displayed = displayKittyImage(payload: payload, control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber)
        }

        if resolved.shouldReply && displayed {
            sendKittyOk(control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber, placementId: control.placementId)
        }
    }

    private func handleKittyPut(control: KittyGraphicsControl) {
        let resolved = resolveKittyImageForDisplay(control: control)
        guard let image = resolved.image else {
            sendKittyError(control: control, message: "ENOENT: image not found")
            return
        }

        let displayed = displayKittyImage(payload: image.payload, control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber)

        if resolved.shouldReply && displayed {
            sendKittyOk(control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber, placementId: control.placementId)
        }
    }

    private func handleKittyDelete(control: KittyGraphicsControl) {
        let mode = control.deleteMode ?? "a"
        let freesData = String(mode).uppercased() == String(mode)
        switch String(mode).lowercased() {
        case "a":
            deletePlacementsVisibleOnScreen()
        case "i":
            guard let imageId = control.imageId else {
                sendKittyError(control: control, message: "EINVAL: missing image id")
                return
            }
            deletePlacementsByImageId(imageId: imageId, placementId: control.placementId)
        case "n":
            guard let imageNumber = control.imageNumber else {
                sendKittyError(control: control, message: "EINVAL: missing image number")
                return
            }
            deletePlacementsByImageNumber(imageNumber: imageNumber, placementId: control.placementId)
        case "c":
            deletePlacementsAtCell(col: buffer.x + 1, row: buffer.y + 1, zIndex: nil)
        case "p":
            guard control.cropX > 0, control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing cell position")
                return
            }
            deletePlacementsAtCell(col: control.cropX, row: control.cropY, zIndex: nil)
        case "q":
            guard control.cropX > 0, control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing cell position")
                return
            }
            deletePlacementsAtCell(col: control.cropX, row: control.cropY, zIndex: control.zIndex)
        case "x":
            guard control.cropX > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing column")
                return
            }
            deletePlacementsInColumn(control.cropX)
        case "y":
            guard control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing row")
                return
            }
            deletePlacementsInRow(control.cropY)
        case "z":
            deletePlacementsWithZIndex(control.zIndex)
        case "r":
            guard control.cropX > 0, control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing id range")
                return
            }
            // Exact conversion: ids outside UInt32 range reject instead of
            // trapping on untrusted control ints.
            guard let minId = UInt32(exactly: min(control.cropX, control.cropY)),
                  let maxId = UInt32(exactly: max(control.cropX, control.cropY)) else {
                sendKittyError(control: control, message: "EINVAL: bad id range")
                return
            }
            deletePlacementsByImageIdRange(minId: minId, maxId: maxId)
        default:
            sendKittyError(control: control, message: "EINVAL: unsupported delete")
        }
        if freesData {
            cleanupUnusedKittyImages()
        }
    }

    private func resolveKittyImageId(control: KittyGraphicsControl) -> (imageId: UInt32?, imageNumber: UInt32?, shouldReply: Bool, errorMessage: String?) {
        if let number = control.imageNumber {
            let newId = kittyGraphicsState.nextImageId
            kittyGraphicsState.nextImageId &+= 1
            return (newId, number, control.suppressResponses == 0, nil)
        }

        if let id = control.imageId {
            return (id, nil, control.suppressResponses == 0, nil)
        }

        return (nil, nil, false, nil)
    }

    private func resolveKittyImageForDisplay(control: KittyGraphicsControl) -> (image: KittyGraphicsImage?, imageId: UInt32?, imageNumber: UInt32?, shouldReply: Bool) {
        if let number = control.imageNumber, let imageId = kittyGraphicsState.imageNumbers[number], let image = updateKittyImageAccess(imageId: imageId) {
            return (image, imageId, number, control.suppressResponses == 0)
        }
        if let imageId = control.imageId, let image = updateKittyImageAccess(imageId: imageId) {
            return (image, imageId, nil, control.suppressResponses == 0)
        }
        return (nil, nil, nil, control.suppressResponses == 0)
    }

    private func decodeKittyPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> KittyGraphicsPayload? {
        if base64Payload.isEmpty {
            return nil
        }
        guard let decoded = decodeKittyBase64Payload(base64Payload), decoded.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        guard let rawData = decompressKittyData(decoded, compression: control.compression),
              rawData.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        return decodeKittyPayloadData(control: control, rawData: rawData)
    }

    private func cropRgba(bytes: [UInt8], width: Int, height: Int, x: Int, y: Int, w: Int, h: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        let startX = max(0, min(x, width))
        let startY = max(0, min(y, height))
        let maxWidth = width - startX
        let maxHeight = height - startY
        let cropWidth = max(0, min(w > 0 ? w : maxWidth, maxWidth))
        let cropHeight = max(0, min(h > 0 ? h : maxHeight, maxHeight))

        if cropWidth == width && cropHeight == height && startX == 0 && startY == 0 {
            return (bytes, width, height)
        }
        if cropWidth <= 0 || cropHeight <= 0 {
            return nil
        }

        var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        let srcRowBytes = width * 4
        let dstRowBytes = cropWidth * 4
        for row in 0..<cropHeight {
            let srcIndex = (startY + row) * srcRowBytes + startX * 4
            let dstIndex = row * dstRowBytes
            cropped.replaceSubrange(dstIndex..<(dstIndex + dstRowBytes), with: bytes[srcIndex..<(srcIndex + dstRowBytes)])
        }
        return (cropped, cropWidth, cropHeight)
    }

    private func decodePngToRgba(_ data: Data) -> (bytes: [UInt8], width: Int, height: Int)? {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard validateKittyDimensions(width: width, height: height) else {
            return nil
        }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var output = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &output,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (output, width, height)
        #else
        return nil
        #endif
    }

    private func kittyPngPixelSize(data: Data) -> (width: Int, height: Int)? {
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

    private func kittyPlacementGridSize(payload: KittyGraphicsPayload,
                                        widthRequest: ImageSizeRequest,
                                        heightRequest: ImageSizeRequest,
                                        preserveAspectRatio: Bool,
                                        cellSize: (width: Int, height: Int)?,
                                        pixelOffsetX: Int,
                                        pixelOffsetY: Int) -> (cols: Int, rows: Int)? {
        if case .cells(let cols) = widthRequest,
           case .cells(let rows) = heightRequest {
            return (max(1, cols), max(1, rows))
        }

        guard let cellSize else {
            return nil
        }

        let imageSize: (width: Int, height: Int)?
        switch payload {
        case .rgba(_, let width, let height):
            imageSize = (width, height)
        case .png(let data):
            imageSize = kittyPngPixelSize(data: data)
        }
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let aspect = Double(imageSize.width) / Double(imageSize.height)
        var widthPx: Double
        var heightPx: Double

        switch widthRequest {
        case .auto:
            widthPx = Double(imageSize.width)
        case .cells(let cols):
            widthPx = Double(cols * cellSize.width)
        case .pixels(let px):
            widthPx = Double(px)
        case .percent:
            return nil
        }

        switch heightRequest {
        case .auto:
            heightPx = Double(imageSize.height)
        case .cells(let rows):
            heightPx = Double(rows * cellSize.height)
        case .pixels(let px):
            heightPx = Double(px)
        case .percent:
            return nil
        }

        if preserveAspectRatio {
            switch (widthRequest, heightRequest) {
            case (.auto, .auto):
                break
            case (.auto, _):
                widthPx = heightPx * aspect
            case (_, .auto):
                heightPx = widthPx / aspect
            default:
                break
            }
        }

        let cols = Int(ceil((widthPx + Double(pixelOffsetX)) / Double(cellSize.width)))
        let rows = Int(ceil((heightPx + Double(pixelOffsetY)) / Double(cellSize.height)))
        return (max(1, cols), max(1, rows))
    }

    private func applyKittyCursorMovement(startCol: Int, startRow: Int, cols: Int, rows: Int, useIndex: Bool) {
        if useIndex {
            buffer.x = startCol
            buffer.y = startRow - buffer.yBase
            for _ in 0..<rows {
                cmdIndex()
            }
            buffer.x = startCol + cols
        } else {
            buffer.x = startCol + cols
            buffer.y = startRow + rows - buffer.yBase
        }
        restrictCursor()
    }

    private func loadKittyPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        switch control.transmission {
        case "d":
            guard let payload = decodeKittyPayload(control: control, base64Payload: base64Payload) else {
                return (nil, "EINVAL: bad payload")
            }
            return (payload, nil)
        case "f":
            return loadKittyFilePayload(control: control, base64Payload: base64Payload, temporary: false)
        case "t":
            return loadKittyFilePayload(control: control, base64Payload: base64Payload, temporary: true)
        case "s":
            return loadKittySharedMemoryPayload(control: control, base64Payload: base64Payload)
        default:
            return (nil, "ENOTSUP: unsupported transmission")
        }
    }

    private func decodeKittyPayloadData(control: KittyGraphicsControl, rawData: Data) -> KittyGraphicsPayload? {
        guard rawData.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        switch control.format {
        case 100:
            guard validateKittyPngDimensions(data: rawData) else {
                return nil
            }
            return .png(rawData)
        case 24:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 3) else {
                return nil
            }
            let expected = control.width * control.height * 3
            guard rawData.count == expected else {
                return nil
            }
            // Checked expansion cost before allocating the RGBA buffer: the
            // source check above bounds 3-byte pixels, not the 4-byte output.
            guard Int64(control.width) * Int64(control.height) * 4 <= Int64(Terminal.kittyMaxImageBytes) else {
                return nil
            }
            var rgba = [UInt8]()
            rgba.reserveCapacity(control.width * control.height * 4)
            var idx = rawData.startIndex
            while idx < rawData.endIndex {
                let r = rawData[idx]
                let g = rawData[rawData.index(after: idx)]
                let b = rawData[rawData.index(idx, offsetBy: 2)]
                rgba.append(r)
                rgba.append(g)
                rgba.append(b)
                rgba.append(255)
                idx = rawData.index(idx, offsetBy: 3)
            }
            return .rgba(bytes: rgba, width: control.width, height: control.height)
        case 32:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 4) else {
                return nil
            }
            let expected = control.width * control.height * 4
            guard rawData.count == expected else {
                return nil
            }
            return .rgba(bytes: [UInt8](rawData), width: control.width, height: control.height)
        default:
            return nil
        }
    }

    private func decodeKittyBase64Payload(_ payload: [UInt8]) -> Data? {
        Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters)
    }

    private func decompressKittyData(_ data: Data, compression: Character?) -> Data? {
        guard let compression else {
            return data
        }
        guard compression == "z" else {
            return nil
        }
        guard let inflated = decompressZlib(data), inflated.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }
        return inflated
    }

    private func validateKittyDimensions(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }
        return width <= Terminal.kittyMaxImageDimension && height <= Terminal.kittyMaxImageDimension
    }

    private func validateKittyRawDimensions(width: Int, height: Int, bytesPerPixel: Int) -> Bool {
        guard validateKittyDimensions(width: width, height: height) else {
            return false
        }
        let pixelCount = Int64(width) * Int64(height)
        let limit = Int64(Terminal.kittyMaxImageBytes) / Int64(bytesPerPixel)
        return pixelCount <= limit
    }

    private func validateKittyPngDimensions(data: Data) -> Bool {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }
        return validateKittyDimensions(width: width, height: height)
        #else
        return true
        #endif
    }

    private func loadKittyFilePayload(control: KittyGraphicsControl, base64Payload: [UInt8], temporary: Bool) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        #if os(Windows)
        return (nil, "ENOTSUP: unsupported transmission")
        #else
        guard let pathData = decodeKittyBase64Payload(base64Payload), !pathData.isEmpty else {
            return (nil, "EINVAL: bad payload")
        }
        guard !pathData.contains(0) else {
            return (nil, "EINVAL: bad path")
        }
        guard let path = String(data: pathData, encoding: .utf8),
              let resolved = resolveKittyRealPath(path) else {
            return (nil, "EINVAL: bad path")
        }
        guard isKittySafePath(resolved) else {
            return (nil, "EINVAL: bad path")
        }
        if temporary {
            guard isKittyTempPath(resolved) else {
                return (nil, "EINVAL: bad temp path")
            }
            guard resolved.contains("tty-graphics-protocol") else {
                return (nil, "EINVAL: bad temp path")
            }
        }

        guard let data = readKittyFileData(path: resolved,
                                           offset: control.dataOffset,
                                           size: control.dataSize,
                                           deleteAfterRead: temporary) else {
            return (nil, "EINVAL: bad payload")
        }

        guard let rawData = decompressKittyData(data, compression: control.compression),
              rawData.count <= Terminal.kittyMaxImageBytes else {
            return (nil, "EINVAL: bad payload")
        }
        guard let payload = decodeKittyPayloadData(control: control, rawData: rawData) else {
            return (nil, "EINVAL: bad payload")
        }
        return (payload, nil)
        #endif
    }

    private func loadKittySharedMemoryPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        #if os(Windows)
        return (nil, "ENOTSUP: unsupported transmission")
        #else
        guard let pathData = decodeKittyBase64Payload(base64Payload), !pathData.isEmpty else {
            return (nil, "EINVAL: bad payload")
        }
        guard !pathData.contains(0) else {
            return (nil, "EINVAL: bad payload")
        }
        guard let name = String(data: pathData, encoding: .utf8) else {
            return (nil, "EINVAL: bad payload")
        }

        let expectedSize = kittyExpectedDataSize(control: control)
        if control.format != 100, expectedSize == nil {
            return (nil, "EINVAL: bad payload")
        }

        guard let data = readKittySharedMemory(name: name,
                                               expectedSize: expectedSize,
                                               offset: control.dataOffset,
                                               size: control.dataSize) else {
            return (nil, "EINVAL: bad payload")
        }
        guard let rawData = decompressKittyData(data, compression: control.compression),
              rawData.count <= Terminal.kittyMaxImageBytes else {
            return (nil, "EINVAL: bad payload")
        }
        guard let payload = decodeKittyPayloadData(control: control, rawData: rawData) else {
            return (nil, "EINVAL: bad payload")
        }
        return (payload, nil)
        #endif
    }

    private func kittyExpectedDataSize(control: KittyGraphicsControl) -> Int? {
        switch control.format {
        case 100:
            return nil
        case 24:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 3) else {
                return nil
            }
            return control.width * control.height * 3
        case 32:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 4) else {
                return nil
            }
            return control.width * control.height * 4
        default:
            return nil
        }
    }

    #if os(Windows)
    private func resolveKittyRealPath(_ path: String) -> String? {
        nil
    }
    #else
    private func resolveKittyRealPath(_ path: String) -> String? {
        return path.withCString { cstr -> String? in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(cstr, &buffer) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }
    #endif

    private func isKittySafePath(_ path: String) -> Bool {
        if path.hasPrefix("/proc/") || path.hasPrefix("/sys/") {
            return false
        }
        if path.hasPrefix("/dev/") && !path.hasPrefix("/dev/shm/") {
            return false
        }
        return true
    }

    private func isKittyTempPath(_ path: String) -> Bool {
        if path.hasPrefix("/tmp") || path.hasPrefix("/dev/shm") {
            return true
        }
        let tempDir = FileManager.default.temporaryDirectory.path
        if path.hasPrefix(tempDir) {
            return true
        }
        if let resolved = resolveKittyRealPath(tempDir), path.hasPrefix(resolved) {
            return true
        }
        return false
    }

    #if !os(Windows)
    private func readKittyFileData(path: String, offset: Int, size: Int, deleteAfterRead: Bool) -> Data? {
        guard offset >= 0, size >= 0 else {
            return nil
        }
        var st = stat()
        let statResult = path.withCString { stat($0, &st) }
        guard statResult == 0 else {
            return nil
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        let fileSize = Int64(st.st_size)
        guard fileSize >= 0 else {
            return nil
        }
        if fileSize > Int64(Terminal.kittyMaxImageBytes) {
            return nil
        }
        if Int64(offset) > fileSize {
            return nil
        }
        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            close(fd)
            if deleteAfterRead {
                _ = path.withCString { unlink($0) }
            }
        }

        if offset > 0 {
            let seekResult = lseek(fd, off_t(offset), SEEK_SET)
            guard seekResult >= 0 else {
                return nil
            }
        }

        let maxRead = size > 0 ? min(size, Terminal.kittyMaxImageBytes) : Terminal.kittyMaxImageBytes
        let remaining = min(Int64(maxRead), fileSize - Int64(offset))
        if remaining <= 0 {
            return Data()
        }

        var data = Data()
        data.reserveCapacity(Int(remaining))
        var buffer = [UInt8](repeating: 0, count: 4096)
        var bytesLeft = remaining

        while bytesLeft > 0 {
            let chunkSize = min(buffer.count, Int(bytesLeft))
            let readCount = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else {
                    return -1
                }
                return read(fd, base, chunkSize)
            }
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
            bytesLeft -= Int64(readCount)
        }
        return data
    }
    #endif

    #if !os(Windows)
    private func readKittySharedMemory(name: String, expectedSize: Int?, offset: Int, size: Int) -> Data? {
        guard offset >= 0, size >= 0 else {
            return nil
        }
        var fd: Int32 = -1
        let openResult = name.withCString { swiftShmOpen($0, O_RDONLY, 0) }
        fd = openResult
        guard fd >= 0 else {
            return nil
        }
        defer {
            close(fd)
            _ = name.withCString { shm_unlink($0) }
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return nil
        }
        let statSize = Int(st.st_size)
        guard statSize > 0 else {
            return nil
        }
        if statSize > Terminal.kittyMaxImageBytes {
            return nil
        }
        if let expectedSize, statSize < expectedSize {
            return nil
        }
        let effectiveExpectedSize = expectedSize ?? statSize

        let start = offset
        let end: Int
        if size > 0 {
            end = min(offset + size, effectiveExpectedSize)
        } else {
            end = effectiveExpectedSize
        }
        guard start < end, end <= statSize else {
            return nil
        }

        guard let map = mmap(nil, statSize, PROT_READ, MAP_SHARED, fd, 0),
              map != MAP_FAILED else {
            return nil
        }
        defer {
            munmap(map, statSize)
        }

        let startPtr = map.advanced(by: start)
        return Data(bytes: startPtr, count: end - start)
    }
    #endif

    private func displayKittyImage(payload: KittyGraphicsPayload, control: KittyGraphicsControl, imageId: UInt32?, imageNumber: UInt32?) -> Bool {
        if control.unicodePlaceholder == 1 {
            if control.parentImageId != nil || control.parentPlacementId != nil {
                sendKittyError(control: control, message: "EINVAL: virtual placement cannot refer to parent")
                return false
            }
            if let imageId = imageId {
                let origin = resolveKittyPlacementOrigin(control: control)
                if let errorMessage = origin.errorMessage {
                    sendKittyError(control: control, message: errorMessage)
                    return false
                }
                let placementId = control.placementId ?? nextKittyPlacementId()
                removeKittyPlacement(imageId: imageId, placementId: placementId)
                let col = origin.col ?? buffer.x
                let row = origin.row ?? (buffer.y + buffer.yBase)
                let cols = control.columns > 0 ? control.columns : 0
                let rows = control.rows > 0 ? control.rows : 0
                var pixelOffsetX = control.pixelOffsetX
                var pixelOffsetY = control.pixelOffsetY
                if pixelOffsetX < 0 { pixelOffsetX = 0 }
                if pixelOffsetY < 0 { pixelOffsetY = 0 }
                if (pixelOffsetX != 0 || pixelOffsetY != 0),
                   let cellSize = tdel?.cellSizeInPixels(source: self) {
                    let maxX = max(0, cellSize.width - 1)
                    let maxY = max(0, cellSize.height - 1)
                    pixelOffsetX = min(pixelOffsetX, maxX)
                    pixelOffsetY = min(pixelOffsetY, maxY)
                }
                registerKittyPlacement(imageId: imageId,
                                       placementId: placementId,
                                       parentImageId: nil,
                                       parentPlacementId: nil,
                                       parentOffsetH: 0,
                                       parentOffsetV: 0,
                                       pixelOffsetX: pixelOffsetX,
                                       pixelOffsetY: pixelOffsetY,
                                       col: col,
                                       row: row,
                                       cols: cols,
                                       rows: rows,
                                       zIndex: control.zIndex,
                                       isVirtual: true)
            }
            return true
        }

        let widthRequest: ImageSizeRequest = control.columns > 0 ? .cells(control.columns) : .auto
        let heightRequest: ImageSizeRequest = control.rows > 0 ? .cells(control.rows) : .auto
        let preserveAspectRatio = control.columns == 0 || control.rows == 0
        let cropRequested = control.cropX != 0 || control.cropY != 0 || control.cropWidth != 0 || control.cropHeight != 0
        var displayPayload = payload
        let origin = resolveKittyPlacementOrigin(control: control)
        if let errorMessage = origin.errorMessage {
            sendKittyError(control: control, message: errorMessage)
            return false
        }
        if cropRequested {
            switch payload {
            case .rgba(let bytes, let width, let height):
                guard let cropped = cropRgba(bytes: bytes,
                                             width: width,
                                             height: height,
                                             x: control.cropX,
                                             y: control.cropY,
                                             w: control.cropWidth,
                                             h: control.cropHeight) else {
                    sendKittyError(control: control, message: "EINVAL: bad crop")
                    return false
                }
                displayPayload = .rgba(bytes: cropped.bytes, width: cropped.width, height: cropped.height)
            case .png(let data):
                guard let rgba = decodePngToRgba(data) else {
                    sendKittyError(control: control, message: "ENOTSUP: cannot crop png")
                    return false
                }
                guard let cropped = cropRgba(bytes: rgba.bytes,
                                             width: rgba.width,
                                             height: rgba.height,
                                             x: control.cropX,
                                             y: control.cropY,
                                             w: control.cropWidth,
                                             h: control.cropHeight) else {
                    sendKittyError(control: control, message: "EINVAL: bad crop")
                    return false
                }
                displayPayload = .rgba(bytes: cropped.bytes, width: cropped.width, height: cropped.height)
            }
        }
        var pixelOffsetX = control.pixelOffsetX
        var pixelOffsetY = control.pixelOffsetY
        if pixelOffsetX < 0 { pixelOffsetX = 0 }
        if pixelOffsetY < 0 { pixelOffsetY = 0 }
        if (pixelOffsetX != 0 || pixelOffsetY != 0),
           let cellSize = tdel?.cellSizeInPixels(source: self) {
            let maxX = max(0, cellSize.width - 1)
            let maxY = max(0, cellSize.height - 1)
            pixelOffsetX = min(pixelOffsetX, maxX)
            pixelOffsetY = min(pixelOffsetY, maxY)
        }

        let resolvedPlacementId = control.placementId ?? nextKittyPlacementId()
        kittyPlacementContext = KittyPlacementContext(imageId: imageId ?? control.imageId,
                                                      imageNumber: imageNumber ?? control.imageNumber,
                                                      placementId: resolvedPlacementId,
                                                      parentImageId: control.parentImageId,
                                                      parentPlacementId: control.parentPlacementId,
                                                      parentOffsetH: control.offsetH,
                                                      parentOffsetV: control.offsetV,
                                                      zIndex: control.zIndex,
                                                      widthRequest: widthRequest,
                                                      heightRequest: heightRequest,
                                                      preserveAspectRatio: preserveAspectRatio,
                                                      cursorPolicy: control.cursorPolicy,
                                                      isRelative: origin.isRelative,
                                                      pixelOffsetX: pixelOffsetX,
                                                      pixelOffsetY: pixelOffsetY)
        defer {
            kittyPlacementContext = nil
        }
        let savedX = buffer.x
        let savedY = buffer.y

        if let imageId = imageId {
            removeKittyPlacement(imageId: imageId, placementId: resolvedPlacementId)
        }

        if let col = origin.col, let row = origin.row {
            let targetRow = row - buffer.yBase
            if targetRow >= 0 && targetRow < buffer.lines.count {
                buffer.y = targetRow
                buffer.x = max(0, min(col, cols - 1))
            } else {
                sendKittyError(control: control, message: "EINVAL: placement out of range")
                return false
            }
        }

        let placementCol = buffer.x
        let placementRow = buffer.y + buffer.yBase

        switch displayPayload {
        case .png(let data):
            tdel?.createImage(source: self, data: data, width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
        case .rgba(var bytes, let width, let height):
            tdel?.createImageFromBitmap(source: self, bytes: &bytes, width: width, height: height)
        }

        // Headless terminals have no image renderer, but still need parsed
        // placement state to remain authoritative. Synthetic line metadata is
        // scrolled and trimmed by Buffer exactly like rendered image stripes.
        if let imageId,
           kittyGraphicsState.placementsByKey[KittyPlacementKey(imageId: imageId, placementId: resolvedPlacementId)] == nil,
           let grid = kittyPlacementGridSize(payload: displayPayload,
                                             widthRequest: widthRequest,
                                             heightRequest: heightRequest,
                                             preserveAspectRatio: preserveAspectRatio,
                                             cellSize: tdel?.cellSizeInPixels(source: self),
                                             pixelOffsetX: pixelOffsetX,
                                             pixelOffsetY: pixelOffsetY) {
            registerKittyPlacement(imageId: imageId,
                                   placementId: resolvedPlacementId,
                                   parentImageId: control.parentImageId,
                                   parentPlacementId: control.parentPlacementId,
                                   parentOffsetH: control.offsetH,
                                   parentOffsetV: control.offsetV,
                                   pixelOffsetX: pixelOffsetX,
                                   pixelOffsetY: pixelOffsetY,
                                   col: placementCol,
                                   row: placementRow,
                                   cols: grid.cols,
                                   rows: grid.rows,
                                   zIndex: control.zIndex,
                                   isVirtual: false)
            for rowOffset in 0..<grid.rows {
                let targetRow = placementRow + rowOffset
                guard targetRow >= 0, targetRow < buffer.lines.count else { continue }
                let placeholder = KittyHeadlessPlacementImage()
                placeholder.kittyImageId = imageId
                placeholder.kittyImageNumber = imageNumber
                placeholder.kittyPlacementId = resolvedPlacementId
                placeholder.kittyZIndex = control.zIndex
                placeholder.kittyCol = placementCol
                placeholder.kittyRow = placementRow
                placeholder.kittyCols = grid.cols
                placeholder.kittyRows = grid.rows
                placeholder.kittyPixelOffsetX = pixelOffsetX
                placeholder.kittyPixelOffsetY = pixelOffsetY
                placeholder.col = placementCol
                buffer.attachImage(placeholder, toLineAt: targetRow)
            }
        }

        if origin.isRelative || control.cursorPolicy == 1 {
            buffer.x = savedX
            buffer.y = savedY
        } else if let grid = kittyPlacementGridSize(payload: displayPayload,
                                                    widthRequest: widthRequest,
                                                    heightRequest: heightRequest,
                                                    preserveAspectRatio: preserveAspectRatio,
                                                    cellSize: tdel?.cellSizeInPixels(source: self),
                                                    pixelOffsetX: pixelOffsetX,
                                                    pixelOffsetY: pixelOffsetY) {
            let moveCols = max(1, grid.cols)
            let moveRows = max(1, grid.rows)
            let useIndex = tdel?.cellSizeInPixels(source: self) == nil
            applyKittyCursorMovement(startCol: placementCol,
                                     startRow: placementRow,
                                     cols: moveCols,
                                     rows: moveRows,
                                     useIndex: useIndex)
        }
        return true
    }

    private func resolveKittyPlacementOrigin(control: KittyGraphicsControl) -> (col: Int?, row: Int?, isRelative: Bool, errorMessage: String?) {
        guard let parentImageId = control.parentImageId, let parentPlacementId = control.parentPlacementId else {
            return (nil, nil, false, nil)
        }
        let key = KittyPlacementKey(imageId: parentImageId, placementId: parentPlacementId)
        guard let parent = kittyGraphicsState.placementsByKey[key] else {
            return (nil, nil, true, "ENOPARENT: parent placement not found")
        }
        if parent.isAlternateBuffer != isCurrentBufferAlternate {
            return (nil, nil, true, "ENOPARENT: parent placement not in current buffer")
        }
        let positions = collectKittyPlacementPositions(in: buffer)
        var resolved: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var visiting: Set<KittyPlacementKey> = []
        guard let parentPosition = resolveKittyPlacementPosition(for: key,
                                                                 positions: positions,
                                                                 resolved: &resolved,
                                                                 visiting: &visiting) else {
            return (nil, nil, true, "ENOPARENT: parent placement not found")
        }
        // Checked parent-relative arithmetic: untrusted H/V offsets must
        // never trap. Overflows reject before any placement mutation.
        let (col, colOverflow) = parentPosition.col.addingReportingOverflow(control.offsetH)
        let (row, rowOverflow) = parentPosition.row.addingReportingOverflow(control.offsetV)
        guard !colOverflow, !rowOverflow else {
            return (nil, nil, true, "EINVAL: parent offset out of range")
        }
        return (col, row, true, nil)
    }

    private func nextKittyPlacementId() -> UInt32 {
        var id = kittyGraphicsState.nextPlacementId
        kittyGraphicsState.nextPlacementId &+= 1
        if id == 0 {
            id = kittyGraphicsState.nextPlacementId
            kittyGraphicsState.nextPlacementId &+= 1
        }
        return id == 0 ? 1 : id
    }

    private func collectKittyPlacementPositions(in buffer: Buffer) -> [KittyPlacementKey: (row: Int, col: Int)] {
        var positions: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        for rowIndex in 0..<buffer.lines.count {
            let line = buffer.lines[rowIndex]
            guard let images = line.images else {
                continue
            }
            for image in images {
                guard let kitty = image as? KittyPlacementImage,
                      kitty.kittyIsKitty,
                      let imageId = kitty.kittyImageId,
                      let placementId = kitty.kittyPlacementId else {
                    continue
                }
                let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
                if let existing = positions[key] {
                    if rowIndex < existing.row {
                        positions[key] = (row: rowIndex, col: existing.col)
                    }
                } else {
                    positions[key] = (row: rowIndex, col: image.col)
                }
            }
        }
        return positions
    }

    private func resolveKittyPlacementPosition(for key: KittyPlacementKey,
                                               positions: [KittyPlacementKey: (row: Int, col: Int)],
                                               resolved: inout [KittyPlacementKey: (row: Int, col: Int)],
                                               visiting: inout Set<KittyPlacementKey>) -> (row: Int, col: Int)? {
        if let cached = resolved[key] {
            return cached
        }
        guard let record = kittyGraphicsState.placementsByKey[key],
              record.isAlternateBuffer == isCurrentBufferAlternate else {
            return nil
        }
        if visiting.contains(key) {
            return nil
        }
        visiting.insert(key)

        var base: (row: Int, col: Int)?
        if record.isVirtual {
            base = (row: record.row, col: record.col)
        } else if let pos = positions[key] {
            base = pos
        } else {
            base = (row: record.row, col: record.col)
        }

        if let parentImageId = record.parentImageId,
           let parentPlacementId = record.parentPlacementId {
            let parentKey = KittyPlacementKey(imageId: parentImageId, placementId: parentPlacementId)
            if let parentPos = resolveKittyPlacementPosition(for: parentKey,
                                                             positions: positions,
                                                             resolved: &resolved,
                                                             visiting: &visiting) {
                // Checked recursive accumulation: a stored absurd offset
                // unresolves the placement instead of trapping.
                let (row, rowOverflow) = parentPos.row.addingReportingOverflow(record.parentOffsetV)
                let (col, colOverflow) = parentPos.col.addingReportingOverflow(record.parentOffsetH)
                if rowOverflow || colOverflow {
                    base = nil
                } else {
                    base = (row: row, col: col)
                }
            } else {
                base = nil
            }
        }

        visiting.remove(key)
        if let base {
            resolved[key] = base
        }
        return base
    }

    private func moveKittyPlacementImages(in buffer: Buffer,
                                          key: KittyPlacementKey,
                                          deltaRow: Int,
                                          newTopRow: Int,
                                          newLeftCol: Int) {
        var moves: [(image: KittyPlacementImage, targetRow: Int)] = []

        for rowIndex in 0..<buffer.lines.count {
            let line = buffer.lines[rowIndex]
            guard let images = line.images else {
                continue
            }
            var kept: [TerminalImage] = []
            var moved: [KittyPlacementImage] = []
            for image in images {
                if let kitty = image as? KittyPlacementImage,
                   kitty.kittyIsKitty,
                   kitty.kittyImageId == key.imageId,
                   kitty.kittyPlacementId == key.placementId {
                    moved.append(kitty)
                } else {
                    kept.append(image)
                }
            }
            if !moved.isEmpty {
                line.images = kept.isEmpty ? nil : kept
                let targetRow = rowIndex + deltaRow
                for image in moved {
                    moves.append((image: image, targetRow: targetRow))
                }
            }
        }

        for move in moves {
            guard move.targetRow >= 0 && move.targetRow < buffer.lines.count else {
                continue
            }
            var image = move.image
            image.col = newLeftCol
            image.kittyCol = newLeftCol
            image.kittyRow = newTopRow
            buffer.attachImage(image, toLineAt: move.targetRow)
        }
    }

    func updateKittyRelativePlacementsForCurrentBuffer() {
        let isAlt = isCurrentBufferAlternate
        let positions = collectKittyPlacementPositions(in: buffer)

        for (key, record) in kittyGraphicsState.placementsByKey where record.isAlternateBuffer == isAlt {
            if record.isVirtual {
                continue
            }
            guard let pos = positions[key] else {
                continue
            }
            if record.row != pos.row || record.col != pos.col {
                var updated = record
                updated.row = pos.row
                updated.col = pos.col
                kittyGraphicsState.placementsByKey[key] = updated
            }
        }

        var resolved: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var visiting: Set<KittyPlacementKey> = []

        for (key, record) in kittyGraphicsState.placementsByKey where record.isAlternateBuffer == isAlt {
            guard record.parentImageId != nil, record.parentPlacementId != nil else {
                continue
            }
            guard let desired = resolveKittyPlacementPosition(for: key,
                                                              positions: positions,
                                                              resolved: &resolved,
                                                              visiting: &visiting) else {
                continue
            }
            var updated = record
            if record.isVirtual {
                updated.row = desired.row
                updated.col = desired.col
                kittyGraphicsState.placementsByKey[key] = updated
                continue
            }
            let current = positions[key] ?? (row: record.row, col: record.col)
            let deltaRow = desired.row - current.row
            if deltaRow != 0 || desired.col != current.col {
                moveKittyPlacementImages(in: buffer,
                                         key: key,
                                         deltaRow: deltaRow,
                                         newTopRow: desired.row,
                                         newLeftCol: desired.col)
            }
            updated.row = desired.row
            updated.col = desired.col
            kittyGraphicsState.placementsByKey[key] = updated
        }
    }

    func registerKittyPlacement(imageId: UInt32,
                                placementId: UInt32,
                                parentImageId: UInt32?,
                                parentPlacementId: UInt32?,
                                parentOffsetH: Int,
                                parentOffsetV: Int,
                                pixelOffsetX: Int,
                                pixelOffsetY: Int,
                                col: Int,
                                row: Int,
                                cols: Int,
                                rows: Int,
                                zIndex: Int,
                                isVirtual: Bool) {
        let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
        // Re-registration replaces any retained stripes recorded by a prior
        // install; the install re-notes the new cost on success.
        releaseRenderedStripeCost(keys: [key])
        let record = KittyPlacementRecord(imageId: imageId,
                                          placementId: placementId,
                                          parentImageId: parentImageId,
                                          parentPlacementId: parentPlacementId,
                                          parentOffsetH: parentOffsetH,
                                          parentOffsetV: parentOffsetV,
                                          pixelOffsetX: pixelOffsetX,
                                          pixelOffsetY: pixelOffsetY,
                                          col: col,
                                          row: row,
                                          cols: cols,
                                          rows: rows,
                                          zIndex: zIndex,
                                          isVirtual: isVirtual,
                                          isAlternateBuffer: isCurrentBufferAlternate)
        kittyGraphicsState.placementsByKey[key] = record
    }

    private func removeKittyPlacement(imageId: UInt32, placementId: UInt32) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            image.kittyImageId == imageId && image.kittyPlacementId == placementId
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        var combined = removedKeys.union(altRemoved)
        combined.insert(KittyPlacementKey(imageId: imageId, placementId: placementId))
        for key in combined {
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
        }
        releaseRenderedStripeCost(keys: combined)
    }

    private func sendKittyOk(control: KittyGraphicsControl, imageId: UInt32?, imageNumber: UInt32?, placementId: UInt32?) {
        if control.suppressResponses != 0 {
            return
        }
        var parts: [String] = []
        if let id = imageId {
            parts.append("i=\(id)")
        }
        if let number = imageNumber {
            parts.append("I=\(number)")
        }
        if let placement = placementId {
            parts.append("p=\(placement)")
        }
        var controlData = "G"
        if !parts.isEmpty {
            controlData += parts.joined(separator: ",")
        }
        sendResponse(cc.APC, "\(controlData);OK", cc.ST)
    }

    private func sendKittyError(control: KittyGraphicsControl, message: String) {
        if control.suppressResponses != 0 {
            return
        }
        var controlData = "G"
        if let id = control.imageId {
            controlData += "i=\(id)"
        } else if let number = control.imageNumber {
            controlData += "I=\(number)"
        }
        sendResponse(cc.APC, "\(controlData);\(message)", cc.ST)
    }

    /// Terminal for a parser-level hosted overflow: the Kitty APC exceeded
    /// the configured encoded cap while accumulating, so its tail was
    /// dropped pre-parse and nothing was dispatched. Emits one typed
    /// EOVERFLOW honoring the retained control prefix (suppression plus
    /// image ids for correlation), clears any open partial transfer from
    /// earlier chunks, and retains zero payload or placement state.
    /// Flag-off terminals never reach here (the parser does not cap).
    func rejectHostedApcOverflow(contentPrefix: ArraySlice<UInt8>) {
        let limits = hostedKittyLimits()
        kittyGraphicsState.pending = nil
        let message = "EOVERFLOW: hosted transfer too large (\(limits.maxPartialEncodedBytes) byte cap)"
        guard !contentPrefix.isEmpty, let (control, _) = parseKittyGraphicsControl(contentPrefix) else {
            sendResponse(cc.APC, "G;\(message)", cc.ST)
            return
        }
        sendKittyError(control: control, message: message)
    }

    /// Exports exact Kitty payloads and placements wholly contained in the
    /// retained text-snapshot line range. A nil result means the caller must
    /// use its canonical fallback rather than paint an incomplete image state.
    public func makeKittyGraphicsSnapshot(
        firstInvariantRow: Int,
        retainedLineCount: Int,
        maximumPayloadBytes: Int
    ) -> TerminalKittyGraphicsSnapshot? {
        guard kittyGraphicsState.pending == nil,
              retainedLineCount > 0,
              maximumPayloadBytes >= 0 else { return nil }
        updateKittyRelativePlacementsForCurrentBuffer()
        let firstRow = firstInvariantRow - buffer.linesTop
        let endRow = firstRow + retainedLineCount
        guard firstRow >= 0, endRow <= buffer.lines.count else { return nil }

        var keys = Set<KittyPlacementKey>()
        for row in firstRow..<endRow {
            guard let images = buffer.lines[row].images else { continue }
            for image in images {
                guard let kitty = image as? KittyPlacementImage,
                      kitty.kittyIsKitty,
                      let imageID = kitty.kittyImageId,
                      let placementID = kitty.kittyPlacementId else { continue }
                keys.insert(KittyPlacementKey(imageId: imageID, placementId: placementID))
            }
        }
        if keys.isEmpty {
            return TerminalKittyGraphicsSnapshot(retainedLineCount: retainedLineCount, images: [], placements: [])
        }

        var placements: [TerminalKittyGraphicsSnapshot.Placement] = []
        var imageIDs = Set<UInt32>()
        let numberByImageID = Dictionary(uniqueKeysWithValues: kittyGraphicsState.imageNumbers.map { ($0.value, $0.key) })
        for key in keys.sorted(by: { ($0.imageId, $0.placementId) < ($1.imageId, $1.placementId) }) {
            guard let record = kittyGraphicsState.placementsByKey[key],
                  record.isAlternateBuffer == isCurrentBufferAlternate,
                  !record.isVirtual,
                  record.cols > 0,
                  record.rows > 0,
                  record.row >= firstRow,
                  record.row + record.rows <= endRow else { return nil }
            imageIDs.insert(record.imageId)
            placements.append(.init(
                imageID: record.imageId,
                imageNumber: numberByImageID[record.imageId],
                placementID: record.placementId,
                column: record.col,
                relativeRow: record.row - firstRow,
                columns: record.cols,
                rows: record.rows,
                zIndex: record.zIndex,
                pixelOffsetX: record.pixelOffsetX,
                pixelOffsetY: record.pixelOffsetY
            ))
        }

        var totalBytes = 0
        var images: [TerminalKittyGraphicsSnapshot.Image] = []
        for imageID in imageIDs.sorted() {
            guard let image = kittyGraphicsState.imagesById[imageID] else { return nil }
            let payload: TerminalKittyGraphicsSnapshot.Image.Payload
            switch image.payload {
            case .png(let data):
                totalBytes += data.count
                payload = .png(data)
            case .rgba(let bytes, let width, let height):
                totalBytes += bytes.count
                payload = .rgba(Data(bytes), width: width, height: height)
            }
            guard totalBytes <= maximumPayloadBytes else { return nil }
            images.append(.init(id: imageID, number: numberByImageID[imageID], payload: payload))
        }
        return TerminalKittyGraphicsSnapshot(
            retainedLineCount: retainedLineCount,
            images: images,
            placements: placements
        )
    }

    /// Installs only placement metadata. Placeholder stripes then follow the
    /// same buffer mutations as ordinary images while payload bytes remain
    /// deferred and cannot delay first paint or input.
    public func prepareKittyGraphicsManifest(_ manifest: TerminalKittyGraphicsManifest) -> Bool {
        guard manifest.version == 1,
              manifest.retainedLineCount > 0,
              manifest.retainedLineCount <= buffer.lines.count else { return false }
        clearAllKittyImages()
        for placement in manifest.placements {
            guard placement.columns > 0,
                  placement.rows > 0,
                  placement.relativeRow >= 0,
                  placement.relativeRow + placement.rows <= manifest.retainedLineCount else { return false }
            registerKittyPlacement(
                imageId: placement.imageID,
                placementId: placement.placementID,
                parentImageId: nil,
                parentPlacementId: nil,
                parentOffsetH: 0,
                parentOffsetV: 0,
                pixelOffsetX: placement.pixelOffsetX,
                pixelOffsetY: placement.pixelOffsetY,
                col: placement.column,
                row: placement.relativeRow,
                cols: placement.columns,
                rows: placement.rows,
                zIndex: placement.zIndex,
                isVirtual: false
            )
            for rowOffset in 0..<placement.rows {
                let placeholder = KittyHeadlessPlacementImage()
                placeholder.kittyImageId = placement.imageID
                placeholder.kittyImageNumber = placement.imageNumber
                placeholder.kittyPlacementId = placement.placementID
                placeholder.kittyZIndex = placement.zIndex
                placeholder.kittyCol = placement.column
                placeholder.kittyRow = placement.relativeRow
                placeholder.kittyCols = placement.columns
                placeholder.kittyRows = placement.rows
                placeholder.kittyPixelOffsetX = placement.pixelOffsetX
                placeholder.kittyPixelOffsetY = placement.pixelOffsetY
                placeholder.col = placement.column
                buffer.attachImage(placeholder, toLineAt: placement.relativeRow + rowOffset)
            }
        }
        return true
    }

    /// Resolves the manifest against the post-suffix buffer. Only placeholders
    /// that survived ordinary terminal mutations receive their old payload;
    /// deleted or ID-replaced placements can never be resurrected.
    func consumeKittyGraphicsPayloads(
        _ payloads: TerminalKittyGraphicsPayloadSnapshot
    ) -> TerminalKittyGraphicsSnapshot? {
        guard payloads.version == 1 else { return nil }
        updateKittyRelativePlacementsForCurrentBuffer()
        let payloadByID = Dictionary(uniqueKeysWithValues: payloads.images.map { ($0.id, $0) })
        let positions = collectKittyPlacementPositions(in: buffer)
        var survivingKeys = Set<KittyPlacementKey>()
        for row in 0..<buffer.lines.count {
            guard let images = buffer.lines[row].images else { continue }
            for image in images {
                guard image is KittyHeadlessPlacementImage,
                      let kitty = image as? KittyPlacementImage,
                      let imageID = kitty.kittyImageId,
                      let placementID = kitty.kittyPlacementId else { continue }
                survivingKeys.insert(KittyPlacementKey(imageId: imageID, placementId: placementID))
            }
        }

        var placements: [TerminalKittyGraphicsSnapshot.Placement] = []
        var neededImageIDs = Set<UInt32>()
        for key in survivingKeys.sorted(by: { ($0.imageId, $0.placementId) < ($1.imageId, $1.placementId) }) {
            guard kittyGraphicsState.imagesById[key.imageId] == nil,
                  payloadByID[key.imageId] != nil,
                  let record = kittyGraphicsState.placementsByKey[key],
                  let position = positions[key] else { continue }
            neededImageIDs.insert(key.imageId)
            placements.append(.init(
                imageID: key.imageId,
                imageNumber: payloadByID[key.imageId]?.number,
                placementID: key.placementId,
                column: position.col,
                relativeRow: position.row,
                columns: record.cols,
                rows: record.rows,
                zIndex: record.zIndex,
                pixelOffsetX: record.pixelOffsetX,
                pixelOffsetY: record.pixelOffsetY
            ))
        }

        for row in 0..<buffer.lines.count {
            guard let images = buffer.lines[row].images else { continue }
            let kept = images.filter { !($0 is KittyHeadlessPlacementImage) }
            guard kept.count != images.count else { continue }
            buffer.clearImagesFromLine(at: row)
            for image in kept { buffer.attachImage(image, toLineAt: row) }
        }

        let neededImages = payloads.images.filter { neededImageIDs.contains($0.id) }
        var totalBytes = 0
        for image in neededImages {
            let payload: KittyGraphicsPayload
            let byteSize: Int
            switch image.payload {
            case .png(let data):
                payload = .png(data)
                byteSize = data.count
            case .rgba(let data, let width, let height):
                guard width > 0, height > 0, data.count == width * height * 4 else { return nil }
                payload = .rgba(bytes: Array(data), width: width, height: height)
                byteSize = data.count
            }
            totalBytes += byteSize
            guard kittyGraphicsState.totalImageBytes + totalBytes <= clampedKittyImageCacheLimitBytes() else { return nil }
            kittyGraphicsState.imagesById[image.id] = KittyGraphicsImage(
                payload: payload,
                byteSize: byteSize,
                lastAccessTick: nextKittyImageAccessTick()
            )
            if let number = image.number { kittyGraphicsState.imageNumbers[number] = image.id }
        }
        kittyGraphicsState.totalImageBytes += totalBytes
        return TerminalKittyGraphicsSnapshot(
            retainedLineCount: buffer.lines.count,
            images: neededImages,
            placements: placements
        )
    }

    /// Two-phase hosted handler for transmit-and-display with a direct
    /// payload. Always consumes the sequence when two-phase rendering is
    /// enabled: eligible transmissions record cursor-anchored placement,
    /// attach headless placeholder rows, advance the cursor exactly like the
    /// inline path, and enqueue an immutable decode ticket carrying every
    /// geometry preparation needs. Ineligible transmissions get a typed
    /// in-order rejection. Nothing here decodes image bytes, scales, or
    /// creates stripes, and nothing falls through to the legacy synchronous
    /// inline decoder.
    ///
    /// Must run on the feeding thread: it shares parser, cursor, and buffer
    /// state with every other feed operation. Admission passes before image-id
    /// assignment, placement registration, placeholder creation, and enqueue,
    /// so a rejected sequence mutates nothing.
    private func handleHostedKittyTransmitDirect(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        assert(recordHostedFeedingThread())
        let limits = hostedKittyLimits()
        func reject(_ message: String) {
            sendKittyError(control: control, message: message)
        }
        guard control.format == 100 || control.format == 24 || control.format == 32 else {
            reject("EINVAL: unsupported format")
            return
        }
        guard control.compression == nil || control.compression == "z" else {
            reject("EINVAL: unsupported compression")
            return
        }
        let isVirtual = control.unicodePlaceholder == 1
        if isVirtual, control.parentImageId != nil || control.parentPlacementId != nil {
            reject("EINVAL: virtual placement cannot refer to parent")
            return
        }
        // Queue admission before any mutation: hosts rely on exact
        // pending-job/byte accounting for their watermarks.
        switch admitHostedRenderRequest(encodedBytes: base64Payload.count) {
        case .admitted:
            break
        case .rejected(let reason):
            switch reason {
            case .partialTransferTooLarge(let bytes, let limit),
                    .payloadTooLarge(let bytes, let limit):
                reject("EOVERFLOW: hosted payload too large (\(bytes) > \(limit))")
            case .pendingQueueFull(let jobs, let limit):
                reject("EBUSY: hosted queue full (\(jobs) >= \(limit))")
            case .pendingQueueBytesFull(let bytes, let limit):
                reject("EBUSY: hosted queue bytes full (\(bytes) > \(limit))")
            }
            return
        }
        // Parent origin resolves against live records exactly like the inline
        // path; errors precede all mutation.
        let origin = resolveKittyPlacementOrigin(control: control)
        if let errorMessage = origin.errorMessage {
            reject(errorMessage)
            return
        }
        // Placement-metadata bounds after all pure validation, before any
        // mutation: reaps scrollback-dead records and evicts unanchored
        // virtual/store-only records past the count cap.
        guard enforceHostedPlacementBounds() else {
            reject("EBUSY: hosted placements full")
            return
        }
        let cellSize = tdel?.cellSizeInPixels(source: self)
        // Requested pixel offsets are untrusted: clamp into a sane range up
        // front so grid math can never trap near Int.max. A later view-size
        // clamp still applies for view-backed terminals.
        let reqOffsetX = min(max(0, control.pixelOffsetX), limits.maxImageDimension)
        let reqOffsetY = min(max(0, control.pixelOffsetY), limits.maxImageDimension)
        // Placement grid without decoding: explicit cells apply directly;
        // auto dimensions derive from raw `s=`/`v=` or, for PNG, from a
        // bounded header-only sniff (no raster decode). A nil grid means a
        // headless auto-size display, which the inline path renders as a
        // store-only no-op: the ticket still carries the payload for storage.
        let grid: (cols: Int, rows: Int)?
        if isVirtual {
            grid = nil
        } else if control.columns > 0, control.rows > 0 {
            grid = (control.columns, control.rows)
        } else if control.format == 100 {
            // Compressed auto-size PNG cannot be gridded without inflating
            // on the feeding thread, so it gets an explicit ENOTSUP (never
            // a misleading EINVAL from a failed sniff of zlib bytes).
            if control.compression != nil && (control.columns == 0 || control.rows == 0) {
                reject("ENOTSUP: compressed auto-size PNG requires explicit c=/r= in hosted mode")
                return
            }
            if cellSize == nil {
                grid = nil
            } else if let sniffed = hostedSniffPNGDimensions(base64Payload: base64Payload) {
                grid = hostedPlacementGrid(imageWidth: sniffed.width, imageHeight: sniffed.height,
                                            columns: control.columns, rows: control.rows,
                                            cellSize: cellSize,
                                            pixelOffsetX: reqOffsetX,
                                            pixelOffsetY: reqOffsetY)
                if grid == nil {
                    reject("EINVAL: bad dimensions")
                    return
                }
            } else {
                reject("EINVAL: bad payload")
                return
            }
        } else {
            guard HostedKittyImageDecoder.validateDimensions(width: control.width, height: control.height, maxDimension: limits.maxImageDimension) else {
                reject("EINVAL: bad dimensions")
                return
            }
            grid = hostedPlacementGrid(imageWidth: control.width, imageHeight: control.height,
                                        columns: control.columns, rows: control.rows,
                                        cellSize: cellSize,
                                        pixelOffsetX: reqOffsetX,
                                        pixelOffsetY: reqOffsetY)
            if grid == nil, cellSize != nil {
                reject("EINVAL: bad dimensions")
                return
            }
        }
        let cols = grid?.cols ?? 0
        let rows = grid?.rows ?? 0
        if let grid {
            // Checked area product: control ints are untrusted and must
            // never trap near Int.max.
            let (cells, cellsOverflow) = grid.cols.multipliedReportingOverflow(by: grid.rows)
            guard grid.cols <= limits.maxImageDimension,
                  grid.rows <= limits.maxImageDimension,
                  !cellsOverflow, cells <= limits.maxPlacementCells else {
                reject("EOVERFLOW: placement too large")
                return
            }
        }
        // Image identity: explicit `i=`/`I=` mirror the inline resolver;
        // anonymous display takes an ephemeral internal id (stored nowhere,
        // replied nowhere), matching inline transient semantics.
        let imageId: UInt32
        let imageNumber: UInt32?
        let shouldReply: Bool
        let isAnonymous: Bool
        if let id = control.imageId {
            imageId = id
            imageNumber = nil
            shouldReply = control.suppressResponses == 0
            isAnonymous = false
        } else if control.imageNumber != nil {
            let resolved = resolveKittyImageId(control: control)
            guard let id = resolved.imageId else {
                reject("EINVAL: bad payload")
                return
            }
            imageId = id
            imageNumber = resolved.imageNumber
            shouldReply = resolved.shouldReply
            isAnonymous = false
        } else {
            imageId = kittyGraphicsState.nextImageId
            kittyGraphicsState.nextImageId &+= 1
            imageNumber = nil
            shouldReply = false
            isAnonymous = true
        }
        let placementId = control.placementId ?? nextKittyPlacementId()
        var pixelOffsetX = reqOffsetX
        var pixelOffsetY = reqOffsetY
        if (pixelOffsetX != 0 || pixelOffsetY != 0),
           let cellSize {
            pixelOffsetX = min(pixelOffsetX, max(0, cellSize.width - 1))
            pixelOffsetY = min(pixelOffsetY, max(0, cellSize.height - 1))
        }

        let savedX = buffer.x
        let savedY = buffer.y
        // Mirror the inline path: absolute placements position the cursor at
        // the origin first; relative (parent-anchored) placements keep it.
        if let col = origin.col, let row = origin.row {
            let targetRow = row - buffer.yBase
            if targetRow >= 0 && targetRow < buffer.lines.count {
                buffer.y = targetRow
                buffer.x = max(0, min(col, cols - 1))
            } else {
                reject("EINVAL: placement out of range")
                return
            }
        }
        let placementCol = buffer.x
        let placementRow = buffer.y + buffer.yBase
        // Pairs with placementRow: together they form the stable absolute
        // coordinate used to anchor deferred stripes after scroll/trim.
        let originLinesTop = buffer.linesTop
        if isAnonymous {
            evictExcessAnonymousPlacements()
        }
        removeKittyPlacement(imageId: imageId, placementId: placementId)
        registerKittyPlacement(imageId: imageId,
                               placementId: placementId,
                               parentImageId: control.parentImageId,
                               parentPlacementId: control.parentPlacementId,
                               parentOffsetH: control.offsetH,
                               parentOffsetV: control.offsetV,
                               pixelOffsetX: pixelOffsetX,
                               pixelOffsetY: pixelOffsetY,
                               col: placementCol,
                               row: placementRow,
                               cols: cols,
                               rows: rows,
                               zIndex: control.zIndex,
                               isVirtual: isVirtual)
        if isAnonymous {
            kittyGraphicsState.anonymousPlacementKeys.append(KittyPlacementKey(imageId: imageId, placementId: placementId))
        }
        if !isVirtual {
            var didScroll = false
            for _ in 0..<rows {
                let placeholder = KittyHeadlessPlacementImage()
                placeholder.kittyImageId = imageId
                placeholder.kittyImageNumber = imageNumber
                placeholder.kittyPlacementId = placementId
                placeholder.kittyZIndex = control.zIndex
                placeholder.kittyCol = placementCol
                placeholder.kittyRow = placementRow
                placeholder.kittyCols = cols
                placeholder.kittyRows = rows
                placeholder.kittyPixelOffsetX = pixelOffsetX
                placeholder.kittyPixelOffsetY = pixelOffsetY
                placeholder.col = placementCol
                buffer.attachImage(placeholder, toLineAt: buffer.y + buffer.yBase)
                updateRange(buffer.y)
                let rowX = buffer.x
                let previousYBase = buffer.yBase
                let previousLinesTop = buffer.linesTop
                cmdLineFeed()
                if buffer.yBase != previousYBase || buffer.linesTop != previousLinesTop {
                    didScroll = true
                }
                buffer.x = rowX
            }
            if didScroll {
                updateFullScreen()
            }
            // Inline cursor semantics exactly: relative placements and
            // cursorPolicy 1 preserve position, otherwise INDEX-scroll when
            // headless (no cell size) or direct-set when view-backed.
            if origin.isRelative || control.cursorPolicy == 1 {
                buffer.x = savedX
                buffer.y = savedY
            } else if let grid {
                let moveCols = max(1, grid.cols)
                let moveRows = max(1, grid.rows)
                let useIndex = cellSize == nil
                applyKittyCursorMovement(startCol: placementCol,
                                         startRow: placementRow,
                                         cols: moveCols,
                                         rows: moveRows,
                                         useIndex: useIndex)
            }
        }
        pendingHostedKittyRenders.append(HostedKittyRenderRequest(epoch: hostedGraphicsEpoch,
                                                                  originLinesTop: originLinesTop,
                                                                  imageId: imageId,
                                                                  imageNumber: imageNumber,
                                                                  placementId: placementId,
                                                                  columns: cols,
                                                                  rows: rows,
                                                                  zIndex: control.zIndex,
                                                                  pixelOffsetX: pixelOffsetX,
                                                                  pixelOffsetY: pixelOffsetY,
                                                                  format: control.format,
                                                                  rawWidth: control.width,
                                                                  rawHeight: control.height,
                                                                  compression: control.compression,
                                                                  base64Payload: base64Payload,
                                                                  isAlternateBuffer: isCurrentBufferAlternate,
                                                                  cellWidthPx: cellSize?.width,
                                                                  cellHeightPx: cellSize?.height,
                                                                  anchorCol: placementCol,
                                                                  anchorRow: placementRow,
                                                                  isVirtual: isVirtual,
                                                                  isAnonymous: isAnonymous,
                                                                  cropX: control.cropX,
                                                                  cropY: control.cropY,
                                                                  cropWidth: control.cropWidth,
                                                                  cropHeight: control.cropHeight,
                                                                  parentImageId: control.parentImageId,
                                                                  parentPlacementId: control.parentPlacementId,
                                                                  parentOffsetH: control.offsetH,
                                                                  parentOffsetV: control.offsetV))
        // Matches the inline reply: the requested placement id (which may be
        // absent), never the auto-assigned one.
        if shouldReply {
            sendKittyOk(control: control, imageId: isAnonymous ? nil : imageId, imageNumber: imageNumber, placementId: control.placementId)
        }
    }

    /// Placement grid math mirroring `kittyPlacementGridSize` for explicit
    /// and auto (aspect-preserving) size requests, without touching payloads.
    /// Percent requests cannot arise from the parser and return nil. All
    /// arithmetic runs in the Double domain with exact `Int` conversion, so
    /// untrusted control ints can never trap near `Int.max`; absurd results
    /// simply miss and the caller rejects them.
    private func hostedPlacementGrid(imageWidth: Int, imageHeight: Int,
                                     columns: Int, rows: Int,
                                     cellSize: (width: Int, height: Int)?,
                                     pixelOffsetX: Int, pixelOffsetY: Int) -> (cols: Int, rows: Int)? {
        if columns > 0, rows > 0 {
            return (max(1, columns), max(1, rows))
        }
        guard imageWidth > 0, imageHeight > 0,
              let cellSize, cellSize.width > 0, cellSize.height > 0,
              pixelOffsetX >= 0, pixelOffsetY >= 0 else {
            return nil
        }
        let preserveAspectRatio = columns == 0 || rows == 0
        let aspect = Double(imageWidth) / Double(imageHeight)
        var widthPx: Double
        var heightPx: Double
        if columns > 0 {
            widthPx = Double(columns) * Double(cellSize.width)
        } else {
            widthPx = Double(imageWidth)
        }
        if rows > 0 {
            heightPx = Double(rows) * Double(cellSize.height)
        } else {
            heightPx = Double(imageHeight)
        }
        if preserveAspectRatio {
            if columns == 0, rows > 0 {
                widthPx = heightPx * aspect
            } else if rows == 0, columns > 0 {
                heightPx = widthPx / aspect
            }
        }
        guard widthPx.isFinite, heightPx.isFinite else { return nil }
        guard let cols = Int(exactly: ceil((widthPx + Double(pixelOffsetX)) / Double(cellSize.width))),
              let rowsOut = Int(exactly: ceil((heightPx + Double(pixelOffsetY)) / Double(cellSize.height))),
              cols > 0, rowsOut > 0 else {
            return nil
        }
        return (cols, rowsOut)
    }

    /// Evicts the oldest anonymous placements past the configured bound.
    /// Runs after admission and before registration, so an admitted display
    /// always fits while total anonymous state stays bounded. Stale keys
    /// (explicit deletes, resets) are pruned first.
    private func evictExcessAnonymousPlacements() {
        let cap = max(1, hostedKittyLimits().maxAnonymousPlacements)
        kittyGraphicsState.anonymousPlacementKeys.removeAll { kittyGraphicsState.placementsByKey[$0] == nil }
        while kittyGraphicsState.anonymousPlacementKeys.count >= cap {
            let oldest = kittyGraphicsState.anonymousPlacementKeys.removeFirst()
            removeKittyPlacement(imageId: oldest.imageId, placementId: oldest.placementId)
        }
    }

    /// Bounded PNG dimension prefix for auto-sized deferred displays. Decodes
    /// only enough base64 to cover the 8-byte signature plus the IHDR length,
    /// type, and dimensions (24 bytes from at most 64 base64 chars): no full
    /// payload decode and no ImageIO on the feeding thread. Full header and
    /// raster validation stays in off-main preparation, which rejects
    /// anything this prefix misreads.
    func hostedSniffPNGDimensions(base64Payload: [UInt8]) -> (width: Int, height: Int)? {
        // 24 decoded bytes need 32 base64 chars without whitespace; allow a
        // wider window so wrapped payloads still parse.
        guard base64Payload.count >= 32 else { return nil }
        guard let decoded = Data(base64Encoded: Data(base64Payload.prefix(64)), options: .ignoreUnknownCharacters),
              decoded.count >= 24 else {
            return nil
        }
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard Array(decoded.prefix(8)) == pngSignature else { return nil }
        // IHDR chunk length must be 13 and chunk type "IHDR".
        let chunkLength = (UInt32(decoded[8]) << 24) | (UInt32(decoded[9]) << 16) |
            (UInt32(decoded[10]) << 8) | UInt32(decoded[11])
        guard chunkLength == 13,
              decoded[12] == 73, decoded[13] == 72, decoded[14] == 68, decoded[15] == 82 else {
            return nil
        }
        let width = (UInt32(decoded[16]) << 24) | (UInt32(decoded[17]) << 16) |
            (UInt32(decoded[18]) << 8) | UInt32(decoded[19])
        let height = (UInt32(decoded[20]) << 24) | (UInt32(decoded[21]) << 16) |
            (UInt32(decoded[22]) << 8) | UInt32(decoded[23])
        // Exact conversion: absurd dimensions miss instead of trapping, and
        // the grid caps reject them downstream.
        guard width > 0, height > 0,
              let w = Int(exactly: width), let h = Int(exactly: height) else {
            return nil
        }
        return (w, h)
    }

    func clearAllKittyImages() {
        // Retire every outstanding two-phase ticket: placements recorded by
        // the deferred parser no longer exist after a mass clear.
        hostedGraphicsEpoch &+= 1
        pendingHostedKittyRenders.removeAll()
        kittyGraphicsState.renderedStripeBytesByKey.removeAll()
        kittyGraphicsState.totalRenderedStripeBytes = 0
        kittyGraphicsState.anonymousPlacementKeys.removeAll()
        for idx in 0..<buffer.lines.count {
            buffer.clearImagesFromLine(at: idx)
        }
        for idx in 0..<altBuffer.lines.count {
            altBuffer.clearImagesFromLine(at: idx)
        }
        kittyGraphicsState.imagesById.removeAll()
        kittyGraphicsState.imageNumbers.removeAll()
        kittyGraphicsState.placementsByKey.removeAll()
        kittyGraphicsState.totalImageBytes = 0
        kittyGraphicsState.nextImageAccessTick = 1
        updateRange(startLine: buffer.scrollTop, endLine: buffer.scrollBottom)
    }

    func clearKittyImages(in buffer: Buffer, isAlternateBuffer: Bool) {
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count) { _ in true }
        let recordKeys = removePlacementRecords { record in
            record.isAlternateBuffer == isAlternateBuffer
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
        cleanupUnusedKittyImages()
    }

    private func deletePlacementsVisibleOnScreen() {
        let start = buffer.yBase
        let end = min(buffer.yBase + rows, buffer.lines.count)
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: start..<end) { _ in true }
        let recordKeys = removePlacementRecords { record in
            recordIntersectsScreen(record)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsByImageId(imageId: UInt32, placementId: UInt32?) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard image.kittyImageId == imageId else { return false }
            if let placementId = placementId {
                return image.kittyPlacementId == placementId
            }
            return true
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let allRemoved = removedKeys.union(altRemoved)
        let recordKeys = removePlacementRecords { record in
            guard record.imageId == imageId else { return false }
            if let placementId = placementId {
                return record.placementId == placementId
            }
            return true
        }
        let extraKeys = recordKeys.subtracting(allRemoved)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsByImageNumber(imageNumber: UInt32, placementId: UInt32?) {
        guard let imageId = kittyGraphicsState.imageNumbers[imageNumber] else {
            return
        }
        deletePlacementsByImageId(imageId: imageId, placementId: placementId)
    }

    private func deletePlacementsByImageIdRange(minId: UInt32, maxId: UInt32) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard let imageId = image.kittyImageId else { return false }
            return imageId >= minId && imageId <= maxId
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let allRemoved = removedKeys.union(altRemoved)
        let recordKeys = removePlacementRecords { record in
            record.imageId >= minId && record.imageId <= maxId
        }
        let extraKeys = recordKeys.subtracting(allRemoved)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsAtCell(col: Int, row: Int, zIndex: Int?) {
        // Checked indices: untrusted 1-based positions must never trap.
        // An overflowing row matches nothing (fail-closed).
        guard col >= 1, row >= 1 else { return }
        let colIndex = col - 1
        let (base, overflow) = (row - 1).addingReportingOverflow(buffer.yBase)
        let rowIndex = overflow ? Int.max : base
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard image.kittyIsKitty else { return false }
            if let zIndex = zIndex, image.kittyZIndex != zIndex {
                return false
            }
            return self.kittyPlacementIntersectsCell(image, col: colIndex, row: rowIndex)
        }
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count, predicate: predicate)
        let recordKeys = removePlacementRecords { record in
            if let zIndex = zIndex, record.zIndex != zIndex {
                return false
            }
            return recordIntersectsCell(record, col: colIndex, row: rowIndex)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsInColumn(_ col: Int) {
        guard col >= 1 else { return }
        let colIndex = col - 1
        let predicate: (KittyPlacementImage) -> Bool = { image in
            self.kittyPlacementIntersectsColumn(image, col: colIndex)
        }
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count, predicate: predicate)
        let recordKeys = removePlacementRecords { record in
            recordIntersectsColumn(record, col: colIndex)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsInRow(_ row: Int) {
        guard row >= 1 else { return }
        let (base, overflow) = (row - 1).addingReportingOverflow(buffer.yBase)
        let rowIndex = overflow ? Int.max : base
        let predicate: (KittyPlacementImage) -> Bool = { image in
            self.kittyPlacementIntersectsRow(image, row: rowIndex)
        }
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count, predicate: predicate)
        let recordKeys = removePlacementRecords { record in
            recordIntersectsRow(record, row: rowIndex)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsWithZIndex(_ zIndex: Int) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            image.kittyZIndex == zIndex
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let allRemoved = removedKeys.union(altRemoved)
        let recordKeys = removePlacementRecords { record in
            record.zIndex == zIndex
        }
        let extraKeys = recordKeys.subtracting(allRemoved)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func removeKittyPlacements(in buffer: Buffer, lineRange: Range<Int>, predicate: (KittyPlacementImage) -> Bool) -> Set<KittyPlacementKey> {
        let lower = max(0, lineRange.lowerBound)
        let upper = min(lineRange.upperBound, buffer.lines.count)
        if lower >= upper {
            return []
        }
        var removedKeys = Set<KittyPlacementKey>()
        var minLine = Int.max
        var maxLine = -1
        for idx in lower..<upper {
            let line = buffer.lines[idx]
            guard let images = line.images else {
                continue
            }
            var kept: [TerminalImage] = []
            var lineRemoved = false
            for image in images {
                if let kitty = image as? KittyPlacementImage, kitty.kittyIsKitty, predicate(kitty) {
                    if let imageId = kitty.kittyImageId, let placementId = kitty.kittyPlacementId {
                        removedKeys.insert(KittyPlacementKey(imageId: imageId, placementId: placementId))
                    }
                    lineRemoved = true
                } else {
                    kept.append(image)
                }
            }
            if lineRemoved {
                line.images = kept.isEmpty ? nil : kept
                minLine = min(minLine, idx)
                maxLine = max(maxLine, idx)
            }
        }
        if minLine <= maxLine, buffer === self.buffer {
            // Convert absolute buffer line indices to display-relative row indices.
            // minLine/maxLine are indices into buffer.lines[], while updateRange expects
            // 0-based display rows (0 = top of viewport). For the alternate screen yBase==0
            // so they coincide, but for the normal screen with scrollback they differ.
            let displayMin = minLine - buffer.yBase
            let displayMax = maxLine - buffer.yBase
            if displayMax >= 0 && displayMin < rows {
                updateRange(startLine: max(0, displayMin), endLine: min(rows - 1, displayMax))
            }
        }
        return removedKeys
    }

    private func removeKittyPlacementsByKey(_ keys: Set<KittyPlacementKey>) -> Set<KittyPlacementKey> {
        if keys.isEmpty {
            return []
        }
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard let imageId = image.kittyImageId, let placementId = image.kittyPlacementId else {
                return false
            }
            return keys.contains(KittyPlacementKey(imageId: imageId, placementId: placementId))
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let combined = removedKeys.union(altRemoved)
        // Line stripes are freed even when the record survives; release the
        // retained-stripe cost so accounting tracks actual bitmaps.
        releaseRenderedStripeCost(keys: combined)
        return combined
    }

    private func removePlacementRecords(_ predicate: (KittyPlacementRecord) -> Bool) -> Set<KittyPlacementKey> {
        var removed = Set<KittyPlacementKey>()
        for (key, record) in kittyGraphicsState.placementsByKey where predicate(record) {
            removed.insert(key)
        }
        for key in removed {
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
        }
        releaseRenderedStripeCost(keys: removed)
        return removed
    }

    private func recordIntersectsCell(_ record: KittyPlacementRecord, col: Int, row: Int) -> Bool {
        let left = record.col
        let top = record.row
        let width = max(1, record.cols)
        let height = max(1, record.rows)
        let right = left + width - 1
        let bottom = top + height - 1
        return col >= left && col <= right && row >= top && row <= bottom
    }

    private func recordIntersectsRow(_ record: KittyPlacementRecord, row: Int) -> Bool {
        let top = record.row
        let height = max(1, record.rows)
        let bottom = top + height - 1
        return row >= top && row <= bottom
    }

    private func recordIntersectsColumn(_ record: KittyPlacementRecord, col: Int) -> Bool {
        let left = record.col
        let width = max(1, record.cols)
        let right = left + width - 1
        return col >= left && col <= right
    }

    private func recordIntersectsScreen(_ record: KittyPlacementRecord) -> Bool {
        let screenTop = buffer.yBase
        let screenBottom = buffer.yBase + rows - 1
        let screenLeft = 0
        let screenRight = cols - 1
        let left = record.col
        let top = record.row
        let width = max(1, record.cols)
        let height = max(1, record.rows)
        let right = left + width - 1
        let bottom = top + height - 1
        return right >= screenLeft && left <= screenRight && bottom >= screenTop && top <= screenBottom
    }

    func cleanupUnusedKittyImages() {
        let used = collectUsedKittyImageIds()
        let unusedIds = kittyGraphicsState.imagesById.keys.filter { !used.contains($0) }
        for id in unusedIds {
            removeKittyImage(imageId: id)
        }
    }

    func storeKittyImage(payload: KittyGraphicsPayload, imageId: UInt32, imageNumber: UInt32?) {
        setKittyImagePayloadStaged(payload: payload, imageId: imageId, imageNumber: imageNumber)
        enforceKittyImageCacheLimit()
    }

    /// Stores one image payload without cache enforcement. The two-phase
    /// install commits every staged payload first and enforces once, so a
    /// prevalidated atomic batch cannot evict itself mid-commit.
    func setKittyImagePayloadStaged(payload: KittyGraphicsPayload, imageId: UInt32, imageNumber: UInt32?) {
        let byteSize = kittyPayloadByteSize(payload)
        let lastAccessTick = nextKittyImageAccessTick()
        if let existing = kittyGraphicsState.imagesById[imageId] {
            kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - existing.byteSize)
        }
        kittyGraphicsState.imagesById[imageId] = KittyGraphicsImage(payload: payload,
                                                                   byteSize: byteSize,
                                                                   lastAccessTick: lastAccessTick)
        kittyGraphicsState.totalImageBytes += byteSize
        if let number = imageNumber {
            kittyGraphicsState.imageNumbers[number] = imageId
        }
    }

    private func updateKittyImageAccess(imageId: UInt32) -> KittyGraphicsImage? {
        guard var image = kittyGraphicsState.imagesById[imageId] else {
            return nil
        }
        image.lastAccessTick = nextKittyImageAccessTick()
        kittyGraphicsState.imagesById[imageId] = image
        return image
    }

    func kittyPayloadByteSize(_ payload: KittyGraphicsPayload) -> Int {
        switch payload {
        case .png(let data):
            return data.count
        case .rgba(let bytes, _, _):
            return bytes.count
        }
    }

    func nextKittyImageAccessTick() -> UInt64 {
        let tick = kittyGraphicsState.nextImageAccessTick
        kittyGraphicsState.nextImageAccessTick &+= 1
        return tick
    }

    func enforceKittyImageCacheLimit() {
        let limit = clampedKittyImageCacheLimitBytes()
        guard kittyGraphicsState.totalImageBytes > limit else {
            return
        }

        let used = collectUsedKittyImageIds()
        let unusedIds = kittyGraphicsState.imagesById
            .filter { !used.contains($0.key) }
            .sorted { $0.value.lastAccessTick < $1.value.lastAccessTick }
            .map { $0.key }
        for id in unusedIds {
            removeKittyImage(imageId: id)
            if kittyGraphicsState.totalImageBytes <= limit {
                return
            }
        }

        let oldestIds = kittyGraphicsState.imagesById
            .sorted { $0.value.lastAccessTick < $1.value.lastAccessTick }
            .map { $0.key }
        for id in oldestIds {
            removeKittyImage(imageId: id)
            if kittyGraphicsState.totalImageBytes <= limit {
                return
            }
        }
    }

    func clampedKittyImageCacheLimitBytes() -> Int {
        let configured = options.kittyImageCacheLimitBytes
        if configured <= 0 {
            return 0
        }
        return min(configured, Terminal.kittyMaxImageCacheBytes)
    }

    private func removeKittyImage(imageId: UInt32) {
        guard let removed = kittyGraphicsState.imagesById.removeValue(forKey: imageId) else {
            return
        }
        kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - removed.byteSize)
        removeKittyImageNumbers(for: imageId)
    }

    func removeKittyImageNumbers(for imageId: UInt32) {
        let numbers = kittyGraphicsState.imageNumbers.filter { $0.value == imageId }.map { $0.key }
        for number in numbers {
            kittyGraphicsState.imageNumbers.removeValue(forKey: number)
        }
    }

    private func collectUsedKittyImageIds() -> Set<UInt32> {
        var used = Set<UInt32>()
        collectUsedKittyImageIds(from: normalBuffer, into: &used)
        collectUsedKittyImageIds(from: altBuffer, into: &used)
        for record in kittyGraphicsState.placementsByKey.values {
            used.insert(record.imageId)
        }
        return used
    }

    private func collectUsedKittyImageIds(from buffer: Buffer, into set: inout Set<UInt32>) {
        for idx in 0..<buffer.lines.count {
            let line = buffer.lines[idx]
            guard let images = line.images else { continue }
            for image in images {
                if let kitty = image as? KittyPlacementImage, let imageId = kitty.kittyImageId {
                    set.insert(imageId)
                }
            }
        }
    }

    private func kittyPlacementIntersectsCell(_ image: KittyPlacementImage, col: Int, row: Int) -> Bool {
        let left = image.kittyCol
        let top = image.kittyRow
        let width = max(1, image.kittyCols)
        let height = max(1, image.kittyRows)
        let right = left + width - 1
        let bottom = top + height - 1
        return col >= left && col <= right && row >= top && row <= bottom
    }

    private func kittyPlacementIntersectsRow(_ image: KittyPlacementImage, row: Int) -> Bool {
        let top = image.kittyRow
        let height = max(1, image.kittyRows)
        let bottom = top + height - 1
        return row >= top && row <= bottom
    }

    private func kittyPlacementIntersectsColumn(_ image: KittyPlacementImage, col: Int) -> Bool {
        let left = image.kittyCol
        let width = max(1, image.kittyCols)
        let right = left + width - 1
        return col >= left && col <= right
    }

    /// zlib inflate with an in-loop output cap. The default preserves the
    /// legacy bound; pass a smaller cap to enforce admission while appending.
    /// Shares the pure-Swift RFC1950 decoder with the two-phase prepare path
    /// so `o=z` behaves identically on every platform.
    private func decompressZlib(_ data: Data, maxOutputBytes: Int = Terminal.kittyMaxImageBytes) -> Data? {
        HostedKittyImageDecoder.decompressZlib(data, maxOutputBytes: maxOutputBytes)
    }
}
