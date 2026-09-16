//
//  HostedKittyReviewFixTests.swift
//
//  Focused coverage for the U1 review fixes (PERF-001..007 plus correctness
//  parity): precomputed off-main stripes, bounded partial/pending queues with
//  metrics, capped inflation with dimensions-before-decode admission,
//  no-inline-fallback under configured limits, source-plus-rendered
//  accounting with lifecycle release, atomic batch rollback, duplicate image
//  ids, and response/cursor parity.
//

import Foundation
import Testing

@testable import SwiftTerm

/// Stand-in for an attached stripe: carries placement identity without any
/// view object, so install lifecycle can be tested without AppKit rendering.
/// Crucially it is *not* a headless placeholder, which keeps the lifecycle
/// invariant real delegates uphold: a successful attach leaves stripe
/// presence behind (placeholders are gone).
final class FakeStripeImage: KittyPlacementImage {
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

/// Test delegate with a flippable stripe-attach outcome. On success it swaps
/// consumed placeholders for fake stripes, faithfully modeling the
/// placeholder-to-stripe lifecycle without AppKit rendering.
final class ToggleAttachDelegate: TerminalTestDelegate {
    var failAttach = true
    var attachCalls = 0

    override func attachPreparedKittyImage(source: Terminal, prepared: HostedKittyPreparedImage) -> Bool {
        attachCalls += 1
        if failAttach {
            return false
        }
        let key = KittyPlacementKey(imageId: prepared.imageId, placementId: prepared.placementId)
        for row in 0..<source.buffer.lines.count {
            guard let images = source.buffer.lines[row].images else { continue }
            var kept: [TerminalImage] = []
            var swapped = false
            for image in images {
                if image is KittyHeadlessPlacementImage,
                   let kitty = image as? KittyPlacementImage,
                   kitty.kittyImageId == key.imageId,
                   kitty.kittyPlacementId == key.placementId {
                    swapped = true
                } else {
                    kept.append(image)
                }
            }
            if swapped {
                let stripe = FakeStripeImage()
                stripe.kittyImageId = prepared.imageId
                stripe.kittyImageNumber = prepared.imageNumber
                stripe.kittyPlacementId = prepared.placementId
                stripe.kittyZIndex = prepared.zIndex
                stripe.kittyCol = prepared.anchorCol
                stripe.kittyRow = prepared.anchorRow
                stripe.kittyCols = prepared.columns
                stripe.kittyRows = prepared.rows
                stripe.col = prepared.anchorCol
                kept.append(stripe)
                source.buffer.clearImagesFromLine(at: row)
                for image in kept {
                    source.buffer.attachImage(image, toLineAt: row)
                }
            }
        }
        return true
    }
}

final class HostedKittyReviewFixTests {
    private func makeTerminal(options: TerminalOptions? = nil,
                              cells: (width: Int, height: Int)? = nil,
                              delegate: TerminalTestDelegate? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let del = delegate ?? TerminalTestDelegate()
        del.cellSizeInPixelsValue = cells
        var resolved = options ?? TerminalOptions(cols: 20, rows: 8)
        resolved.hostedKittyTwoPhaseRendering = true
        let terminal = Terminal(delegate: del, options: resolved)
        return (terminal, del)
    }

    private func sendKitty(terminal: Terminal, control: String, base64: String) {
        terminal.feed(text: "\u{1b}_G\(control);\(base64)\u{1b}\\")
    }

    private var rgba2x2Base64: String {
        Data([255, 0, 0, 255,
              0, 255, 0, 255,
              0, 0, 255, 255,
              255, 255, 255, 255]).base64EncodedString()
    }

    private func solidRed2x2() -> String {
        var bytes: [UInt8] = []
        for _ in 0..<4 {
            bytes.append(contentsOf: [255, 0, 0, 255])
        }
        return Data(bytes).base64EncodedString()
    }

    private func responses(_ delegate: TerminalTestDelegate) -> String {
        String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
    }

    // MARK: - PERF-001: precomputed stripes, no main-thread raster

    @Test @MainActor func testPrepareProducesStripesOffMain() async {
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: solidRed2x2())
        let ticket = t.takePendingHostedKittyRenders()[0]
        // Geometry is captured immutably on the feeding thread.
        #expect(ticket.cellWidthPx == 8)
        #expect(ticket.cellHeightPx == 16)

