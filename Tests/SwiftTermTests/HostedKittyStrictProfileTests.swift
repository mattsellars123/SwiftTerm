//
//  HostedKittyStrictProfileTests.swift
//
//  Second-pass U1 review fixes: stored-block/exact-cap inflate, pre-copy m=0
//  caps with checked arithmetic, IHDR-prefix PNG sniff, aggregate batch cap,
//  overflow-safe geometry, bounded anonymous lifecycle, strict hosted profile
//  (deferred a=T,t=d only), and legacy store-then-place preservation.
//

import Foundation
import Testing

@testable import SwiftTerm

final class HostedKittyStrictProfileTests {
    private func makeTerminal(options: TerminalOptions? = nil,
                              cells: (width: Int, height: Int)? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        delegate.cellSizeInPixelsValue = cells
        var resolved = options ?? TerminalOptions(cols: 20, rows: 8)
        resolved.hostedKittyTwoPhaseRendering = true
        let terminal = Terminal(delegate: delegate, options: resolved)
        return (terminal, delegate)
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

    private var png1x1Base64: String {
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    }

    /// 100 `A` bytes at zlib level 0 (stored blocks only).
    private var stored100Base64: String {
        "eAEBZACb/0FBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEC6Rll"
    }

    private func responses(_ delegate: TerminalTestDelegate) -> String {
        String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
    }

    private func solidTicket(columns: Int = 2, rows: Int = 1) -> HostedKittyRenderRequest {
        var bytes: [UInt8] = []
        for _ in 0..<4 { bytes.append(contentsOf: [255, 0, 0, 255]) }
        return HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                        placementId: 1, columns: columns, rows: rows, zIndex: 0,
                                        pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                        rawWidth: 2, rawHeight: 2, compression: nil,
                                        base64Payload: Array(Data(bytes).base64EncodedString().utf8),
                                        isAlternateBuffer: false)
    }

    // MARK: - (1) stored blocks + exact cap

