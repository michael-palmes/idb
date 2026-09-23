/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation

// MARK: - Transport selection

/// Which HID transport a caller that did not request one gets. Pure functions over injected facts.
///
/// Deliberately not a probe of whether `dtuhidd` is resident: it is demand-launched and exits when
/// idle, so it is often not running on a simulator that routes all HID through it. Whether it can
/// actually be reached is settled by `FBSimulatorDTUHIDTransport.dtuhid(for:)`'s liveness probe.
enum FBSimulatorHIDTransportSelection {
  static let firstDTUHIDCoreSimulatorVersion = "1155.4"

  static func shipsDTUHID(coreSimulatorVersion: String?) -> Bool {
    guard let coreSimulatorVersion else {
      return false
    }
    return coreSimulatorVersion.compare(firstDTUHIDCoreSimulatorVersion, options: .numeric) != .orderedAscending
  }

  /// From 1155.4 the guest hands the legacy keyboard service to `dtuhidd` for the whole boot.
  static func isLegacyHIDSuppressed(coreSimulatorVersion: String?) -> Bool {
    shipsDTUHID(coreSimulatorVersion: coreSimulatorVersion)
  }

  /// Apple TV stays on Indigo: the Siri Remote trackpad rides an Indigo service `dtuhidd` lacks.
  static func defaultTransport(coreSimulatorVersion: String?, isAppleTV: Bool) -> FBSimulatorHIDTransportType {
    shipsDTUHID(coreSimulatorVersion: coreSimulatorVersion) && !isAppleTV ? .dtuhid : .indigo
  }
}

extension FBSimulator {

  /// Whether this simulator's legacy HID keyboard service is handed to `dtuhidd` (Xcode 27,
  /// CoreSimulator-1155.4 and later), so legacy keyboard events produce no text.
  var isLegacyHIDSuppressed: Bool {
    FBSimulatorHIDTransportSelection.isLegacyHIDSuppressed(
      coreSimulatorVersion: FBSimulatorControlFrameworkLoader.loadedCoreSimulatorVersion)
  }

  /// The HID transport to use when a caller does not request one.
  var defaultHIDTransport: FBSimulatorHIDTransportType {
    FBSimulatorHIDTransportSelection.defaultTransport(
      coreSimulatorVersion: FBSimulatorControlFrameworkLoader.loadedCoreSimulatorVersion,
      isAppleTV: productFamily == .familyAppleTV)
  }
}

// MARK: - Loaded CoreSimulator version

private extension FBSimulatorControlFrameworkLoader {

  /// The version of the CoreSimulator framework actually loaded in-process (e.g. `"1155.4"`), read
  /// from the bundle that vends `SimDevice`, or `nil` if it is not loaded. CoreSimulator is a system
  /// framework that the Xcode installer overwrites, so the loaded framework can differ from the
  /// selected Xcode; behaviour gated on a CoreSimulator version must consult this, not the Xcode one.
  static var loadedCoreSimulatorVersion: String? {
    guard let simDeviceClass = NSClassFromString("SimDevice") else {
      return nil
    }
    return Bundle(for: simDeviceClass).infoDictionary?["CFBundleVersion"] as? String
  }
}