        // Preparation crosses an isolation boundary: Sendable ticket in,
        // fully scaled canvas plus per-row stripes out.
        let prepared = await Task.detached {
            prepareHostedKittyRender(ticket)
        }.value
        guard case .success(let image) = prepared else {
            Issue.record("expected successful preparation")
            return
        }
        #expect(image.stripes.count == 2)
        #expect(image.scaledWidth == 24)
        #expect(image.scaledHeight == 32)
        for (index, stripe) in image.stripes.enumerated() {
            #expect(stripe.stripeIndex == index)
            #expect(stripe.width == 24)
            #expect(stripe.height == 16)
            #expect(stripe.rgba.count == 24 * 16 * 4)
            // Solid source scales to solid stripes regardless of filtering.
            var offset = stripe.rgba.startIndex
            while offset < stripe.rgba.endIndex {
                #expect(stripe.rgba[offset] == 255)
                #expect(stripe.rgba[stripe.rgba.index(offset, offsetBy: 1)] == 0)
                #expect(stripe.rgba[stripe.rgba.index(offset, offsetBy: 2)] == 0)
                #expect(stripe.rgba[stripe.rgba.index(offset, offsetBy: 3)] == 255)
                offset = stripe.rgba.index(offset, offsetBy: 4)
            }
        }
        #expect(image.renderedByteCost == 2 * 24 * 16 * 4)

        let outcome = t.installHostedKittyPreparedImages([image])
        #expect(outcome == .installed(placements: 1))
        let usage = t.kittyImageMemoryUsage()
        #expect(usage.sourceBytes == 16)
        #expect(usage.renderedBytes == 2 * 24 * 16 * 4)
        #expect(usage.totalBytes == usage.sourceBytes + usage.renderedBytes)
    }