    @Test func testStoredBlockPrepareAndExactCap() {
        // 100 stored bytes decode to 100 `A`s.
        let ticket = HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 1, imageNumber: nil,
                                              placementId: 1, columns: 1, rows: 1, zIndex: 0,
                                              pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                              rawWidth: 5, rawHeight: 5, compression: "z",
                                              base64Payload: Array(stored100Base64.utf8),
                                              isAlternateBuffer: false)
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected stored-block preparation")
            return
        }
        #expect(image.rgba.count == 100)
        #expect(image.rgba.allSatisfy { $0 == 65 })

        // Exact cap admits byte-for-byte on the binding intermediate (the
        // 111-byte encoding); one less rejects.
        guard case .success = prepareHostedKittyRender(ticket, limits: HostedKittyGraphicsLimits(maxPayloadBytes: 111)) else {
            Issue.record("expected exact-cap admission")
            return
        }
        let tight = HostedKittyGraphicsLimits(maxPayloadBytes: 110)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            Issue.record("expected exact-cap rejection")
            return
        }
        guard case .exceedsPayloadLimit = error else {
            Issue.record("expected exceedsPayloadLimit, got \(error)")
            return
        }
    }

    @Test func testStoredBlockLegacyInlinePath() {
        // Flag off: the legacy store path shares the fixed decoder.
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 8))
        sendKitty(terminal: terminal, control: "a=t,f=32,s=5,v=5,t=d,o=z,i=60", base64: stored100Base64)
        #expect(terminal.kittyGraphicsState.imagesById[60]?.byteSize == 100)
    }

    // MARK: - (2) pre-copy m=0 caps, checked arithmetic

    @Test func testParserCapsOversizeApc() {
        // Whole-APC retention (control text included) is capped in the
        // parser before any terminal allocation: one typed overflow, zero
        // terminal state.
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedMaxPartialEncodedBytes: 16)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=1", base64: String(repeating: "Q", count: 20))
        #expect(responses(delegate).contains("EOVERFLOW"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(t.hostedKittyQueueMetrics().partialEncodedBytes == 0)
        // Flag off: the same bytes reach normal processing (here a payload
        // validation error, proving the parser did not interfere).
        let offDelegate = TerminalTestDelegate()
        let offTerminal = Terminal(delegate: offDelegate, options: TerminalOptions(cols: 20, rows: 8))
        sendKitty(terminal: offTerminal, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=1", base64: String(repeating: "Q", count: 20))
        let offResponse = String(bytes: offDelegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(offResponse.contains("EINVAL"))
    }

    @Test func testTerminatingChunkOverflowDrops() {
        // Each chunk fits whole-APC retention, but their sum exceeds the
        // cross-chunk accumulation cap: the terminating reassembly is
        // dropped before its copy, with a typed error.
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedMaxPartialEncodedBytes: 128)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=2,r=1,i=1,m=1;\(String(repeating: "Q", count: 80))\u{1b}\\")
        #expect(t.hostedKittyQueueMetrics().partialEncodedBytes == 80)
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=2,r=1,i=1,m=0;\(String(repeating: "Q", count: 80))\u{1b}\\")
        #expect(responses(delegate).contains("EOVERFLOW"))
        #expect(t.hostedKittyQueueMetrics().partialEncodedBytes == 0)
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    @Test func testEncodedFitsCheckedArithmetic() {
        #expect(hostedEncodedFits(current: 0, additional: 16, limit: 16))
        #expect(!hostedEncodedFits(current: 16, additional: 1, limit: 16))
        #expect(!hostedEncodedFits(current: 20, additional: 0, limit: 16))
        #expect(!hostedEncodedFits(current: -1, additional: 5, limit: 16))
        #expect(!hostedEncodedFits(current: 5, additional: -1, limit: 16))
        // Near-Int.max values must decide without trapping: (max-1)+2 would
        // overflow with `+`, so it is correctly rejected here.
        #expect(!hostedEncodedFits(current: Int.max - 1, additional: 2, limit: Int.max))
        #expect(hostedEncodedFits(current: Int.max, additional: 0, limit: Int.max))
        #expect(!hostedEncodedFits(current: Int.max, additional: 1, limit: Int.max))
    }

    // MARK: - (3) IHDR-prefix sniff

    @Test func testPNGAutoUsesPrefixSniff() {
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        // Auto-size PNG: grid comes from the 24-byte prefix alone.
        sendKitty(terminal: t, control: "a=T,f=100,t=d,i=61", base64: png1x1Base64)
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        #expect(pending[0].columns == 1 && pending[0].rows == 1)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test func testSniffRejectsNonPNG() {
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        let zeros = Data(count: 24).base64EncodedString()
        sendKitty(terminal: t, control: "a=T,f=100,t=d,i=62", base64: zeros)
        #expect(responses(delegate).contains("EINVAL"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        // Short payloads cannot hold a signature plus IHDR dims.
        delegate.clearSentData()
        sendKitty(terminal: t, control: "a=T,f=100,t=d,i=63", base64: "QUJD")
        #expect(responses(delegate).contains("EINVAL"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
    }

    @Test func testSniffUnitAndHugeDims() {
        let (t, _) = makeTerminal()
        let prefix = Data(base64Encoded: png1x1Base64)!.prefix(24)
        let sniffed = t.hostedSniffPNGDimensions(base64Payload: Array(png1x1Base64.utf8))
        #expect(sniffed?.width == 1 && sniffed?.height == 1)
        #expect(t.hostedSniffPNGDimensions(base64Payload: Array(Data(count: 24).base64EncodedString().utf8)) == nil)
        #expect(t.hostedSniffPNGDimensions(base64Payload: Array("QUJD".utf8)) == nil)
        // Absurd dimensions parse (prefix trust boundary) but can never trap;
        // the grid caps reject them downstream.
        var huge = Array(prefix)
        huge[16] = 255; huge[17] = 255; huge[18] = 255; huge[19] = 255
        huge[20] = 255; huge[21] = 255; huge[22] = 255; huge[23] = 255
        let hugeBase64 = Data(huge).base64EncodedString()
        let hugeSniffed = t.hostedSniffPNGDimensions(base64Payload: Array(hugeBase64.utf8))
        #expect(hugeSniffed?.width == 4294967295 && hugeSniffed?.height == 4294967295)

        let (t2, delegate2) = makeTerminal(cells: (width: 8, height: 16))
        sendKitty(terminal: t2, control: "a=T,f=100,t=d,i=64", base64: hugeBase64)
        #expect(responses(delegate2).contains("EOVERFLOW"))
        #expect(t2.takePendingHostedKittyRenders().isEmpty)
        #expect(t2.kittyGraphicsState.placementsByKey.isEmpty)
    }

    // MARK: - (4) aggregate batch cap

    @Test func testBatchAggregateCap() {
        let (t, _) = makeTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=70", base64: rgba2x2Base64)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=71", base64: rgba2x2Base64)
        let tickets = t.takePendingHostedKittyRenders()
        #expect(tickets.count == 2)
        // Two 16-byte payloads exceed a 20-byte in-flight budget: the batch
        // fails before anything is retained.
        let tiny = HostedKittyGraphicsLimits(maxPreparedBatchBytes: 20)
        guard case .failure(let error) = prepareHostedKittyBatch(tickets, limits: tiny) else {
            Issue.record("expected batch-limit failure")
            return
        }
        guard case .exceedsBatchLimit = error else {
            Issue.record("expected exceedsBatchLimit, got \(error)")
            return
        }
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        // Control: the same batch fits the default budget.
        guard case .success(let batch) = prepareHostedKittyBatch(tickets) else {
            Issue.record("expected successful control batch")
            return
        }
        #expect(batch.count == 2)
    }

    // MARK: - (5) overflow-safe geometry

    @Test func testHugePlacementNoTrap() {
        let (t, delegate) = makeTerminal()
        t.feed(text: "AB")
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=9223372036854775807,r=9223372036854775807,i=80", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("EOVERFLOW"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        t.feed(text: "CD")
        let lines = TerminalTestHarness.visibleLinesText(buffer: t.buffer, terminal: t)
        #expect(lines[0].hasPrefix("ABCD"))
    }

    @Test func testHugePixelOffsetClampedNoTrap() {
        let (t, _) = makeTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=81,X=9223372036854775807,Y=9223372036854775807", base64: rgba2x2Base64)
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        #expect(pending[0].pixelOffsetX <= t.hostedKittyLimits().maxImageDimension)
        #expect(pending[0].pixelOffsetY <= t.hostedKittyLimits().maxImageDimension)
    }

    @Test func testHostilePrepareAndInstallNoTrap() {
        // Hand-built ticket with absurd geometry: rejection, not a trap.
        var ticket = solidTicket()
        ticket.columns = Int.max
        guard case .failure(let error) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected hostile-ticket failure")
            return
        }
        #expect(error == .badDimensions)
        // Hostile cell capture: checked canvas math rejects, never traps.
        ticket = solidTicket()
        ticket.columns = 100
        ticket.cellWidthPx = Int.max
        ticket.cellHeightPx = 16
        guard case .failure = prepareHostedKittyRender(ticket) else {
            Issue.record("expected hostile-cell failure")
            return
        }

        // Hostile prepared values: install rejects shape violations safely.
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=82", base64: rgba2x2Base64)
        let real = t.takePendingHostedKittyRenders()[0]
        guard case .success(var image) = prepareHostedKittyRender(real) else {
            Issue.record("expected successful preparation")
            return
        }
        image.rows = Int.max
        guard case .rejected = t.installHostedKittyPreparedImages([image]) else {
            Issue.record("expected rows-mismatch rejection")
            return
        }
        guard case .success(var image2) = prepareHostedKittyRender(real) else {
            Issue.record("expected successful preparation")
            return
        }
        image2.stripes[0] = HostedKittyPreparedStripe(stripeIndex: 0, width: Int.max, height: 2, rgba: Data(count: 8))
        guard case .rejected = t.installHostedKittyPreparedImages([image2]) else {
            Issue.record("expected stripe-overflow rejection")
            return
        }
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyImageMemoryUsage().totalBytes == 0)
    }

    // MARK: - (6) bounded anonymous lifecycle

    @Test func testAnonymousEvictionBounded() {
        // Twenty anonymous displays stay responsive (never rejected) while
        // live anonymous placements stay capped with oldest-first eviction.
        let (t2, delegate2) = makeTerminal()
        var pids: [UInt32] = []
        for _ in 0..<20 {
            sendKitty(terminal: t2, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1", base64: rgba2x2Base64)
            let pending = t2.takePendingHostedKittyRenders()
            #expect(pending.count == 1)
            #expect(pending[0].isAnonymous)
            pids.append(pending[0].placementId)
        }
        #expect(!responses(delegate2).contains("EBUSY"))
        #expect(!responses(delegate2).contains("EOVERFLOW"))
        let liveAnonymous = t2.kittyGraphicsState.placementsByKey.keys.filter { key in
            t2.kittyGraphicsState.imagesById[key.imageId] == nil
        }
        #expect(liveAnonymous.count <= t2.hostedKittyLimits().maxAnonymousPlacements)
        #expect(t2.kittyGraphicsState.placementsByKey[KittyPlacementKey(imageId: 1, placementId: pids[0])] == nil)
        // Anonymous displays store no payload and send no reply.
        #expect(t2.kittyGraphicsState.imagesById.isEmpty)
        #expect(responses(delegate2).isEmpty)
        #expect(t2.kittyImageMemoryUsage().totalBytes == 0)
    }

    // MARK: - strict hosted profile

    @Test func testStrictProfileRejectsNonDeferredWorkflows() {
        let (t, delegate) = makeTerminal()
        t.feed(text: "AB")
        // Store without display.
        sendKitty(terminal: t, control: "a=t,f=32,s=2,v=2,t=d,i=90", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("ENOTSUP"))
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        // Store-then-place.
        sendKitty(terminal: t, control: "a=p,i=90,c=2,r=1", base64: "")
        #expect(responses(delegate).contains("ENOTSUP"))
        // Query.
        sendKitty(terminal: t, control: "a=q,f=32,s=2,v=2,t=d,i=90", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("ENOTSUP"))
        // File-backed display.
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=f,c=2,r=1,i=91", base64: "L3RtcC94")
        #expect(responses(delegate).contains("ENOTSUP"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        // Deletes are rejected with zero mutation: the placement survives.
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=92", base64: rgba2x2Base64)
        #expect(t.takePendingHostedKittyRenders().count == 1)
        t.feed(text: "\u{1b}_Ga=d,d=A\u{1b}\\")
        #expect(responses(delegate).contains("ENOTSUP"))
        #expect(t.kittyGraphicsState.placementsByKey.count == 1)
        // Text/protocol ordering survives every rejection. The admitted i=92
        // display advanced the cursor one row, so CD lands on row 1.
        t.feed(text: "CD")
        let lines = TerminalTestHarness.visibleLinesText(buffer: t.buffer, terminal: t)
        #expect(lines[0].hasPrefix("AB"))
        #expect(lines[1].contains("CD"))
    }

    @Test func testLegacyStoreThenPlaceUnchangedWhenFlagOff() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 8))
        sendKitty(terminal: terminal, control: "a=t,f=32,s=2,v=2,t=d,i=70", base64: rgba2x2Base64)
        #expect(terminal.kittyGraphicsState.imagesById[70]?.byteSize == 16)
        sendKitty(terminal: terminal, control: "a=p,i=70,c=2,r=1", base64: "")
        let response = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(response.contains("OK"))
        #expect(terminal.kittyGraphicsState.imagesById[70] != nil)
        #expect(terminal.takePendingHostedKittyRenders().isEmpty)
    }
}

