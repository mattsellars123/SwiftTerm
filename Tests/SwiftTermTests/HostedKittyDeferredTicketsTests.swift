//
//  HostedKittyDeferredTicketsTests.swift
//
//  Coverage for `Terminal.makeHostedKittyDeferredTickets(manifest:payloads:)`:
//  the reconnect-hydration entry point that converts an installed manifest
//  plus its deferred payload snapshot into immutable two-phase decode
//  tickets without touching cursor, APC replies, placeholders, or stored
//  payloads. Tickets flow through the existing `prepareHostedKittyBatch`
//  (off-thread) and `installHostedKittyPreparedImages` (feeding thread)
//  transaction.
//

import Foundation
import Testing

@testable import SwiftTerm

final class HostedKittyDeferredTicketsTests {
    private func makeTerminal(cells: (width: Int, height: Int)? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        delegate.cellSizeInPixelsValue = cells
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 5))
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

    private var png1x1Base64: String {
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    }

    private func headlessPlaceholderLines(_ terminal: Terminal) -> [Int] {
        var lines: [Int] = []
        for row in 0..<terminal.buffer.lines.count {
            guard let images = terminal.buffer.lines[row].images else { continue }
            if images.contains(where: { $0 is KittyHeadlessPlacementImage }) {
                lines.append(row)
            }
        }
        return lines
    }

    private func firstPlaceholderLine(for imageId: UInt32, placementId: UInt32, in terminal: Terminal) -> Int? {
        for row in 0..<terminal.buffer.lines.count {
            guard let images = terminal.buffer.lines[row].images else { continue }
            for image in images {
                if let kitty = image as? KittyPlacementImage,
                   image is KittyHeadlessPlacementImage,
                   kitty.kittyImageId == imageId,
                   kitty.kittyPlacementId == placementId {
                    return row
                }
            }
        }
        return nil
    }

    /// Legacy-fed source terminal with one RGBA image, snapshotted exactly
    /// like a reconnect host would export it.
    private func rgbaSourceSnapshot() -> TerminalKittyGraphicsSnapshot? {
        let (source, _) = makeTerminal()
        sendKitty(terminal: source, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,q=2,C=1", base64: rgba2x2Base64)
        return source.makeKittyGraphicsSnapshot(
            firstInvariantRow: source.buffer.totalLinesTrimmed,
            retainedLineCount: source.buffer.lines.count,
            maximumPayloadBytes: 1024 * 1024
        )
    }

    private func installedTarget(for snapshot: TerminalKittyGraphicsSnapshot,
                                cells: (width: Int, height: Int)? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate)? {
        let (target, delegate) = makeTerminal(cells: cells)
        guard target.prepareKittyGraphicsManifest(snapshot.manifest) else { return nil }
        delegate.clearSentData()
        return (target, delegate)
    }

    @Test func testValidManifestYieldsAnchoredRGBATicketsAndInstalls() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, delegate) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        #expect(snapshot.placements.count == 1)

        let cursorX = target.buffer.x
        let cursorY = target.buffer.y
        let placeholderLines = headlessPlaceholderLines(target)

        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: snapshot.payloads) else {
            Issue.record("expected tickets, got nil")
            return
        }
        #expect(tickets.count == 1)
        let ticket = tickets[0]
        let placement = snapshot.placements[0]

        // Identity and fencing capture.
        #expect(ticket.imageId == placement.imageID)
        #expect(ticket.placementId == placement.placementID)
        #expect(ticket.epoch == target.hostedGraphicsEpoch)
        #expect(ticket.isAlternateBuffer == target.isCurrentBufferAlternate)
        #expect(ticket.originLinesTop == target.buffer.linesTop)

        // RGBA request form with the stored geometry.
        #expect(ticket.format == 32)
        #expect(ticket.rawWidth == 2)
        #expect(ticket.rawHeight == 2)
        #expect(ticket.compression == nil)
        #expect(ticket.columns == placement.columns)
        #expect(ticket.rows == placement.rows)
        #expect(ticket.zIndex == placement.zIndex)

        // Headless target captures no cell geometry.
        #expect(ticket.cellWidthPx == nil)
        #expect(ticket.cellHeightPx == nil)

        // Anchor points at the first live placeholder row, so the view maps
        // surviving lines to stripe indices exactly.
        guard let firstLine = firstPlaceholderLine(for: ticket.imageId, placementId: ticket.placementId, in: target) else {
            Issue.record("expected live placeholder rows")
            return
        }
        #expect(ticket.anchorRow == firstLine)
        #expect((firstLine + target.buffer.linesTop) - (ticket.anchorRow + ticket.originLinesTop) == 0)

        // Read-only: cursor, replies, placeholders, payloads, queue untouched.
        #expect(target.buffer.x == cursorX)
        #expect(target.buffer.y == cursorY)
        #expect(delegate.sentData.isEmpty)
        #expect(headlessPlaceholderLines(target) == placeholderLines)
        #expect(target.kittyGraphicsState.imagesById.isEmpty)
        #expect(target.takePendingHostedKittyRenders().isEmpty)

        // The ticket round-trips the exact snapshot bytes.
        guard let roundTripped = Data(base64Encoded: Data(ticket.base64Payload)) else {
            Issue.record("ticket payload is not valid base64")
            return
        }
        #expect(roundTripped == Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]))

        // Full two-phase flow: off-thread prepare, feeding-thread install.
        guard case .success(let prepared) = prepareHostedKittyBatch(tickets) else {
            Issue.record("expected batch preparation to succeed")
            return
        }
        #expect(prepared.count == 1)
        #expect(prepared[0].stripes.isEmpty)
        let outcome = target.installHostedKittyPreparedImages(prepared)
        #expect(outcome == .installed(placements: 1))
        #expect(target.kittyGraphicsState.imagesById[placement.imageID] != nil)
    }

    @Test func testPNGTicketForm() {
        let (source, _) = makeTerminal()
        sendKitty(terminal: source, control: "a=T,f=100,t=d,c=2,r=1,i=9,q=2,C=1", base64: png1x1Base64)
        guard let snapshot = source.makeKittyGraphicsSnapshot(
            firstInvariantRow: source.buffer.totalLinesTrimmed,
            retainedLineCount: source.buffer.lines.count,
            maximumPayloadBytes: 1024 * 1024),
              let (target, _) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: snapshot.payloads) else {
            Issue.record("expected tickets, got nil")
            return
        }
        #expect(tickets.count == 1)
        #expect(tickets[0].format == 100)
        #expect(Data(base64Encoded: Data(tickets[0].base64Payload)) == Data(base64Encoded: png1x1Base64))

