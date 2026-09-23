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

  // MARK: Teardown
  func testCloseDrainsAnUndrainedSend() async throws {
    let recorder = DrainRecorder(); let transport = makeTransport(recorder)
    let hid = FBSimulatorHID(transport: transport, transportType: .dtuhid, simulator: nil)
    try await hid.sendKeyboard(direction: .up, keyCode: 0)      // no flush
    await hid.close()
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, [timing.replyTailNanos])
  }
  func testCloseSkipsTheDrainWhenNothingWasSent() async {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    await hid.close()
    let sleeps = await recorder.sleeps, barriers = await recorder.barriers
    XCTAssertEqual(sleeps, []); XCTAssertEqual(barriers.count, 0)
  }
  func testCloseDrainsEvenWhenTheCallerIsCancelled() async throws {
    let recorder = DrainRecorder(); let hid = makeHID(recorder)
    try await hid.sendKeyboard(direction: .up, keyCode: 0)
    let closing = Task { await hid.close() }
    closing.cancel()
    await closing.value
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, [timing.replyTailNanos])
  }

  // MARK: Liveness
  func testLivenessProbeIsAnInertBarrierWithTheLivenessDeadline() async throws {
    let recorder = DrainRecorder(); let transport = makeTransport(recorder)
    try await transport.confirmLiveness()
    let probes = await recorder.probes, timeouts = await recorder.probeTimeouts
    XCTAssertEqual(probes.count, 1)
    XCTAssertTrue(xpc_dictionary_get_bool(probes[0], "isBarrier"))
    XCTAssertEqual(xpc_dictionary_get_uint64(xpc_dictionary_get_dictionary(probes[0], "payload")!, "usageCode"), 0)
    XCTAssertEqual(timeouts, [timing.livenessTimeoutNanos])
  }
  func testLivenessWaitsOutTheActivationFloorFromTheProbe() async throws {
    let recorder = DrainRecorder()
    let transport = makeTransport(recorder, livenessLatency: 300_000_000)
    let latency = try await transport.confirmLiveness()
    let sleeps = await recorder.sleeps
    XCTAssertEqual(latency, 300_000_000)
    XCTAssertEqual(sleeps, [timing.activationFloorNanos - 300_000_000])
  }
  func testLivenessDoesNotSettleTheFirstGestureDrain() async throws {
    // Deliberate deviation from upstream 92cc718f (see confirmLiveness).
    let recorder = DrainRecorder(); let transport = makeTransport(recorder)
    try await transport.confirmLiveness()
    try await transport.sendKeyboard(direction: .up, keyCode: 0); try await transport.flush()
    let barriers = await recorder.barriers, sleeps = await recorder.sleeps
    XCTAssertEqual(barriers.count, 1)
    XCTAssertEqual(sleeps, [timing.activationFloorNanos, timing.replyTailNanos])
  }
  func testUnansweredProbeIsRetriedThenReportedUnresponsive() async {
    let recorder = DrainRecorder(); var attempts = 0
    do {
      _ = try await FBSimulatorDTUHIDTransport.connectConfirmingLiveness(
        timing: timing, clock: recordingClock(recorder), logger: nil
      ) {
        attempts += 1
        throw DTUHIDLivenessFailure.timedOut(nanos: self.timing.livenessTimeoutNanos)
      }
      XCTFail("expected dtuhidUnresponsive")
    } catch FBSimulatorHIDError.dtuhidUnresponsive(let count, let underlying) {
      XCTAssertEqual(count, timing.livenessAttempts); XCTAssertTrue(underlying is DTUHIDLivenessFailure)
    } catch { XCTFail("unexpected \(error)") }
    XCTAssertEqual(attempts, timing.livenessAttempts)
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, Array(repeating: timing.livenessRetryBackoffNanos, count: timing.livenessAttempts - 1))
  }
  func testAProbeThatRecoversOnALaterAttemptIsReturned() async throws {
    let recorder = DrainRecorder(); var attempts = 0
    let transport = makeTransport(recorder)
    let result = try await FBSimulatorDTUHIDTransport.connectConfirmingLiveness(
      timing: timing, clock: recordingClock(recorder), logger: nil
    ) {
      attempts += 1
      if attempts < 3 { throw DTUHIDLivenessFailure.peerUnavailable("Connection invalid") }
      return transport
    }
    XCTAssertTrue(result === transport)
    let sleeps = await recorder.sleeps
    XCTAssertEqual(sleeps, [timing.livenessRetryBackoffNanos, timing.livenessRetryBackoffNanos])
  }
  func testMissingXPCSymbolsAreNotRetried() async {
    let recorder = DrainRecorder(); var attempts = 0
    do {
      _ = try await FBSimulatorDTUHIDTransport.connectConfirmingLiveness(
        timing: timing, clock: recordingClock(recorder), logger: nil
      ) { attempts += 1; throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable }
      XCTFail("expected rethrow")
    } catch FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable {} catch { XCTFail("unexpected \(error)") }
    XCTAssertEqual(attempts, 1)
  }
  func testTransientClassification() {
    XCTAssertTrue(FBSimulatorHIDError.dtuhidDigitizerServiceUnavailable(underlying: nil).isTransientDTUHIDFailure)
    XCTAssertTrue(FBSimulatorHIDError.dtuhidConnectionFailed.isTransientDTUHIDFailure)
    XCTAssertTrue(FBSimulatorHIDError.dtuhidUnresponsive(attempts: 5, underlying: nil).isTransientDTUHIDFailure)
    XCTAssertFalse(FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable.isTransientDTUHIDFailure)
  }

  // MARK: Helpers
  private enum BarrierReply { case answer, timeout }
  private enum LivenessReply { case answer, unanswered }
  private struct InjectedFailure: Error {}

  private func sendInertKey(on hid: FBSimulatorHID) async throws {
    // Mirrors send(event:logger:) without needing an FBControlCore logger in this target.
    try await hid.sendKeyboard(direction: .up, keyCode: 0)
    try await hid.flush()
  }
  private func makeHID(_ recorder: DrainRecorder, barrier: BarrierReply = .answer) -> FBSimulatorHID {
    FBSimulatorHID(transport: makeTransport(recorder, barrier: barrier), transportType: .dtuhid, simulator: nil)
  }
  private func makeTransport(
    _ recorder: DrainRecorder, barrier: BarrierReply = .answer, liveness: LivenessReply = .answer,
    livenessLatency: UInt64 = 0
  ) -> FBSimulatorDTUHIDTransport {
    let connection = xpc_connection_create("com.facebook.fbsimulatorcontrol.test.dtuhid", nil)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    let transport = FBSimulatorDTUHIDTransport(
      connection: connection, mainScreenSize: CGSize(width: 100, height: 200), mainScreenScale: 2.0,
      timing: timing,
      clock: recordingClock(recorder, barrier: barrier, liveness: liveness, livenessLatency: livenessLatency))
    addTeardownBlock { transport.disconnect() }
    return transport
  }
  private func recordingClock(
    _ recorder: DrainRecorder, barrier: BarrierReply = .answer, liveness: LivenessReply = .answer,
    livenessLatency: UInt64 = 0
  ) -> DTUHIDDrainClock {
    let time = FakeTime()
    return DTUHIDDrainClock(
      now: { time.now() },
      sleep: { try await recorder.sleep($0) },
      awaitBarrierReply: { _, message, timeout in
        await recorder.barrier(message, timeout)
        if barrier == .timeout { throw DTUHIDDrainTimeout.expired }
      },
      awaitLivenessReply: { _, message, timeout in
        await recorder.probe(message, timeout)
        time.advance(livenessLatency)
        if liveness == .unanswered { throw DTUHIDLivenessFailure.timedOut(nanos: timeout) }
      })
  }
  private actor DrainRecorder {
    var sleeps: [UInt64] = []
    var barriers: [xpc_object_t] = []
    var barrierTimeouts: [UInt64] = []
    var probes: [xpc_object_t] = []
    var probeTimeouts: [UInt64] = []
    var failNextSleep = false
    func setFailNextSleep() { failNextSleep = true }
    func sleep(_ nanos: UInt64) throws {
      try Task.checkCancellation()
      if failNextSleep { failNextSleep = false; throw InjectedFailure() }
      sleeps.append(nanos)
    }
    func barrier(_ message: xpc_object_t, _ timeout: UInt64) { barriers.append(message); barrierTimeouts.append(timeout) }
    func probe(_ message: xpc_object_t, _ timeout: UInt64) { probes.append(message); probeTimeouts.append(timeout) }
  }
  private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock(); private var nanos: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return nanos }
    func advance(_ by: UInt64) { lock.lock(); nanos += by; lock.unlock() }
  }
}