final class HostedKittyFinalReviewTests {
    private func makeTerminal(options: TerminalOptions? = nil,
                              cells: (width: Int, height: Int)? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        delegate.cellSizeInPixelsValue = cells
        var resolved = options ?? TerminalOptions(cols: 20, rows: 8)
        resolved.hostedKittyTwoPhaseRendering = true
        return (Terminal(delegate: delegate, options: resolved), delegate)
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

    private func responses(_ delegate: TerminalTestDelegate) -> String {
        String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
    }

    // MARK: - (1) parser-level encoded cap across feeds

    @Test func testParserCapsAcrossFeeds() {
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedMaxPartialEncodedBytes: 64)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        // Split one APC across feeds: retention stops at the cap mid-stream
        // instead of allocating the full sequence.
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=2,r=1,i=5,m=0;" + String(repeating: "Q", count: 30))
        #expect(t.parser._apc.count <= 65)
        t.feed(text: String(repeating: "Q", count: 30))
        #expect(t.parser._apc.count <= 65)
        // The terminator emits exactly one typed overflow; nothing dispatches.
        t.feed(text: "\u{1b}\\")
        #expect(responses(delegate).components(separatedBy: "EOVERFLOW").count - 1 == 1)
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(t.kittyGraphicsState.pending == nil)
    }