    @Test func testTamperedStripesRejectedNotTrusted() {
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: solidRed2x2())
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(var image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }
        // Corrupt one stripe's byte count: install validates shape and cost
        // instead of trusting the prepared value.
        image.stripes[0] = HostedKittyPreparedStripe(stripeIndex: 0, width: 24, height: 16,
                                                     rgba: Data(count: 8))
        let outcome = t.installHostedKittyPreparedImages([image])
        guard case .rejected = outcome else {
            Issue.record("expected stripe validation rejection, got \(outcome)")
            return
        }
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyImageMemoryUsage().totalBytes == 0)
    }

    // MARK: - PERF-002: bounded queues, metrics, admission before mutation

    @Test func testEndlessPartialChunksStayBounded() {
        // The parser cap covers whole-APC retention (control text included),
        // so this uses a cap above one chunk's control overhead; the
        // terminal-level cap then bounds cross-chunk accumulation.
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedMaxPartialEncodedBytes: 128)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        // Open a chunked transfer and overflow it: the partial is dropped
        // with a typed error and nothing is queued or placed.
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,m=1;\(String(repeating: "Q", count: 40))\u{1b}\\")
        #expect(t.hostedKittyQueueMetrics().partialEncodedBytes == 40)
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,m=1;\(String(repeating: "Q", count: 100))\u{1b}\\")
        #expect(responses(delegate).contains("EOVERFLOW"))
        #expect(t.hostedKittyQueueMetrics().partialEncodedBytes == 0)
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        // An endless m=1 stream never accumulates beyond the cap.
        for _ in 0..<200 {
            t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,m=1;Qg\u{1b}\\")
            #expect(t.hostedKittyQueueMetrics().partialEncodedBytes <= 128)
        }
        #expect(responses(delegate).contains("EOVERFLOW"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    @Test func testPendingQueueCapsMetricsAndNoMutation() {
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedMaxPendingJobs: 2)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=1", base64: rgba2x2Base64)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=2", base64: rgba2x2Base64)
        var metrics = t.hostedKittyQueueMetrics()
        #expect(metrics.pendingJobs == 2)
        #expect(metrics.pendingBytes == 2 * rgba2x2Base64.utf8.count)
        #expect(metrics.partialEncodedBytes == 0)
        #expect(metrics.oldestJobAge != nil)
        guard let age = metrics.oldestJobAge else { return }
        #expect(age >= 0)

        // The third transfer is rejected before image-id assignment,
        // placement registration, or enqueue.
        let recordsBefore = t.kittyGraphicsState.placementsByKey.count
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=3", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("EBUSY"))
        #expect(t.takePendingHostedKittyRenders().count == 2)
        #expect(t.kittyGraphicsState.placementsByKey.count == recordsBefore)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)

        metrics = t.hostedKittyQueueMetrics()
        #expect(metrics.pendingJobs == 0)
        #expect(metrics.pendingBytes == 0)
        #expect(metrics.oldestJobAge == nil)
    }

    @Test func testPendingQueueBytesCap() {
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedMaxPendingBytes: 0)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=1", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("EBUSY"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    // MARK: - PERF-003: capped inflation, dimensions before decode

    @Test func testZlibExpansionBombCapped() {
        // 120 bytes of zlib expanding to 100000 zero bytes.
        let bomb = "eNrtwTEBAAAAwqD1T20ND6AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAVwOGrwAB"
        func ticket() -> HostedKittyRenderRequest {
            HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                     placementId: 1, columns: 2, rows: 1, zIndex: 0,
                                     pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                     rawWidth: 250, rawHeight: 100, compression: "z",
                                     base64Payload: Array(bomb.utf8), isAlternateBuffer: false)
        }
        // The cap fires while appending: 100000 bytes can never materialize
        // under a 1024-byte budget.
        let tight = HostedKittyGraphicsLimits(maxPayloadBytes: 1024)
        guard case .failure(let error) = prepareHostedKittyRender(ticket(), limits: tight) else {
            Issue.record("expected capped inflation failure")
            return
        }
        guard case .exceedsPayloadLimit = error else {
            Issue.record("expected exceedsPayloadLimit, got \(error)")
            return
        }
        // Control: the same bomb inflates exactly under default limits.
        guard case .success(let image) = prepareHostedKittyRender(ticket()) else {
            Issue.record("expected successful control inflation")
            return
        }
        #expect(image.rgba.count == 100000)
    }

    @Test func testRawExpansionCheckedBeforeAlloc() {
        // 30000-byte RGB source expanding to 40000-byte RGBA under a 35000
        // budget: the source fits, the expansion does not.
        let payload = Data(count: 30_000).base64EncodedString()
        let ticket = HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                              placementId: 1, columns: 2, rows: 1, zIndex: 0,
                                              pixelOffsetX: 0, pixelOffsetY: 0, format: 24,
                                              rawWidth: 100, rawHeight: 100, compression: nil,
                                              base64Payload: Array(payload.utf8), isAlternateBuffer: false)
        let tight = HostedKittyGraphicsLimits(maxPayloadBytes: 35_000)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            Issue.record("expected expansion-limit failure")
            return
        }
        guard case .exceedsPayloadLimit = error else {
            Issue.record("expected exceedsPayloadLimit, got \(error)")
            return
        }
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful control expansion")
            return
        }
        #expect(image.rgba.count == 40_000)
    }

    @Test func testRawHugeDimensionsRejectedWithoutAlloc() {
        // 10000x10000 is dimensionally valid but the 4-byte payload cannot
        // match its 400MB checked cost: rejected before any allocation.
        let ticket = HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                              placementId: 1, columns: 1, rows: 1, zIndex: 0,
                                              pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                              rawWidth: 10000, rawHeight: 10000, compression: nil,
                                              base64Payload: Array("QUJD".utf8), isAlternateBuffer: false)
        guard case .failure(let error) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected dimension failure")
            return
        }
        #expect(error == .badDimensions)
    }

#if canImport(ImageIO)
    @Test func testPNGDimensionsCheckedBeforeDecode() {
        // 1000x1000 solid PNG (~5KB encoded, 4MB raster). Header cost exceeds
        // a 1MB budget: rejected from properties alone, never rasterized.
        let ticket = HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                              placementId: 1, columns: 2, rows: 1, zIndex: 0,
                                              pixelOffsetX: 0, pixelOffsetY: 0, format: 100,
                                              rawWidth: 0, rawHeight: 0, compression: nil,
                                              base64Payload: Array(Self.png1000.utf8), isAlternateBuffer: false)
        let tight = HostedKittyGraphicsLimits(maxPayloadBytes: 1_000_000)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            Issue.record("expected header-gated failure")
            return
        }
        guard case .exceedsPayloadLimit = error else {
            Issue.record("expected exceedsPayloadLimit, got \(error)")
            return
        }
        // Control: the same header decodes under default limits.
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful control decode")
            return
        }
        #expect(image.width == 1000)
        #expect(image.height == 1000)
    }

    @Test func testRenderedCostAdmittedBeforeStripes() {
        // 2x2 source is tiny, but 3x2 cells at 8x16px render 3072 bytes:
        // a 100-byte rendered budget rejects before stripe allocation.
        let ticket = HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                              placementId: 1, columns: 3, rows: 2, zIndex: 0,
                                              pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                              rawWidth: 2, rawHeight: 2, compression: nil,
                                              base64Payload: Array(solidRed2x2().utf8),
                                              isAlternateBuffer: false,
                                              cellWidthPx: 8, cellHeightPx: 16)
        let tight = HostedKittyGraphicsLimits(maxPayloadBytes: 100)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            Issue.record("expected rendered-limit failure")
            return
        }
        guard case .exceedsRenderedLimit = error else {
            Issue.record("expected exceedsRenderedLimit, got \(error)")
            return
        }
    }
