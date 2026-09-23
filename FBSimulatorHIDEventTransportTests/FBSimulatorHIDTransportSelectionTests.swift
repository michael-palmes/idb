/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import XCTest

final class FBSimulatorHIDTransportSelectionTests: XCTestCase {

  func testCoreSimulatorBeforeDTUHIDUsesIndigo() {
    XCTAssertEqual(FBSimulatorHIDTransportSelection.defaultTransport(coreSimulatorVersion: "1140.0", isAppleTV: false), .indigo)
  }

  func testCoreSimulatorWithDTUHIDUsesDTUHID() {
    XCTAssertEqual(FBSimulatorHIDTransportSelection.defaultTransport(coreSimulatorVersion: "1155.4", isAppleTV: false), .dtuhid)
    XCTAssertEqual(FBSimulatorHIDTransportSelection.defaultTransport(coreSimulatorVersion: "1169.1", isAppleTV: false), .dtuhid)
  }

  func testUnknownCoreSimulatorUsesIndigo() {
    XCTAssertEqual(FBSimulatorHIDTransportSelection.defaultTransport(coreSimulatorVersion: nil, isAppleTV: false), .indigo)
  }

  func testAppleTVStaysOnIndigo() {
    XCTAssertEqual(FBSimulatorHIDTransportSelection.defaultTransport(coreSimulatorVersion: "1169.1", isAppleTV: true), .indigo)
  }

  func testLegacySuppressionFollowsTheVersionNotDaemonResidency() {
    // Pure over the version: no process lookup, so the answer is the same whether or not dtuhidd is running.
    XCTAssertTrue(FBSimulatorHIDTransportSelection.isLegacyHIDSuppressed(coreSimulatorVersion: "1169.1"))
    XCTAssertFalse(FBSimulatorHIDTransportSelection.isLegacyHIDSuppressed(coreSimulatorVersion: "1140.0"))
  }
}