    // MARK: - (2) earliest strict gate + delete traps

    @Test func testEarlyGateRejectsBeforeMutation() {
        let (t, delegate) = makeTerminal()
        // Non-conforming chunked transfers reject at entry: no partial kept.
        t.feed(text: "\u{1b}_Ga=t,f=32,s=2,v=2,t=d,i=90,m=1;QUJD\u{1b}\\")
        #expect(responses(delegate).contains("ENOTSUP"))
        #expect(t.kittyGraphicsState.pending == nil)
        t.feed(text: "\u{1b}_Ga=p,i=90,c=2,r=1,m=1;QUJD\u{1b}\\")
        #expect(t.kittyGraphicsState.pending == nil)
        // Unknown actions keep legacy EINVAL with zero mutation.
        t.feed(text: "\u{1b}_Ga=x\u{1b}\\")
        #expect(responses(delegate).contains("EINVAL"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        // A rejected delete mutates nothing, not even an open partial: the
        // transfer completes normally afterwards.
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=2,r=1,i=91,m=1;\(rgba2x2Base64)\u{1b}\\")
        #expect(t.kittyGraphicsState.pending != nil)
        t.feed(text: "\u{1b}_Ga=d,d=A\u{1b}\\")
        #expect(responses(delegate).contains("ENOTSUP"))
        #expect(t.kittyGraphicsState.pending != nil)
        t.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=2,r=1,i=91,m=0;\u{1b}\\")
        #expect(t.takePendingHostedKittyRenders().count == 1)
    }

