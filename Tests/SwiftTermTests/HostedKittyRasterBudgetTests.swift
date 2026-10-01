//
//  HostedKittyRasterBudgetTests.swift
//
//  XCTest coverage for the raster-budget separation: the 8 MiB wire budget
//  (`maxPayloadBytes`) constrains encoded/inflated/raw source bytes only,
//  while `maxDecodedRasterBytes` (32 MiB) admits legitimately large decoded
//  rasters and `maxRenderedBytes` (8 MiB) bounds one placement's canvas.
//  The 64 MiB aggregate batch bound is unchanged.

import Foundation
import XCTest
@testable import SwiftTerm
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

final class HostedKittyRasterBudgetTests: XCTestCase {
    // MARK: - Defaults

    func testDefaultBudgetsSeparateWireFromRasterCanvasAndAggregate() {
        let limits = HostedKittyGraphicsLimits()
        XCTAssertEqual(limits.maxPayloadBytes, 8 * 1024 * 1024, "Wire/inflated/raw source budget stays 8 MiB.")
        XCTAssertEqual(limits.maxDecodedRasterBytes, 32 * 1024 * 1024, "Decoded raster admits 4K frames and <=2000-dimension screenshots.")
        XCTAssertEqual(limits.maxRenderedBytes, 8 * 1024 * 1024, "One placement canvas stays 8 MiB.")
        XCTAssertEqual(limits.maxPreparedBatchBytes, 64 * 1024 * 1024, "Aggregate batch bound is unchanged.")
    }

    // MARK: - Raw formats respect the raster bound (portable, no ImageIO)

    private func rawTicket(format: Int, width: Int, height: Int, payload: Data) -> HostedKittyRenderRequest {
        HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 11, imageNumber: nil,
                                 placementId: 3, columns: 2, rows: 1, zIndex: 0,
                                 pixelOffsetX: 0, pixelOffsetY: 0, format: format,
                                 rawWidth: width, rawHeight: height, compression: nil,
                                 base64Payload: Array(payload.base64EncodedString().utf8),
                                 isAlternateBuffer: false)
    }

    func testRGBExpansionRespectsDecodedRasterBound() {
        // 100x100 RGB (30,000 wire bytes) expands to 40,000 RGBA bytes.
        let ticket = rawTicket(format: 24, width: 100, height: 100, payload: Data(count: 30_000))
        let tight = HostedKittyGraphicsLimits(maxDecodedRasterBytes: 35_000)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            XCTFail("expected decoded-raster rejection")
            return
        }
        XCTAssertEqual(error, .exceedsDecodedRasterLimit(bytes: 40_000, limit: 35_000))
        // Separation: the same wire budget admits once the raster fits.
        guard case .success(let admitted) = prepareHostedKittyRender(ticket, limits: HostedKittyGraphicsLimits(maxPayloadBytes: 35_000)) else {
            XCTFail("expected wire-budget admission under the default raster bound")
            return
        }
        XCTAssertEqual(admitted.rgba.count, 40_000)
    }

    func testRaw32RespectsDecodedRasterBound() {
        // 100x100 RGBA is 40,000 bytes on the wire and as a raster.
        let ticket = rawTicket(format: 32, width: 100, height: 100, payload: Data(count: 40_000))
        let tight = HostedKittyGraphicsLimits(maxDecodedRasterBytes: 35_000)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            XCTFail("expected decoded-raster rejection")
            return
        }
        XCTAssertEqual(error, .exceedsDecodedRasterLimit(bytes: 40_000, limit: 35_000))
        guard case .success(let admitted) = prepareHostedKittyRender(ticket) else {
            XCTFail("expected successful control under default limits")
            return
        }
        XCTAssertEqual(admitted.rgba.count, 40_000)
    }

    func testOversizedWirePayloadStillRejectsWithPayloadLimit() {
        // 1500x1500 RGBA is 9,000,000 wire bytes: over the unchanged 8 MiB
        // wire budget, rejected before any raster work.
        let ticket = rawTicket(format: 32, width: 1500, height: 1500, payload: Data(count: 9_000_000))
        guard case .failure(let error) = prepareHostedKittyRender(ticket) else {
            XCTFail("expected wire-budget rejection")
            return
        }
        XCTAssertEqual(error, .exceedsPayloadLimit(bytes: 9_000_000, limit: 8 * 1024 * 1024))
    }

    // MARK: - Canvas and aggregate bounds unchanged (portable)

    func testRenderedCanvasBoundUsesRenderedBytes() {
        // 2x2 source is 16 bytes, but 3x2 cells at 8x16px render 3072 bytes.
        let ticket = HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 21, imageNumber: nil,
                                              placementId: 5, columns: 3, rows: 2, zIndex: 0,
                                              pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                              rawWidth: 2, rawHeight: 2, compression: nil,
                                              base64Payload: Array(Data(count: 16).base64EncodedString().utf8),
                                              isAlternateBuffer: false,
                                              cellWidthPx: 8, cellHeightPx: 16)
        let tight = HostedKittyGraphicsLimits(maxRenderedBytes: 100)
        guard case .failure(let error) = prepareHostedKittyRender(ticket, limits: tight) else {
            XCTFail("expected rendered-limit rejection")
            return
        }
        guard case .exceedsRenderedLimit = error else {
            XCTFail("expected exceedsRenderedLimit, got \(error)")
            return
        }
        guard case .success(let admitted) = prepareHostedKittyRender(ticket) else {
            XCTFail("expected successful control under default limits")
            return
        }
        XCTAssertEqual(admitted.renderedByteCost, 24 * 32 * 4)
        XCTAssertEqual(admitted.stripes.count, 2)
    }

    func testAggregateBatchBoundStillEnforced() {
        func ticket(imageId: UInt32) -> HostedKittyRenderRequest {
            HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: imageId, imageNumber: nil,
                                     placementId: 1, columns: 2, rows: 2, zIndex: 0,
                                     pixelOffsetX: 0, pixelOffsetY: 0, format: 32,
                                     rawWidth: 2, rawHeight: 2, compression: nil,
                                     base64Payload: Array(Data(count: 16).base64EncodedString().utf8),
                                     isAlternateBuffer: false,
                                     cellWidthPx: 8, cellHeightPx: 16)
        }
        // Each ticket charges 16 source + 2048 rendered = 2064 bytes:
        // 2x2 cells at 8x16px scale the 2x2 source to a 16x32 canvas
        // (512px * 4B), and distinct image ids never share source charges.
        // One ticket fits a 3000-byte batch; the pair (4128) exceeds it.
        let tiny = HostedKittyGraphicsLimits(maxPreparedBatchBytes: 3000)
        guard case .success(let single) = prepareHostedKittyBatch([ticket(imageId: 31)], limits: tiny) else {
            XCTFail("expected single-ticket admission inside the tiny batch")
            return
        }
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(hostedPreparedBatchChargedBytes(single), 2064)
        guard case .failure(let error) = prepareHostedKittyBatch([ticket(imageId: 31), ticket(imageId: 32)], limits: tiny) else {
            XCTFail("expected aggregate rejection")
            return
        }
        guard case .exceedsBatchLimit = error else {
            XCTFail("expected exceedsBatchLimit, got \(error)")
            return
        }
        guard case .success(let admitted) = prepareHostedKittyBatch([ticket(imageId: 31), ticket(imageId: 32)]) else {
            XCTFail("expected successful control under default limits")
            return
        }
        XCTAssertEqual(admitted.count, 2)
    }