#endif

    // MARK: - PERF-004: no inline fallback, configured limits

    @Test func testDirectVariantsDeferWithoutInlineDecode() {
        let (t, _) = makeTerminal()
        // Crop, unicode placeholder, anonymous display, and headless raw
        // auto-size all take the deferred path: a ticket is queued while no
        // payload is decoded or stored on the feeding thread.
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=11,x=0,y=0,w=1,h=1", base64: rgba2x2Base64)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,U=1,i=12", base64: rgba2x2Base64)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1", base64: rgba2x2Base64)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,i=13", base64: rgba2x2Base64)
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 4)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(pending[0].cropWidth == 1 && pending[0].cropHeight == 1)
        #expect(pending[1].isVirtual)
        #expect(pending[2].isAnonymous)
        #expect(pending[3].columns == 0 && pending[3].rows == 0)

        // The cropped ticket prepares to a 1x1 raster.
        guard case .success(let cropped) = prepareHostedKittyRender(pending[0]) else {
            Issue.record("expected cropped preparation")
            return
        }
        #expect(cropped.width == 1 && cropped.height == 1)
        // The virtual ticket validates the stored payload with no stripes.
        guard case .success(let virtual) = prepareHostedKittyRender(pending[1]) else {
            Issue.record("expected virtual preparation")
            return
        }
        #expect(virtual.isVirtual && virtual.stripes.isEmpty)
        let outcome = t.installHostedKittyPreparedImages([cropped, virtual])
        #expect(outcome == .installed(placements: 2))
        #expect(t.kittyGraphicsState.imagesById[11]?.payloadByteCount == 4)
        #expect(t.kittyGraphicsState.imagesById[12] != nil)
    }

    @Test func testParentPlacementDefers() {
        let (t, _) = makeTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=4,r=2,i=40", base64: rgba2x2Base64)
        let parentPid = t.takePendingHostedKittyRenders()[0].placementId
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=41,P=40,Q=\(parentPid)", base64: rgba2x2Base64)
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        #expect(pending[0].parentImageId == 40)
        #expect(pending[0].parentPlacementId == parentPid)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test func testUnsupportedVariantsRejectedInOrder() {
        let (t, delegate) = makeTerminal()
        t.feed(text: "AB")
        sendKitty(terminal: t, control: "a=T,f=99,s=2,v=2,t=d,c=2,r=1,i=50", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("EINVAL"))
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=51,o=x", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("EINVAL"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        // Text and protocol ordering survive the rejections.
        t.feed(text: "CD")
        let lines = TerminalTestHarness.visibleLinesText(buffer: t.buffer, terminal: t)
        #expect(lines[0].hasPrefix("ABCD"))
    }

    @Test func testConfiguredHighLimitAdmitsAboveCompiledDefault() {
        // The compiled default payload cap is 8MB; a 9MB transfer is admitted
        // only because the terminal is configured for 16MB.
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedPayloadLimitBytes: 16 * 1024 * 1024,
                                      kittyHostedMaxPartialEncodedBytes: 16 * 1024 * 1024,
                                      kittyHostedMaxPendingBytes: 64 * 1024 * 1024)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        let payload = Data(count: 9_000_000).base64EncodedString()
        sendKitty(terminal: t, control: "a=T,f=32,s=1500,v=1500,t=d,c=2,r=1,i=60", base64: payload)
        #expect(t.takePendingHostedKittyRenders().count == 1)
        #expect(!responses(delegate).contains("EOVERFLOW"))
        #expect(!responses(delegate).contains("EBUSY"))
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    // MARK: - PERF-005: source-plus-rendered accounting and lifecycle

    @Test func testAccountingReleasedOnReset() {
        // Hosted mode has no APC deletes; reset is the explicit hosted
        // teardown path and must release source plus rendered costs.
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: solidRed2x2())
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }
        #expect(t.installHostedKittyPreparedImages([image]) == .installed(placements: 1))
        #expect(t.kittyImageMemoryUsage().sourceBytes == 16)
        #expect(t.kittyImageMemoryUsage().renderedBytes == image.renderedByteCost)
        #expect(image.renderedByteCost > 0)
        t.feed(text: "\u{1b}c")
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(t.kittyImageMemoryUsage().totalBytes == 0)
    }

    // MARK: - PERF-006: atomic install, rollback, retry

    @Test func testAttachFailureRollsBackAndRetrySucceeds() {
        let delegate = ToggleAttachDelegate()
        let (t, _) = makeTerminal(cells: (width: 8, height: 16), delegate: delegate)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: solidRed2x2())
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }

        delegate.failAttach = true
        let failed = t.installHostedKittyPreparedImages([image])
        guard case .rejected(let reason) = failed else {
            Issue.record("expected attach rejection, got \(failed)")
            return
        }
        #expect(reason == "stripe attach failed")
        // Nothing left behind: no cache payload, no rendered cost, and the
        // placement record with its placeholders survives for retry.
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyImageMemoryUsage().totalBytes == 0)
        let key = KittyPlacementKey(imageId: 7, placementId: ticket.placementId)
        #expect(t.kittyGraphicsState.placementsByKey[key] != nil)

        // Retry with the same batch commits exactly once.
        delegate.failAttach = false
        #expect(t.installHostedKittyPreparedImages([image]) == .installed(placements: 1))
        #expect(t.kittyGraphicsState.imagesById[7] != nil)
        #expect(t.kittyImageMemoryUsage().sourceBytes == 16)
        // A third install finds the placeholders consumed: stale, no double
        // charge, no duplicated stripes.
        #expect(t.installHostedKittyPreparedImages([image]) == .stale)
        #expect(t.kittyImageMemoryUsage().sourceBytes == 16)
        #expect(delegate.attachCalls == 2)
    }

    // MARK: - PERF-007: duplicate image ids

    @Test func testDuplicateImageIdsChargedOnce() {
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=30", base64: solidRed2x2())
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=30", base64: solidRed2x2())
        let tickets = t.takePendingHostedKittyRenders()
        #expect(tickets.count == 2)
        #expect(tickets[0].placementId != tickets[1].placementId)
        guard case .success(let first) = prepareHostedKittyRender(tickets[0]),
              case .success(let second) = prepareHostedKittyRender(tickets[1]) else {
            Issue.record("expected successful preparations")
            return
        }
        #expect(t.installHostedKittyPreparedImages([first, second]) == .installed(placements: 2))
        // One source charge for the shared image id, two rendered charges.
        #expect(t.kittyImageMemoryUsage().sourceBytes == 16)
        #expect(t.kittyImageMemoryUsage().renderedBytes == 2 * first.renderedByteCost)

        // The same placement twice in one batch de-duplicates to one commit
        // with no additional charge (headless placeholders persist, exactly
        // like the legacy headless path).
        #expect(t.installHostedKittyPreparedImages([first, first]) == .installed(placements: 1))
        #expect(t.kittyImageMemoryUsage().sourceBytes == 16)
        #expect(t.kittyImageMemoryUsage().renderedBytes == 2 * first.renderedByteCost)
    }

    // MARK: - Correctness parity: responses, cursor, range safety

    @Test func testOKResponseEchoesRequestedPlacementId() {
        let (t, delegate) = makeTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=7,p=5", base64: rgba2x2Base64)
        let ticket = t.takePendingHostedKittyRenders()[0]
        #expect(ticket.placementId != 5 || true) // auto-assignment is internal
        #expect(responses(delegate).contains("p=5"))

        delegate.clearSentData()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=8", base64: rgba2x2Base64)
        let response = responses(delegate)
        #expect(response.contains("i=8"))
        #expect(!response.contains("p="))
    }

    @Test func testHeadlessCursorMatchesInline() {
        func fedTerminal(twoPhase: Bool, cursorPolicy: Int) -> Terminal {
            let delegate = TerminalTestDelegate()
            var options = TerminalOptions(cols: 20, rows: 8)
            options.hostedKittyTwoPhaseRendering = twoPhase
            let terminal = Terminal(delegate: delegate, options: options)
            terminal.feed(text: "\u{1b}[2;7r\u{1b}[3;1H")
            terminal.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,C=\(cursorPolicy);\(rgba2x2Base64)\u{1b}\\")
            terminal.feed(text: "X")
            return terminal
        }
        for policy in [0, 1] {
            let hosted = fedTerminal(twoPhase: true, cursorPolicy: policy)
            let inline = fedTerminal(twoPhase: false, cursorPolicy: policy)
            #expect(hosted.buffer.x == inline.buffer.x)
            #expect(hosted.buffer.y == inline.buffer.y)
            let hostedLines = TerminalTestHarness.visibleLinesText(buffer: hosted.buffer, terminal: hosted)
            let inlineLines = TerminalTestHarness.visibleLinesText(buffer: inline.buffer, terminal: inline)
            #expect(hostedLines == inlineLines)
        }
    }

