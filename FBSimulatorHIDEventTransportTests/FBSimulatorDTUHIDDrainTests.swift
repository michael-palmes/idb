/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import CoreGraphics
import XCTest
import XPC

final class FBSimulatorDTUHIDDrainTests: XCTestCase {
  private let timing = DTUHIDTiming.standard

  // MARK: Drain

  func testFirstGestureTakesOnlyTheWarmDrain() async throws {
    // BUG: dtuhidd holds events pending until its services open (560-770ms on Xcode 27.1) and discards them when the peer disconnects first; flipped in the following commits.
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await sendInertKey(on: hid)
    let sleeps = await recorder.sleeps, barriers = await recorder.barriers
    XCTAssertEqual(barriers.count, 0)
    XCTAssertEqual(sleeps, [timing.drainNanos])
  }

  func testFlushWithoutASendStillDrains() async throws {
    // BUG: dtuhidd holds events pending until its services open (560-770ms on Xcode 27.1) and discards them when the peer disconnects first; flipped in the following commits.
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await hid.flush()
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, [timing.drainNanos])
  }

  // MARK: Helpers

  private func sendInertKey(on hid: FBSimulatorHID) async throws {
    // Mirrors send(event:logger:) without needing an FBControlCore logger in this target.
    try await hid.sendKeyboard(direction: .up, keyCode: 0)
    try await hid.flush()
  }

  private func makeHID(_ recorder: DrainRecorder) -> FBSimulatorHID {
    FBSimulatorHID(transport: makeTransport(recorder), transportType: .dtuhid, simulator: nil)
  }

  private func makeTransport(_ recorder: DrainRecorder) -> FBSimulatorDTUHIDTransport {
    let connection = xpc_connection_create("com.facebook.fbsimulatorcontrol.test.dtuhid", nil)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    let transport = FBSimulatorDTUHIDTransport(
      connection: connection, mainScreenSize: CGSize(width: 100, height: 200), mainScreenScale: 2.0,
      timing: timing,
      clock: recordingClock(recorder))
    addTeardownBlock { transport.disconnect() }
    return transport
  }

  private func recordingClock(_ recorder: DrainRecorder) -> DTUHIDDrainClock {
    DTUHIDDrainClock(sleep: { try await recorder.sleep($0) })
  }

  private actor DrainRecorder {
    var sleeps: [UInt64] = []
    var barriers: [xpc_object_t] = []

    func sleep(_ nanos: UInt64) throws {
      try Task.checkCancellation()
      sleeps.append(nanos)
    }
  }
}