#if canImport(CoreGraphics) && canImport(ImageIO)
    // MARK: - Screenshot-scale PNG (needs ImageIO)

    /// Deterministic opaque 2000x1476 PNG: solid fill plus fixed bars, so
    /// the compressed wire stays far under 8 MiB while decoded RGBA is
    /// 11,808,000 bytes. Mirrors Pi's <=2000-dimension resized video frame.
    private func screenshotScalePNG() -> Data? {
        let width = 2000
        let height = 1476
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.10, green: 0.23, blue: 0.61, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        context.fill(CGRect(x: 0, y: height - 8, width: width, height: 8))
        context.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1.0))
        context.fill(CGRect(x: 0, y: height / 2 - 4, width: width, height: 8))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func screenshotTicket(base64: String) -> HostedKittyRenderRequest {
        HostedKittyRenderRequest(epoch: 0, originLinesTop: 0, imageId: 424242, imageNumber: nil,
                                 placementId: 7, columns: 60, rows: 22, zIndex: 0,
                                 pixelOffsetX: 0, pixelOffsetY: 0, format: 100,
                                 rawWidth: 0, rawHeight: 0, compression: nil,
                                 base64Payload: Array(base64.utf8),
                                 isAlternateBuffer: false,
                                 cellWidthPx: 8, cellHeightPx: 16)
    }

    func testScreenshotScalePNGSucceedsWithSmallWire() throws {
        let png = try XCTUnwrap(screenshotScalePNG(), "synthesized screenshot PNG must encode")
        let base64 = png.base64EncodedString()
        let rgbaCost = 2000 * 1476 * 4
        XCTAssertGreaterThan(rgbaCost, 8 * 1024 * 1024, "Premise: decoded RGBA exceeds the wire budget.")
        XCTAssertLessThan(png.count, 8 * 1024 * 1024, "Premise: the compressed wire fits the wire budget.")
        // 60x22 cells at 8x16px render a 480x352 canvas: 675,840 bytes,
        // inside the rendered budget; source plus canvas stays inside the
        // unchanged 64 MiB aggregate.
        guard case .success(let image) = prepareHostedKittyRender(screenshotTicket(base64: base64)) else {
            XCTFail("expected screenshot-scale admission under separated budgets")
            return
        }
        XCTAssertEqual(image.width, 2000)
        XCTAssertEqual(image.height, 1476)
        XCTAssertEqual(image.rgba.count, rgbaCost)
        XCTAssertEqual(image.scaledWidth, 480)
        XCTAssertEqual(image.scaledHeight, 352)
        XCTAssertEqual(image.renderedByteCost, 480 * 352 * 4)
        XCTAssertEqual(image.stripes.count, 22)
        guard case .success(let batch) = prepareHostedKittyBatch([screenshotTicket(base64: base64)]) else {
            XCTFail("expected screenshot-scale batch admission")
            return
        }
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(hostedPreparedBatchChargedBytes(batch), rgbaCost + 480 * 352 * 4)
    }

    func testTightDecodedRasterLimitRejectsPNGBeforeDecode() throws {
        let png = try XCTUnwrap(screenshotScalePNG(), "synthesized screenshot PNG must encode")
        let tight = HostedKittyGraphicsLimits(maxDecodedRasterBytes: 1_000_000)
        guard case .failure(let error) = prepareHostedKittyRender(screenshotTicket(base64: png.base64EncodedString()), limits: tight) else {
            XCTFail("expected header-gated decoded-raster rejection")
            return
        }
        XCTAssertEqual(error, .exceedsDecodedRasterLimit(bytes: 2000 * 1476 * 4, limit: 1_000_000))
    }
#endif
}