    @Test func testDeleteFieldsNoTrap() {
        // Flag off keeps legacy deletes; absurd fields fail closed, never trap.
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 8))
        func resp() -> String {
            String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        }
        terminal.feed(text: "\u{1b}_Ga=d,d=r,x=4294967296,y=1\u{1b}\\")
        #expect(resp().contains("EINVAL"))
        terminal.feed(text: "\u{1b}_Ga=d,d=p,x=9223372036854775807,y=9223372036854775807\u{1b}\\")
        terminal.feed(text: "\u{1b}_Ga=d,d=y,y=9223372036854775807\u{1b}\\")
        terminal.feed(text: "\u{1b}_Ga=d,d=x,x=9223372036854775807\u{1b}\\")
        terminal.feed(text: "OK")
        let lines = TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal)
        #expect(lines[0].hasPrefix("OK"))
    }

    // MARK: - (3) checked parent offsets

    @Test func testParentOffsetOverflowRejects() {
        // Overflow needs a nonzero base (0 + Int.max is exactly Int.max),
        // so position the cursor first: 2 + Int.max and 1 + Int.max trap
        // without the checked arithmetic.
        let (t, delegate) = makeTerminal()
        t.feed(text: "AB\n")
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=4,r=2,i=40", base64: rgba2x2Base64)
        let pid = t.takePendingHostedKittyRenders()[0].placementId
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=41,P=40,Q=\(pid),H=9223372036854775807", base64: rgba2x2Base64)
        #expect(responses(delegate).contains("EINVAL"))
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=42,P=40,Q=\(pid),V=9223372036854775807", base64: rgba2x2Base64)
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.count == 1)
        // Int.min with a zero base cannot overflow; it clamps gracefully.
        let (t2, delegate2) = makeTerminal()
        sendKitty(terminal: t2, control: "a=T,f=32,s=2,v=2,t=d,c=4,r=2,i=40", base64: rgba2x2Base64)
        let pid2 = t2.takePendingHostedKittyRenders()[0].placementId
        sendKitty(terminal: t2, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=43,P=40,Q=\(pid2),H=-9223372036854775808", base64: rgba2x2Base64)
        #expect(t2.takePendingHostedKittyRenders().count == 1)
        _ = delegate2
        t.feed(text: "OK")
        let lines = TerminalTestHarness.visibleLinesText(buffer: t.buffer, terminal: t)
        #expect(lines.joined().contains("OK"))
    }

    @Test func testParentOffsetOverflowLegacyNoTrap() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 8))
        terminal.feed(text: "AB")
        sendKitty(terminal: terminal, control: "a=T,f=32,s=2,v=2,t=d,c=4,r=2,i=40", base64: rgba2x2Base64)
        // 2 + Int.max trapped here before the checked arithmetic.
        sendKitty(terminal: terminal, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=41,P=40,Q=1,H=9223372036854775807", base64: rgba2x2Base64)
        let resp = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(resp.contains("EINVAL"))
        terminal.feed(text: "OK")
        let lines = TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal)
        #expect(lines.joined().contains("OK"))
    }

    @Test func testRecursiveParentOffsetNoTrap() {
        let (t, _) = makeTerminal()
        t.registerKittyPlacement(imageId: 50, placementId: 1, parentImageId: nil, parentPlacementId: nil,
                                 parentOffsetH: 0, parentOffsetV: 0, pixelOffsetX: 0, pixelOffsetY: 0,
                                 col: 0, row: 0, cols: 2, rows: 1, zIndex: 0, isVirtual: true)
        t.registerKittyPlacement(imageId: 51, placementId: 1, parentImageId: 50, parentPlacementId: 1,
                                 parentOffsetH: Int.max, parentOffsetV: Int.min, pixelOffsetX: 0, pixelOffsetY: 0,
                                 col: 0, row: 0, cols: 2, rows: 1, zIndex: 0, isVirtual: true)
        // Recursive accumulation with absurd stored offsets unresolves the
        // placement instead of trapping.
        t.updateKittyRelativePlacementsForCurrentBuffer()
        #expect(t.kittyGraphicsState.placementsByKey.count == 2)
    }

    // MARK: - (4) scrollback lifecycle plateau

    @Test func testScrollbackTrimPlateausMemory() {
        var options = TerminalOptions(cols: 20, rows: 4, scrollback: 2)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTerminal(options: options)
        var installed = 0
        for n in 0..<30 {
            sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=\(100 + n)", base64: rgba2x2Base64)
            let tickets = t.takePendingHostedKittyRenders()
            guard tickets.count == 1 else {
                Issue.record("iteration \(n): expected one ticket")
                return
            }
            guard case .success(let image) = prepareHostedKittyRender(tickets[0]) else {
                Issue.record("iteration \(n): preparation failed")
                return
            }
            let outcome = t.installHostedKittyPreparedImages([image])
            guard case .installed = outcome else {
                Issue.record("iteration \(n): install failed with \(outcome)")
                return
            }
            installed += 1
        }
        #expect(installed == 30)
        // Dead anchors reaped, payloads reclaimed: bounded, not linear.
        #expect(t.kittyGraphicsState.placementsByKey.count <= 10)
        #expect(t.kittyGraphicsState.imagesById.count <= 10)
        #expect(t.kittyImageMemoryUsage().totalBytes <= 160)
        _ = delegate
    }

    @Test func testVirtualMetadataBounded() {
        let (t, delegate) = makeTerminal()
        var installed = 0
        for n in 0..<1100 {
            sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,U=1,i=\(200 + n)", base64: rgba2x2Base64)
            let tickets = t.takePendingHostedKittyRenders()
            guard tickets.count == 1 else {
                Issue.record("iteration \(n): expected one ticket")
                return
            }
            guard case .success(let image) = prepareHostedKittyRender(tickets[0]) else {
                Issue.record("iteration \(n): preparation failed")
                return
            }
            guard case .installed = t.installHostedKittyPreparedImages([image]) else {
                Issue.record("iteration \(n): install failed")
                return
            }
            installed += 1
        }
        #expect(installed == 1100)
        // Same-anchor virtuals never scroll out, so the count cap (with
        // oldest-first eviction of unanchored records) is the bound.
        #expect(t.kittyGraphicsState.placementsByKey.count <= 1024)
        #expect(t.kittyGraphicsState.imagesById.count <= 1024)
        #expect(t.kittyImageMemoryUsage().sourceBytes <= 1024 * 16)
        #expect(t.kittyGraphicsState.imagesById[200] == nil)
        #expect(t.kittyGraphicsState.imagesById[200 + 1099] != nil)
        _ = delegate
    }

