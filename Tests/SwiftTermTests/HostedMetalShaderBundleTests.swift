//
//  HostedMetalShaderBundleTests.swift
//
//  XCTest coverage for the SwiftPM sibling-bundle shader probe: under
//  `swift test`, Bundle.main is the toolchain runner shim while the resource
//  bundle sits beside the .xctest as `.../debug/SwiftTerm_SwiftTerm.bundle`.
//  Metal enablement must find the shaders there instead of throwing
//  `shaderSourceMissing`.

#if os(macOS)
import AppKit
import Metal
import XCTest
@testable import SwiftTerm

@MainActor
final class HostedMetalShaderBundleTests: XCTestCase {
    func testMetalEnablementFindsSiblingBundleShaders() throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "No Metal device in this environment.")
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        try view.setUseMetal(true)
        XCTAssertTrue(view.isUsingMetalRenderer)
        XCTAssertNotNil(view.metalView, "Metal enablement must install the MTKView child.")
    }
}
#endif