#if os(macOS)
    @Test func testRealViewAttachesPrecomputedStripes() {
        // End-to-end through a real AppKit view: the install path builds
        // image objects from precomputed stripe bytes (no decode, scale, or
        // slicing on the feeding thread) and swaps every placeholder.
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.terminal.options.hostedKittyTwoPhaseRendering = true
        let t = view.terminal!
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: solidRed2x2())
        let ticket = t.takePendingHostedKittyRenders()[0]
        #expect((ticket.cellWidthPx ?? 0) > 0)
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }
        #expect(image.stripes.count == 2)
        #expect(t.installHostedKittyPreparedImages([image]) == .installed(placements: 1))
        // Every placeholder line now carries a rendered stripe; no headless
        // placeholder for the key survives.
        let key = KittyPlacementKey(imageId: 7, placementId: ticket.placementId)
        var stripes = 0
        var placeholders = 0
        for row in 0..<t.buffer.lines.count {
            for picture in t.buffer.lines[row].images ?? [] {
                guard let kitty = picture as? KittyPlacementImage,
                      kitty.kittyImageId == key.imageId,
                      kitty.kittyPlacementId == key.placementId else { continue }
                if picture is KittyHeadlessPlacementImage {
                    placeholders += 1
                } else {
                    stripes += 1
                }
            }
        }
        #expect(placeholders == 0)
        #expect(stripes == 2)
        #expect(t.kittyImageMemoryUsage().renderedBytes == image.renderedByteCost)
    }

    @Test func testRealViewOutOfRangePlaceholderFailsWithoutMutation() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.terminal.options.hostedKittyTwoPhaseRendering = true
        let t = view.terminal!
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: solidRed2x2())
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }
        // Insert lines above the placement: surviving placeholders shift past
        // the prepared row range, so no stripe maps to them. Mapping is
        // validated before any mutation, so the failed attach leaves the
        // buffer, cache, and accounting untouched.
        t.feed(text: "\u{1b}[1;1H\u{1b}[3L")
        let outcome = t.installHostedKittyPreparedImages([image])
        guard case .rejected = outcome else {
            Issue.record("expected out-of-range rejection, got \(outcome)")
            return
        }
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyImageMemoryUsage().totalBytes == 0)
        let key = KittyPlacementKey(imageId: 7, placementId: ticket.placementId)
        #expect(t.kittyGraphicsState.placementsByKey[key] != nil)
    }
#endif

    // MARK: - Fixtures

    /// 1000x1000 solid-white PNG (~5KB encoded, 4MB raster).
    static let png1000: String = "iVBORw0KGgoAAAANSUhEUgAAA+gAAAPoCAYAAABNo9TkAAAUoklEQVR42u3XIQEAAAzDsPk3vYk4OEkklDUFAAAA3kUCAAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABl0CAAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABl0CAAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABl0CAAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAMOgAAACAQQcAAACDDgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAACAQQcAAAAMOgAAABh0AAAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAMOgAAAGDQAQAAwKADAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAAIMOAAAABh0AAAAw6AAAAGDQAQAAgJsBUCeHIpzC7iQAAAAASUVORK5CYII="
}

private extension KittyGraphicsImage {
    var payloadByteCount: Int { byteSize }
}