#if canImport(ImageIO)
        guard case .success(let prepared) = prepareHostedKittyBatch(tickets) else {
            Issue.record("expected PNG batch preparation to succeed")
            return
        }
        #expect(prepared[0].width == 1)
        #expect(prepared[0].height == 1)
        let outcome = target.installHostedKittyPreparedImages(prepared)
        #expect(outcome == .installed(placements: 1))
        #expect(target.kittyGraphicsState.imagesById[9] != nil)
#endif
    }

    @Test func testViewBackedTicketsCarryCellGeometryAndStripes() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, delegate) = installedTarget(for: snapshot, cells: (width: 7, height: 14)) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: snapshot.payloads) else {
            Issue.record("expected tickets, got nil")
            return
        }
        #expect(tickets.count == 1)
        #expect(tickets[0].cellWidthPx == 7)
        #expect(tickets[0].cellHeightPx == 14)

        guard case .success(let prepared) = prepareHostedKittyBatch(tickets) else {
            Issue.record("expected batch preparation to succeed")
            return
        }
        #expect(prepared[0].stripes.count == tickets[0].rows)
        let outcome = target.installHostedKittyPreparedImages(prepared)
        #expect(outcome == .installed(placements: 1))
    }

    @Test func testRemovedPlacementsYieldEmptyNotNil() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, delegate) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        target.feed(text: "\u{1b}[2J")
        delegate.clearSentData()

        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: snapshot.payloads) else {
            Issue.record("expected empty array, got nil")
            return
        }
        #expect(tickets.isEmpty)
        #expect(target.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test func testReplacedPlacementIsOmittedAndNeverClobbered() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, delegate) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        let placementId = snapshot.placements[0].placementID
        // Suffix replaces the image bytes under the same ids with a visibly
        // different payload (green instead of red first pixel).
        let replacement = Data([0, 255, 0, 255,
                                0, 255, 0, 255,
                                0, 0, 255, 255,
                                255, 255, 255, 255]).base64EncodedString()
        sendKitty(terminal: target, control: "a=T,f=32,s=2,v=2,t=d,c=3,r=2,i=7,p=\(placementId),q=2,C=1", base64: replacement)
        delegate.clearSentData()

        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: snapshot.payloads) else {
            Issue.record("expected empty array, got nil")
            return
        }
        #expect(tickets.isEmpty)
        // The live replacement payload survives untouched.
        guard case .rgba(let bytes, _, _) = target.kittyGraphicsState.imagesById[7]?.payload else {
            Issue.record("expected live replacement payload to survive")
            return
        }
        #expect(bytes[0] == 0)
        #expect(bytes[1] == 255)
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testPayloadWithoutSurvivingPlacementYieldsEmpty() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, _) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        // Payloads for an image the manifest never installed match nothing.
        let extra = TerminalKittyGraphicsSnapshot.Image(id: 99, number: nil, payload: .rgba(Data(repeating: 1, count: 16), width: 2, height: 2))
        let payloads = TerminalKittyGraphicsPayloadSnapshot(images: [extra])
        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: payloads) else {
            Issue.record("expected empty array, got nil")
            return
        }
        #expect(tickets.isEmpty)
        #expect(target.kittyGraphicsState.imagesById.isEmpty)
    }

    @Test func testInvalidInputReturnsNilWithoutMutation() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, delegate) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        func checkNil(manifest: TerminalKittyGraphicsManifest,
                      payloads: TerminalKittyGraphicsPayloadSnapshot,
                      fileID: String = #fileID, filePath: String = #filePath, line: Int = #line) {
            let cursorX = target.buffer.x
            let cursorY = target.buffer.y
            let placeholders = headlessPlaceholderLines(target)
            let records = target.kittyGraphicsState.placementsByKey.count
            let result = target.makeHostedKittyDeferredTickets(manifest: manifest, payloads: payloads)
            #expect(result == nil, sourceLocation: Testing.SourceLocation(fileID: fileID, filePath: filePath, line: line, column: 1))
            #expect(target.buffer.x == cursorX)
            #expect(target.buffer.y == cursorY)
            #expect(delegate.sentData.isEmpty)
            #expect(headlessPlaceholderLines(target) == placeholders)
            #expect(target.kittyGraphicsState.placementsByKey.count == records)
            #expect(target.kittyGraphicsState.imagesById.isEmpty)
            #expect(target.takePendingHostedKittyRenders().isEmpty)
        }

        let validImage = snapshot.payloads.images[0]
        // Version mismatch on either side.
        checkNil(manifest: TerminalKittyGraphicsManifest(version: 2,
                                                         retainedLineCount: snapshot.manifest.retainedLineCount,
                                                         placements: snapshot.manifest.placements),
                 payloads: snapshot.payloads)
        checkNil(manifest: snapshot.manifest,
                 payloads: TerminalKittyGraphicsPayloadSnapshot(version: 2, images: snapshot.payloads.images))
        // Structurally invalid manifest placement.
        let badPlacement = TerminalKittyGraphicsSnapshot.Placement(imageID: 7, imageNumber: nil, placementID: 1,
                                                                   column: 0, relativeRow: 0, columns: 0, rows: 2,
                                                                   zIndex: 0, pixelOffsetX: 0, pixelOffsetY: 0)
        checkNil(manifest: TerminalKittyGraphicsManifest(retainedLineCount: snapshot.manifest.retainedLineCount,
                                                         placements: [badPlacement]),
                 payloads: snapshot.payloads)
        // RGBA bytes that do not match their dimensions.
        let badRgba = TerminalKittyGraphicsSnapshot.Image(id: validImage.id, number: validImage.number,
                                                          payload: .rgba(Data([1, 2, 3]), width: 2, height: 2))
        checkNil(manifest: snapshot.manifest,
                 payloads: TerminalKittyGraphicsPayloadSnapshot(images: [badRgba]))
        // Duplicate payload ids cannot be addressed unambiguously.
        checkNil(manifest: snapshot.manifest,
                 payloads: TerminalKittyGraphicsPayloadSnapshot(images: [validImage, validImage]))
        // Empty PNG data can never decode.
        let emptyPng = TerminalKittyGraphicsSnapshot.Image(id: validImage.id, number: validImage.number,
                                                           payload: .png(Data()))
        checkNil(manifest: snapshot.manifest,
                 payloads: TerminalKittyGraphicsPayloadSnapshot(images: [emptyPng]))
    }

    @Test func testTicketCreationIsDeterministicAndRepeatable() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, _) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        guard let first = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                payloads: snapshot.payloads),
              let second = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                 payloads: snapshot.payloads) else {
            Issue.record("expected tickets, got nil")
            return
        }
        // `enqueuedAt` stamps each call; everything else must be stable.
        var normalizedFirst = first
        var normalizedSecond = second
        for i in normalizedFirst.indices { normalizedFirst[i].enqueuedAt = Date(timeIntervalSince1970: 0) }
        for i in normalizedSecond.indices { normalizedSecond[i].enqueuedAt = Date(timeIntervalSince1970: 0) }
        #expect(normalizedFirst == normalizedSecond)
        #expect(first.count == 1)
    }

    @Test func testScrollBetweenTicketAndInstallStillInstalls() {
        guard let snapshot = rgbaSourceSnapshot(),
              let (target, _) = installedTarget(for: snapshot) else {
            Issue.record("expected snapshot and manifest install")
            return
        }
        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: snapshot.manifest,
                                                                  payloads: snapshot.payloads) else {
            Issue.record("expected tickets, got nil")
            return
        }
        // Viewport scroll after ticket capture: absolute line coordinates
        // are stable, so the captured anchor still maps stripe zero.
        target.feed(text: "\n\n\n")
        guard case .success(let prepared) = prepareHostedKittyBatch(tickets) else {
            Issue.record("expected batch preparation to succeed")
            return
        }
        let outcome = target.installHostedKittyPreparedImages(prepared)
        #expect(outcome == .installed(placements: 1))
        #expect(target.kittyGraphicsState.imagesById[7] != nil)
    }
}
