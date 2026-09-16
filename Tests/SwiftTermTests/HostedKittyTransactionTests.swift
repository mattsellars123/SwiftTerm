//
//  HostedKittyTransactionTests.swift
//
//  Coverage for the two-phase hosted Kitty graphics transaction:
//  parse-time tickets without decoding, off-thread preparation, atomic
//  installation, stale-ticket fencing, admission limits, and limit survival
//  across reset.
//

import Foundation
import Testing

@testable import SwiftTerm

final class HostedKittyTransactionTests {
    private func makeTwoPhaseTerminal(options: TerminalOptions? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        var resolved = options ?? TerminalOptions(cols: 20, rows: 8)
        resolved.hostedKittyTwoPhaseRendering = true
        let terminal = Terminal(delegate: delegate, options: resolved)
        return (terminal, delegate)
    }

    private func sendKitty(terminal: Terminal, control: String, base64: String) {
        terminal.feed(text: "\u{1b}_G\(control);\(base64)\u{1b}\\")
    }

    /// 2x2 RGBA payload: 16 bytes.
    private var rgba2x2Base64: String {
        Data([255, 0, 0, 255,
              0, 255, 0, 255,
              0, 0, 255, 255,
              255, 255, 255, 255]).base64EncodedString()
    }

    @Test func testTwoPhaseDefersDecodeAndQueuesImmutableTicket() {
        let (t, _) = makeTwoPhaseTerminal()
        t.feed(text: "Hi\n")
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,z=5", base64: rgba2x2Base64)
        t.feed(text: "BYE")

        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        let ticket = pending[0]
        #expect(ticket.imageId == 7)
        #expect(ticket.columns == 3)
        #expect(ticket.rows == 2)
        #expect(ticket.epoch == t.hostedGraphicsEpoch)
        #expect(ticket.format == 32)
        #expect(!ticket.base64Payload.isEmpty)

        // Nothing decoded or stored on the parse path.
        #expect(t.kittyGraphicsState.imagesById[7] == nil)
        #expect(t.takePendingHostedKittyRenders().isEmpty)

        // Cursor-anchored placement is registered with geometry intact.
        let key = KittyPlacementKey(imageId: 7, placementId: ticket.placementId)
        let record = t.kittyGraphicsState.placementsByKey[key]
        #expect(record != nil)
        #expect(record?.cols == 3)
        #expect(record?.rows == 2)
        #expect(record?.zIndex == 5)

        // Surrounding text keeps its order around the image rows.
        let lines = TerminalTestHarness.visibleLinesText(buffer: t.buffer, terminal: t)
        #expect(lines.contains(where: { $0.hasPrefix("Hi") }))
        #expect(lines.contains(where: { $0.contains("BYE") }))
    }

    @Test func testSplitFeedProducesOneTicket() {
        let (t, _) = makeTwoPhaseTerminal()
        let sequence = "\u{1b}_Ga=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7;\(rgba2x2Base64)\u{1b}\\"
        let midpoint = sequence.index(sequence.startIndex, offsetBy: sequence.count / 2)
        t.feed(text: String(sequence[..<midpoint]))
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        t.feed(text: String(sequence[midpoint...]))
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        #expect(pending[0].imageId == 7)
    }

    @Test @MainActor func testPrepareOffMainAndInstallCommits() async {
        let (t, _) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        let ticket = t.takePendingHostedKittyRenders()[0]

        // Preparation crosses an isolation boundary: the request is Sendable
        // and preparation never touches terminal or view state.
        let prepared = await Task.detached {
            prepareHostedKittyRender(ticket)
        }.value
        guard case .success(let image) = prepared else {
            Issue.record("expected successful preparation")
            return
        }
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.rgba.count == 16)
        #expect(image.epoch == t.hostedGraphicsEpoch)

