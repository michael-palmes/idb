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

  func testFirstGestureAwaitsABarrierReplyThenTheTail() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await sendInertKey(on: hid)
    let barriers = await recorder.barriers, sleeps = await recorder.sleeps, timeouts = await recorder.barrierTimeouts
    XCTAssertEqual(barriers.count, 1)
    XCTAssertTrue(xpc_dictionary_get_bool(barriers[0], "isBarrier"))
    XCTAssertEqual(xpc_dictionary_get_uint64(xpc_dictionary_get_dictionary(barriers[0], "payload")!, "usageCode"), 0)
    XCTAssertEqual(timeouts, [timing.replyTimeoutNanos])
    XCTAssertEqual(sleeps, [timing.replyTailNanos])
  }

  func testLaterGesturesTakeTheWarmDrain() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await sendInertKey(on: hid); try await sendInertKey(on: hid)
    let sleeps = await recorder.sleeps, barriers = await recorder.barriers
    XCTAssertEqual(barriers.count, 1)
    XCTAssertEqual(sleeps, [timing.replyTailNanos, timing.drainNanos])
  }

  func testFlushWithoutASendIsANoOp() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await hid.flush()
    let sleeps = await recorder.sleeps, barriers = await recorder.barriers
    XCTAssertEqual(sleeps, []); XCTAssertEqual(barriers.count, 0)
  }

  func testRedundantFlushIsANoOp() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await sendInertKey(on: hid); try await hid.flush()
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, [timing.replyTailNanos])
  }

  func testUnansweredDrainBarrierFallsBackInsteadOfFailing() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder, barrier: .timeout)
    try await sendInertKey(on: hid)
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, [timing.fallbackDrainNanos])
  }

  func testConcurrentFirstGesturesShareOneBarrier() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.sendInertKey(on: hid) }
      group.addTask { try await self.sendInertKey(on: hid) }
      for try await _ in group {}
    }
    let barriers = await recorder.barriers
    XCTAssertEqual(barriers.count, 1)
  }

  func testDrainFailurePropagatesAndRetriesCold() async throws {
    let recorder = DrainRecorder(); await recorder.setFailNextSleep(); let hid = makeHID(recorder)
    do { try await sendInertKey(on: hid); XCTFail("expected failure") } catch is InjectedFailure {}
    try await sendInertKey(on: hid)
    let barriers = await recorder.barriers, sleeps = await recorder.sleeps
    XCTAssertEqual(barriers.count, 2); XCTAssertEqual(sleeps, [timing.replyTailNanos])
  }

  // MARK: Helpers

  private enum BarrierReply { case answer, timeout }
  private struct InjectedFailure: Error {}

  private func sendInertKey(on hid: FBSimulatorHID) async throws {
    // Mirrors send(event:logger:) without needing an FBControlCore logger in this target.
    try await hid.sendKeyboard(direction: .up, keyCode: 0)
    try await hid.flush()
  }

  private func makeHID(_ recorder: DrainRecorder, barrier: BarrierReply = .answer) -> FBSimulatorHID {
    FBSimulatorHID(transport: makeTransport(recorder, barrier: barrier), transportType: .dtuhid, simulator: nil)
  }

  private func makeTransport(_ recorder: DrainRecorder, barrier: BarrierReply = .answer) -> FBSimulatorDTUHIDTransport {
    let connection = xpc_connection_create("com.facebook.fbsimulatorcontrol.test.dtuhid", nil)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    let transport = FBSimulatorDTUHIDTransport(
      connection: connection, mainScreenSize: CGSize(width: 100, height: 200), mainScreenScale: 2.0,
      timing: timing,
      clock: recordingClock(recorder, barrier: barrier))
    addTeardownBlock { transport.disconnect() }
    return transport
  }

  private func recordingClock(_ recorder: DrainRecorder, barrier: BarrierReply = .answer) -> DTUHIDDrainClock {
    DTUHIDDrainClock(
      sleep: { try await recorder.sleep($0) },
      awaitBarrierReply: { _, message, timeout in
        await recorder.barrier(message, timeout)
        if barrier == .timeout { throw DTUHIDDrainTimeout.expired }
      })
  }

  private actor DrainRecorder {
    var sleeps: [UInt64] = []
    var barriers: [xpc_object_t] = []
    var barrierTimeouts: [UInt64] = []
    var failNextSleep = false

    func setFailNextSleep() { failNextSleep = true }

    func sleep(_ nanos: UInt64) throws {
      try Task.checkCancellation()
      if failNextSleep { failNextSleep = false; throw InjectedFailure() }
      sleeps.append(nanos)
    }

    func barrier(_ message: xpc_object_t, _ timeout: UInt64) { barriers.append(message); barrierTimeouts.append(timeout) }
  }
}
