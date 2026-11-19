import Foundation
@testable import FBSimulatorControl
import XCTest

final class FBSimulatorAccessibilityBootstrapPolicyTests: XCTestCase {
  func testRuntimeBeforeIOS27DoesNotRequireBootstrap() {
    let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)

    XCTAssertFalse(FBSimulatorAccessibilityCommands.requiresAccessibilityBootstrap(for: version))
  }

  func testIOS27RuntimeRequiresBootstrap() {
    let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)

    XCTAssertTrue(FBSimulatorAccessibilityCommands.requiresAccessibilityBootstrap(for: version))
  }

  func testFutureRuntimeRequiresBootstrap() {
    let version = OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)

    XCTAssertTrue(FBSimulatorAccessibilityCommands.requiresAccessibilityBootstrap(for: version))
  }

  func testHeldSimulatorSkipsBootstrapUntilCleared() {
    let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    let held = "00000000-0000-0000-0000-000000000001"
    let other = "00000000-0000-0000-0000-000000000002"
    defer { FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: held) }

    XCTAssertTrue(FBSimulatorAccessibilityCommands.bootstrapsBeforeRequest(runtimeVersion: version, udid: held))
    FBSimulatorControlFrameworkLoader.setAccessibilityHeld(true, forSimulatorUDID: held)
    XCTAssertFalse(FBSimulatorAccessibilityCommands.bootstrapsBeforeRequest(runtimeVersion: version, udid: held))
    XCTAssertTrue(FBSimulatorAccessibilityCommands.bootstrapsBeforeRequest(runtimeVersion: version, udid: other))
    FBSimulatorControlFrameworkLoader.setAccessibilityHeld(false, forSimulatorUDID: held)
    XCTAssertTrue(FBSimulatorAccessibilityCommands.bootstrapsBeforeRequest(runtimeVersion: version, udid: held))
  }

  func testHeldRuntimeBeforeIOS27StillNeedsNoBootstrap() {
    let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)

    XCTAssertFalse(FBSimulatorAccessibilityCommands.bootstrapsBeforeRequest(runtimeVersion: version, udid: "00000000-0000-0000-0000-000000000001"))
  }
}