        let outcome = t.installHostedKittyPreparedImages([image])
        #expect(outcome == .installed(placements: 1))
        #expect(t.kittyGraphicsState.imagesById[7] != nil)
    }

    @Test func testBatchPrepareRejectsInvalidAtomically() {
        let (t, _) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=8", base64: rgba2x2Base64)
        var requests = t.takePendingHostedKittyRenders()
        #expect(requests.count == 2)
        requests[1].format = 99

        let result = prepareHostedKittyBatch(requests)
        guard case .failure(let error) = result else {
            Issue.record("expected batch preparation to fail")
            return
        }
        #expect(error == .unsupportedFormat(99))
        // No payload, cache, or stripe mutation was committed for any member.
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test func testInstallStaleAfterEvictionCannotResurrect() {
        // Hosted mode has no APC deletes: anonymous placements age out via
        // oldest-first eviction instead. An install for an evicted placement
        // reports stale and stores nothing.
        let (t, _) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2", base64: rgba2x2Base64)
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }
        for _ in 0..<16 {
            sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2", base64: rgba2x2Base64)
        }
        _ = t.takePendingHostedKittyRenders()

        let outcome = t.installHostedKittyPreparedImages([image])
        #expect(outcome == .stale)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test func testInstallStaleAfterEpochInvalidation() {
        let (t, _) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }

        let epoch = t.hostedGraphicsEpoch
        t.invalidateHostedKittyRenders()
        #expect(t.hostedGraphicsEpoch == epoch + 1)
        #expect(t.takePendingHostedKittyRenders().isEmpty)

        let outcome = t.installHostedKittyPreparedImages([image])
        #expect(outcome == .stale)
        #expect(t.kittyGraphicsState.imagesById[7] == nil)
    }

    @Test func testInstallRejectedWhenCacheExceededCommitsNothing() {
        var options = TerminalOptions(cols: 20, rows: 8, kittyImageCacheLimitBytes: 10)
        options.hostedKittyTwoPhaseRendering = true
        let (t, _) = makeTwoPhaseTerminal(options: options)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }

        let outcome = t.installHostedKittyPreparedImages([image])
        guard case .rejected = outcome else {
            Issue.record("expected cache-limit rejection, got \(outcome)")
            return
        }
        #expect(t.kittyGraphicsState.imagesById[7] == nil)
        // The placeholder survives rejection so terminal geometry is intact.
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    @Test func testLimitsSurviveResetAndRetireTickets() {
        var options = TerminalOptions(cols: 20, rows: 8,
                                      kittyImageCacheLimitBytes: 8 * 1024 * 1024,
                                      kittyHostedPayloadLimitBytes: 4 * 1024 * 1024,
                                      hostedKittyTwoPhaseRendering: true)
        let (t, _) = makeTwoPhaseTerminal(options: options)
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        let ticket = t.takePendingHostedKittyRenders()[0]
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation")
            return
        }
        let epoch = t.hostedGraphicsEpoch

        t.feed(text: "\u{1b}c")

        #expect(t.options.kittyImageCacheLimitBytes == 8 * 1024 * 1024)
        #expect(t.options.kittyHostedPayloadLimitBytes == 4 * 1024 * 1024)
        #expect(t.options.hostedKittyTwoPhaseRendering == true)
        #expect(t.hostedGraphicsEpoch == epoch + 1)
        #expect(t.takePendingHostedKittyRenders().isEmpty)

        let outcome = t.installHostedKittyPreparedImages([image])
        #expect(outcome == .stale)
        #expect(t.kittyGraphicsState.imagesById[7] == nil)
    }

    @Test func testLegacyInlinePathUnchangedWhenFlagOff() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 8))
        sendKitty(terminal: terminal, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        #expect(terminal.takePendingHostedKittyRenders().isEmpty)
        #expect(terminal.kittyGraphicsState.imagesById[7] != nil)
    }

    @Test func testHostedLimitsReflectOptionsAndEnforcePayloadCap() {
        var options = TerminalOptions(cols: 20, rows: 8, kittyHostedPayloadLimitBytes: 4)
        options.hostedKittyTwoPhaseRendering = true
        let (t, delegate) = makeTwoPhaseTerminal(options: options)
        #expect(t.hostedKittyLimits().maxPayloadBytes == 4)

        // Admission passes before any mutation: an over-limit payload is
        // rejected at parse time with a typed in-order error, so no ticket
        // is ever queued and prepare has nothing to fail on.
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: rgba2x2Base64)
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.imagesById[7] == nil)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        let responses = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(responses.contains("EOVERFLOW"))

        // The same payload prepares fine under the default limits, proving
        // the rejection came from the configured terminal limits.
        let ticket = HostedKittyRenderRequest(epoch: t.hostedGraphicsEpoch,
                                              originLinesTop: 0,
                                              imageId: 7,
                                              imageNumber: nil,
                                              placementId: 1,
                                              columns: 3,
                                              rows: 2,
                                              zIndex: 0,
                                              pixelOffsetX: 0,
                                              pixelOffsetY: 0,
                                              format: 32,
                                              rawWidth: 2,
                                              rawHeight: 2,
                                              compression: nil,
                                              base64Payload: Array(rgba2x2Base64.utf8),
                                              isAlternateBuffer: false)
        guard case .success(let image) = prepareHostedKittyRender(ticket) else {
            Issue.record("expected successful preparation under default limits")
            return
        }
        #expect(image.rgba.count == 16)
    }

    @Test func testMalformedPayloadNeverReachesInstall() {
        let (t, _) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7", base64: "!!!not-base64!!!")
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        let result = prepareHostedKittyRender(pending[0])
        guard case .failure = result else {
            Issue.record("expected preparation failure for malformed payload")
            return
        }
        #expect(t.kittyGraphicsState.imagesById[7] == nil)
    }

    @Test func testMutuallyExclusiveIdsRejectedWithFlagOn() {
        let (t, delegate) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,I=9", base64: rgba2x2Base64)
        // The deferred path must not accept what inline validation rejects.
        #expect(t.takePendingHostedKittyRenders().isEmpty)
        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
        let responses = String(bytes: delegate.sentData.flatMap { $0 }, encoding: .utf8) ?? ""
        #expect(responses.contains("EINVAL"))
    }

    @Test func testCursorPolicyPreservedLikeInlinePath() {
        let (t, _) = makeTwoPhaseTerminal()
        t.feed(text: "AB")
        sendKitty(terminal: t, control: "a=T,f=32,s=2,v=2,t=d,c=2,r=1,i=7,C=1", base64: rgba2x2Base64)
        #expect(t.takePendingHostedKittyRenders().count == 1)
        // Cursor policy 1 preserves the pre-image cursor position.
        #expect(t.buffer.x == 2)
        #expect(t.buffer.y == 0)
    }

#if canImport(ImageIO)
    @Test @MainActor func testPNGTicketRoundTrip() async {
        // 1x1 transparent PNG.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let (t, _) = makeTwoPhaseTerminal()
        sendKitty(terminal: t, control: "a=T,f=100,t=d,c=2,r=1,i=9", base64: pngBase64)
        let pending = t.takePendingHostedKittyRenders()
        #expect(pending.count == 1)
        #expect(t.kittyGraphicsState.imagesById[9] == nil)

        let prepared = await Task.detached {
            prepareHostedKittyRender(pending[0])
        }.value
        guard case .success(let image) = prepared else {
            Issue.record("expected successful PNG preparation")
            return
        }
        #expect(image.width == 1)
        #expect(image.height == 1)
        #expect(image.rgba.count == 4)

        let outcome = t.installHostedKittyPreparedImages([image])
        #expect(outcome == .installed(placements: 1))
        #expect(t.kittyGraphicsState.imagesById[9] != nil)
    }
#endif
}