#if os(macOS)
    @Test func testRealViewScrollbackPlateausRenderedMemory() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.terminal.options.hostedKittyTwoPhaseRendering = true
        let t = view.terminal!
        var perImage = 0
        var installed = 0
        for n in 0..<150 {
            sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=8,i=\(300 + n)", base64: rgba2x2Base64)
            let tickets = t.takePendingHostedKittyRenders()
            guard tickets.count == 1 else {
                Issue.record("iteration \(n): expected one ticket")
                return
            }
            guard case .success(let image) = prepareHostedKittyRender(tickets[0]) else {
                Issue.record("iteration \(n): preparation failed")
                return
            }
            if n == 0 { perImage = image.rgba.count + image.renderedByteCost }
            let outcome = t.installHostedKittyPreparedImages([image])
            guard case .installed = outcome else {
                Issue.record("iteration \(n): install failed with \(outcome)")
                return
            }
            installed += 1
        }
        #expect(installed == 150)
        // 1200 rows advanced against ~520 retained: trimmed placements are
        // reaped with their stripe costs and payloads reclaimed.
        #expect(t.kittyGraphicsState.placementsByKey.count <= 90)
        #expect(t.kittyGraphicsState.imagesById.count <= 90)
        #expect(t.kittyImageMemoryUsage().totalBytes <= 90 * perImage)
    }
#endif

    // MARK: - P2: compressed auto-size PNG

    @Test func testCompressedPNGAutoExplicitEnotsup() {
        let (t, delegate) = makeTerminal(cells: (width: 8, height: 16))
        // Compressed auto-size PNG cannot be gridded without inflating on
        // the feeding thread: explicit ENOTSUP, never a misleading EINVAL
        // from sniffing zlib bytes as a PNG header, and zero mutation.
        sendKitty(terminal: t, control: "a=T,f=100,t=d,o=z,i=70", base64: rgba2x2Base64)
        let response = responses(delegate)
        #expect(response.contains("ENOTSUP"))
        #expect(!response.contains("EINVAL"))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }
}
