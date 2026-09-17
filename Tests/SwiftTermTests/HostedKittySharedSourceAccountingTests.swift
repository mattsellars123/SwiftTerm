//
//  HostedKittySharedSourceAccountingTests.swift
//
//  PERF-3: deferred shared-source tickets alias raw bytes and the prepare
//  path reuses one raster per unique source, so `maxPreparedBatchBytes`
//  admission must charge verified shared source bytes once per unique
//  source identity while every placement still charges its own rendered
//  stripes. Distinct crops and same-id byte mismatches retain their own
//  charges and never alias.
//

import Foundation
import Testing

@testable import SwiftTerm

final class HostedKittySharedSourceAccountingTests {
    private func makeTerminal(cols: Int = 20, rows: Int = 12,
                              cells: (width: Int, height: Int)? = nil) -> (terminal: Terminal, delegate: TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        delegate.cellSizeInPixelsValue = cells
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows))
        return (terminal, delegate)
    }

    private func storeOnlyTicket(imageId: UInt32, placementId: UInt32, bytes: Data,
                                 cropX: Int = 0, cropY: Int = 0, cropWidth: Int = 0, cropHeight: Int = 0) -> HostedKittyRenderRequest {
        HostedKittyRenderRequest(epoch: 0, originLinesTop: 0,
                                 imageId: imageId, imageNumber: nil, placementId: placementId,
                                 columns: 0, rows: 0,
                                 zIndex: 0, pixelOffsetX: 0, pixelOffsetY: 0,
                                 format: 32, rawWidth: 2, rawHeight: 2,
                                 compression: nil, base64Payload: [],
                                 rawSourceBytes: bytes, isAlternateBuffer: false,
                                 cropX: cropX, cropY: cropY, cropWidth: cropWidth, cropHeight: cropHeight)
    }

    @Test func testSharedNearLimitSourcePreparesWithinUniqueBudgetAndInstalls() {
        // Near-payload-limit shared source: 1400x1400 RGBA = 7,840,000 bytes,
        // just under the default 8 MiB per-payload cap. Nine placements exceed
        // the old per-placement 64 MiB batch charge (9 x 7.84MB ~ 70.5MB) but
        // fit the unique-source plus rendered budget (~7.85MB).
        let dimension = 1400
        let sourceBytes = Data(repeating: 0x7F, count: dimension * dimension * 4)
        #expect(sourceBytes.count == 7_840_000)
        let placementCount = 9
        let limits = HostedKittyGraphicsLimits.default
        let oldStyleCharge = placementCount * sourceBytes.count
        #expect(oldStyleCharge > limits.maxPreparedBatchBytes)

        let (target, delegate) = makeTerminal(cells: (width: 8, height: 16))
        _ = delegate
        var manifestPlacements: [TerminalKittyGraphicsSnapshot.Placement] = []
        for index in 0..<placementCount {
            manifestPlacements.append(TerminalKittyGraphicsSnapshot.Placement(
                imageID: 7, imageNumber: nil, placementID: UInt32(index + 1),
                column: 0, relativeRow: index, columns: 2, rows: 1,
                zIndex: 0, pixelOffsetX: 0, pixelOffsetY: 0))
        }
        let manifest = TerminalKittyGraphicsManifest(retainedLineCount: placementCount, placements: manifestPlacements)
        let payloads = TerminalKittyGraphicsPayloadSnapshot(images: [
            TerminalKittyGraphicsSnapshot.Image(id: 7, number: nil,
                                                payload: .rgba(sourceBytes, width: dimension, height: dimension))
        ])
        guard target.prepareKittyGraphicsManifest(manifest) else {
            Issue.record("expected manifest install")
            return
        }
        guard let tickets = target.makeHostedKittyDeferredTickets(manifest: manifest, payloads: payloads) else {
            Issue.record("expected tickets, got nil")
            return
        }
        #expect(tickets.count == placementCount)
        #expect(tickets.allSatisfy { $0.base64Payload.isEmpty })
        #expect(tickets.allSatisfy { $0.rawSourceBytes == sourceBytes })

        guard case .success(let prepared) = prepareHostedKittyBatch(tickets) else {
            Issue.record("expected shared-source batch to fit unique-source budget")
            return
        }
        #expect(prepared.count == placementCount)
        #expect(prepared.allSatisfy { $0.stripes.count == 1 })
        let renderedPerPlacement = 2 * 8 * 1 * 16 * 4
        #expect(prepared.allSatisfy { $0.renderedByteCost == renderedPerPlacement })
        #expect(prepared.allSatisfy { $0.rgba == sourceBytes })
        // Unique-source charging: first placement carries the source, the
        // rest alias it and charge only their rendered stripes.
        #expect(prepared[0].sourceChargeBytes == sourceBytes.count)
        #expect(prepared.dropFirst().allSatisfy { $0.sourceChargeBytes == 0 })
        #expect(hostedPreparedBatchUniqueSourceBytes(prepared) == sourceBytes.count)
        #expect(hostedPreparedBatchRenderedBytes(prepared) == placementCount * renderedPerPlacement)
        #expect(hostedPreparedBatchChargedBytes(prepared) == sourceBytes.count + placementCount * renderedPerPlacement)
        #expect(hostedPreparedBatchChargedBytes(prepared) <= limits.maxPreparedBatchBytes)

        let outcome = target.installHostedKittyPreparedImages(prepared)
        #expect(outcome == .installed(placements: placementCount))
        #expect(target.kittyGraphicsState.imagesById[7] != nil)
        let usage = target.kittyImageMemoryUsage()
        #expect(usage.sourceBytes == sourceBytes.count)
        #expect(usage.renderedBytes == placementCount * renderedPerPlacement)
        #expect(usage.totalBytes == usage.sourceBytes + usage.renderedBytes)
    }

    @Test func testMismatchedBytesNeverAliasAndEachCharges() {
        let red = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let green = Data([0, 255, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        guard case .success(let prepared) = prepareHostedKittyBatch([
            storeOnlyTicket(imageId: 7, placementId: 1, bytes: red),
            storeOnlyTicket(imageId: 7, placementId: 2, bytes: green),
        ]) else {
            Issue.record("expected batch preparation to succeed")
            return
        }
        #expect(prepared.count == 2)
        #expect(prepared[0].rgba == red)
        #expect(prepared[1].rgba == green)
        #expect(prepared[0].rgba != prepared[1].rgba)
        // A same-id byte mismatch disables sharing: each ticket keeps its
        // own raster and its own full source charge.
        #expect(prepared[0].sourceChargeBytes == red.count)
        #expect(prepared[1].sourceChargeBytes == green.count)
        #expect(hostedPreparedBatchUniqueSourceBytes(prepared) == red.count + green.count)
        #expect(hostedPreparedBatchRenderedBytes(prepared) == 0)
    }

    @Test func testDistinctCropsRetainDistinctChargesWhileIdenticalCropsShare() {
        // 4x4 RGBA with a distinct byte per pixel block so different 2x2
        // crops produce different bytes.
        var pixels = [UInt8]()
        for i in 0..<16 {
            pixels.append(contentsOf: [UInt8(i), UInt8(255 - i), UInt8(i &* 7), 255])
        }
        let source = Data(pixels)
        #expect(source.count == 64)
        func ticket(placementId: UInt32, cropX: Int, cropY: Int) -> HostedKittyRenderRequest {
            HostedKittyRenderRequest(epoch: 0, originLinesTop: 0,
                                     imageId: 11, imageNumber: nil, placementId: placementId,
                                     columns: 0, rows: 0,
                                     zIndex: 0, pixelOffsetX: 0, pixelOffsetY: 0,
                                     format: 32, rawWidth: 4, rawHeight: 4,
                                     compression: nil, base64Payload: [],
                                     rawSourceBytes: source, isAlternateBuffer: false,
                                     cropX: cropX, cropY: cropY, cropWidth: 2, cropHeight: 2)
        }
        guard case .success(let prepared) = prepareHostedKittyBatch([
            ticket(placementId: 1, cropX: 0, cropY: 0),
            ticket(placementId: 2, cropX: 2, cropY: 2),
            ticket(placementId: 3, cropX: 0, cropY: 0),
        ]) else {
            Issue.record("expected crop batch preparation to succeed")
            return
        }
        #expect(prepared.count == 3)
        #expect(prepared.allSatisfy { $0.rgba.count == 16 })
        #expect(prepared[0].rgba != prepared[1].rgba)
        #expect(prepared[0].rgba == prepared[2].rgba)
        // Genuinely distinct crops keep their own allocations and charges;
        // the repeated identical crop aliases the first and charges zero.
        #expect(prepared[0].sourceChargeBytes == 16)
        #expect(prepared[1].sourceChargeBytes == 16)
        #expect(prepared[2].sourceChargeBytes == 0)
        #expect(hostedPreparedBatchUniqueSourceBytes(prepared) == 32)
    }
}
