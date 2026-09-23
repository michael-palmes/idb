/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@preconcurrency import CoreSimulator
import Darwin
@preconcurrency import FBControlCore
import Foundation
import XPC

// MARK: - Timing policy

/// The waits `FBSimulatorDTUHIDTransport` performs around the events it sends. A value type so the
/// policy is unit-testable without a live `dtuhidd`; the transport never sleeps or reads a clock
/// directly, it goes through `DTUHIDDrainClock`.
struct DTUHIDTiming: Equatable, Sendable {
  /// Warm drain: how long a connection whose services are already open is kept up after a gesture.
  var drainNanos: UInt64 = 80_000_000
  /// Settle after the first post-send barrier reply, covering device dispatch.
  var replyTailNanos: UInt64 = 200_000_000
  /// Deadline for a drain barrier reply before taking `fallbackDrainNanos` instead.
  var replyTimeoutNanos: UInt64 = 2_000_000_000
  /// Wait taken when a drain barrier goes unanswered. Degrades, never fails.
  var fallbackDrainNanos: UInt64 = 1_000_000_000
  /// Deadline for the connect-time liveness reply. Longer than `replyTimeoutNanos` because this is
  /// the send that demand-launches `dtuhidd`.
  var livenessTimeoutNanos: UInt64 = 4_000_000_000
  /// Wait between liveness attempts. `dtuhidd` declares a 10s minimum runtime, so launchd throttles
  /// the respawn of one that aborted early; retrying sooner re-reads the same throttled job.
  var livenessRetryBackoffNanos: UInt64 = 4_000_000_000
  /// Liveness attempts before the transport is reported unresponsive.
  var livenessAttempts: Int = 5
  /// Minimum time from the connection's first message (the liveness probe) before the transport is
  /// handed out. `dtuhidd` creates its virtual services on a peer's first message and opens them
  /// 560-770ms later on Xcode 27.1 (27A9269); events sent before then are held pending and discarded
  /// if the peer disconnects first, which is what a one-shot CLI does.
  var activationFloorNanos: UInt64 = 1_000_000_000

  static let standard = DTUHIDTiming()

  /// Overrides `activationFloorNanos` (milliseconds, capped at 5000) without rebuilding.
  static let activationOverrideEnvironmentKey = "FBSIMCONTROL_DTUHID_ACTIVATION_MS"

  static var live: DTUHIDTiming {
    var timing = standard
    if let raw = ProcessInfo.processInfo.environment[activationOverrideEnvironmentKey],
       let milliseconds = UInt64(raw) {
      timing.activationFloorNanos = min(milliseconds, 5_000) * 1_000_000
    }
    return timing
  }
}

// MARK: - Injectable clock

/// Injectable waits for the DTUHID transport. Every closure is required, so a call site cannot get a
/// liveness probe that silently always succeeds.
struct DTUHIDDrainClock: Sendable {
  /// Monotonic nanoseconds.
  let now: @Sendable () -> UInt64
  let sleep: @Sendable (UInt64) async throws -> Void
  /// Sends a barrier and resolves on any reply (including an XPC error); throws
  /// `DTUHIDDrainTimeout.expired` at the deadline.
  let awaitBarrierReply: @Sendable (xpc_connection_t, xpc_object_t, UInt64) async throws -> Void
  /// Sends a barrier and resolves only on a real peer reply; throws `DTUHIDLivenessFailure`.
  let awaitLivenessReply: @Sendable (xpc_connection_t, xpc_object_t, UInt64) async throws -> Void

  static let live = DTUHIDDrainClock(
    now: { DispatchTime.now().uptimeNanoseconds },
    sleep: { try await Task.sleep(nanoseconds: $0) },
    awaitBarrierReply: { connection, message, timeout in
      // Any reply ends the await: a dead connection is past protecting, and the tail is harmless.
      _ = try await awaitXPCReply(connection, message, timeoutNanos: timeout)
    },
    awaitLivenessReply: { connection, message, timeout in
      let reply: XPCReply
      do {
        reply = try await awaitXPCReply(connection, message, timeoutNanos: timeout)
      } catch {
        throw DTUHIDLivenessFailure.timedOut(nanos: timeout)
      }
      if let errorDescription = reply.errorDescription {
        throw DTUHIDLivenessFailure.peerUnavailable(errorDescription)
      }
    })
}

/// A drain barrier deadline expired; `flush()` takes the fallback drain.
enum DTUHIDDrainTimeout: Error {
  case expired
}

/// Nothing live was found behind a DTUHID connection at connect time.
enum DTUHIDLivenessFailure: Error, CustomStringConvertible {
  /// The probe went unanswered: `dtuhidd` is throttled, crash-looping, or wedged.
  case timedOut(nanos: UInt64)
  /// XPC answered on the peer's behalf, so no daemon took the message.
  case peerUnavailable(String)

  var description: String {
    switch self {
    case let .timedOut(nanos):
      return "no reply within \(nanos / 1_000_000) ms"
    case let .peerUnavailable(detail):
      return detail
    }
  }
}

/// What came back from a barrier, carried out of the XPC queue as plain values.
private struct XPCReply: Sendable {
  let errorDescription: String?
}

/// True for exactly one caller, which owns resuming the continuation.
private final class FirstAnswer: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = true

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let wasPending = pending
    pending = false
    return wasPending
  }
}

/// Sends `message` with a reply handler and resolves with whichever comes first, the reply or the
/// deadline. A late reply after the deadline (or the error reply on cancel) is ignored.
private func awaitXPCReply(
  _ connection: xpc_connection_t, _ message: xpc_object_t, timeoutNanos: UInt64
) async throws -> XPCReply {
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<XPCReply, Error>) in
    let answer = FirstAnswer()
    let queue = DispatchQueue.global(qos: .userInitiated)
    xpc_connection_send_message_with_reply(connection, message, queue) { reply in
      var errorDescription: String?
      if xpc_get_type(reply) == XPC_TYPE_ERROR {
        errorDescription =
          xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) }
          ?? "unknown XPC error"
      }
      if answer.claim() {
        continuation.resume(returning: XPCReply(errorDescription: errorDescription))
      }
    }
    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: timeoutNanos))) {
      if answer.claim() {
        continuation.resume(throwing: DTUHIDDrainTimeout.expired)
      }
    }
  }
}

// MARK: - Contact tracking

/// Tracks the per-contact phase so that a stream of Indigo `.down`/`.up` events maps onto the
/// `dtuhidd` `start` / `position` / `end` model.
struct DigitizerContactTracker {
  private var active = false

  mutating func eventType(for direction: FBSimulatorHIDDirection) -> DigitizerEventType {
    switch direction {
    case .down:
      if active {
        return .position
      }
      active = true
      return .start
    case .up:
      active = false
      return .end
    }
  }
}

// MARK: - Transport

/**
 The DTUHID transport (Xcode 27 / iOS 26+).

 Events cross the host to guest boundary as plain-XPC dictionaries (`DTUHIDMessage` envelopes
 serialized by `XPCEncoder`) delivered to `com.apple.coredevice.feature.remote.hid.digitizer` over a
 connection built from the simulator's Mach port with the private `_4sim` symbols.

 Readiness: `dtuhidd` creates its virtual services on a peer's first message and opens them later;
 events arriving before then are held pending and discarded if the peer disconnects. The factory
 therefore proves a live daemon with a barrier round trip (retried, since `dtuhidd` can abort during
 a slow boot) and waits out `activationFloorNanos`. The first drain after real sends round-trips
 another barrier so the gesture is known to be dequeued before the process can exit; later drains
 take the short warm drain; drains with nothing outstanding are skipped.
 */
actor FBSimulatorDTUHIDTransport: FBSimulatorHIDTransport {

  static let digitizerServiceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
  private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
  private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

  /// XPC connections support concurrent sending and cancellation.
  nonisolated(unsafe) private let connection: xpc_connection_t
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  private let timing: DTUHIDTiming
  private let clock: DTUHIDDrainClock
  private var contact = DigitizerContactTracker()
  private var twoFingerContact = DigitizerContactTracker()
  private var coldDrainState = ColdDrainState.pending
  // A drain claims a snapshot of the send count; later sends remain outstanding.
  private var sendGeneration = 0
  private var drainedGeneration = 0

  // MARK: Initializers

  /// Connects to the simulator's DTUHID service and returns only once a live `dtuhidd` has answered
  /// a liveness probe and the activation floor has passed. Throws `dtuhidUnresponsive` if no attempt
  /// is answered, rather than handing out a transport whose every event would be discarded.
  static func dtuhid(
    for simulator: FBSimulator,
    timing: DTUHIDTiming = .live,
    clock: DTUHIDDrainClock = .live
  ) async throws -> FBSimulatorDTUHIDTransport {
    let logger = FBControlCoreGlobalConfiguration.defaultLogger
    return try await connectConfirmingLiveness(timing: timing, clock: clock, logger: logger) {
      try await connected(to: simulator, timing: timing, clock: clock, logger: logger)
    }
  }

  /// The retry policy, separated from connection building so it is testable without a simulator.
  static func connectConfirmingLiveness(
    timing: DTUHIDTiming,
    clock: DTUHIDDrainClock,
    logger: (any FBControlCoreLogger)?,
    attempt: () async throws -> FBSimulatorDTUHIDTransport
  ) async throws -> FBSimulatorDTUHIDTransport {
    let attempts = max(1, timing.livenessAttempts)
    var lastFailure: Error?
    for index in 1...attempts {
      do {
        return try await attempt()
      } catch let error as FBSimulatorHIDError where !error.isTransientDTUHIDFailure {
        // A toolchain without the `_4sim` symbols will not grow them by being asked again.
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastFailure = error
        logger?.log("dtuhidd did not answer the liveness probe (attempt \(index) of \(attempts)): \(error)")
        guard index < attempts else {
          break
        }
        try await clock.sleep(timing.livenessRetryBackoffNanos)
      }
    }
    throw FBSimulatorHIDError.dtuhidUnresponsive(attempts: attempts, underlying: lastFailure)
  }

  /// One attempt. The service lookup lives inside the attempt: it fails while launchd is
  /// respawning the job, which is exactly the state being retried out of.
  private static func connected(
    to simulator: FBSimulator,
    timing: DTUHIDTiming,
    clock: DTUHIDDrainClock,
    logger: (any FBControlCoreLogger)?
  ) async throws -> FBSimulatorDTUHIDTransport {
    let transport = FBSimulatorDTUHIDTransport(
      connection: try connection(for: simulator),
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale,
      timing: timing,
      clock: clock)
    do {
      let latency = try await transport.confirmLiveness()
      logger?.log("dtuhidd answered the liveness probe in \(latency / 1_000_000) ms")
    } catch {
      transport.disconnect()
      throw error
    }
    return transport
  }

  /// A resumed host XPC connection to the guest digitizer service. Says nothing about whether
  /// `dtuhidd` can run: launchd vends the port for a demand-launched job either way.
  private static func connection(for simulator: FBSimulator) throws -> xpc_connection_t {
    guard let handle = dlopen(nil, RTLD_NOW) else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }
    guard
      let endpointFromPort = symbol(handle, "xpc_endpoint_create_mach_port_4sim", as: EndpointFromMachPortFn.self),
      let connectionFromEndpoint = symbol(handle, "xpc_connection_create_from_endpoint", as: ConnectionFromEndpointFn.self),
      let enableSim2Host = symbol(handle, "xpc_connection_enable_sim2host_4sim", as: EnableSim2HostFn.self)
    else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }

    var lookupError: NSError?
    let servicePort = simulator.device.lookup(digitizerServiceName, error: &lookupError)
    if servicePort == 0 {
      throw FBSimulatorHIDError.dtuhidDigitizerServiceUnavailable(underlying: lookupError)
    }
    guard
      let endpoint = endpointFromPort(servicePort, 0, 0),
      let connection = connectionFromEndpoint(endpoint)
    else {
      throw FBSimulatorHIDError.dtuhidConnectionFailed
    }
    // The load-bearing step: without this the daemon observes the peer but never the payload.
    enableSim2Host(connection)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    return connection
  }

  init(
    connection: xpc_connection_t,
    mainScreenSize: CGSize,
    mainScreenScale: Float,
    timing: DTUHIDTiming = .standard,
    clock: DTUHIDDrainClock = .live
  ) {
    self.connection = connection
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.timing = timing
    self.clock = clock
  }

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(handle, name) else {
      return nil
    }
    return unsafeBitCast(sym, to: type)
  }

  // MARK: Liveness

  /// Round-trips an inert barrier to prove a `dtuhidd` is behind the connection, then waits until
  /// `activationFloorNanos` after the probe was sent so the services it created are open before the
  /// caller's first event. Returns the reply latency (for diagnostics and tuning).
  ///
  /// Deliberately does not settle the cold drain (upstream 92cc718f does): on Xcode 27.1 the reply
  /// can precede device-open, so the first real gesture still round-trips its own barrier.
  @discardableResult
  func confirmLiveness() async throws -> UInt64 {
    let probeSentAt = clock.now()
    try await clock.awaitLivenessReply(connection, barrierMessage(), timing.livenessTimeoutNanos)
    let answeredAt = clock.now()
    let latency = answeredAt >= probeSentAt ? answeredAt - probeSentAt : 0
    if timing.activationFloorNanos > latency {
      try await clock.sleep(timing.activationFloorNanos - latency)
    }
    return latency
  }

  // MARK: FBSimulatorHIDTransport

  nonisolated func disconnect() {
    xpc_connection_cancel(connection)
  }

  func sendTouch(direction: FBSimulatorHIDDirection, x: Double, y: Double) async throws {
    let ratio = FBSimulatorIndigoHID.screenRatio(
      from: CGPoint(x: x, y: y), screenSize: mainScreenSize, screenScale: mainScreenScale)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y)),
      eventType: contact.eventType(for: direction))
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendTwoFingerTouch(direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws {
    let r1 = FBSimulatorIndigoHID.screenRatio(from: finger1, screenSize: mainScreenSize, screenScale: mainScreenScale)
    let r2 = FBSimulatorIndigoHID.screenRatio(from: finger2, screenSize: mainScreenSize, screenScale: mainScreenScale)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(r1.x), y: Double(r1.y)),
      pointTwo: DigitizerPoint(x: Double(r2.x), y: Double(r2.y)),
      eventType: twoFingerContact.eventType(for: direction))
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {
    guard let usage = button.dtuhidUsage else {
      throw FBSimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "sendButton(.applePay) — Apple Pay is a double side-button press, not a single HID usage; send two .sideButton presses instead")
    }
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: UInt64(keyCode), state: state))
  }

  // MARK: Sending

  /// Wraps `payload` in a `DTUHIDMessage` envelope. Pure, so the shape is unit-testable.
  nonisolated func encode(messageType: String, payload: some Encodable, isBarrier: Bool = false) throws -> xpc_object_t {
    let message = DTUHIDMessage(
      messageType: messageType,
      featureIdentifier: Self.digitizerServiceName,
      isBarrier: isBarrier,
      payload: payload)
    return try XPCEncoder().encode(message)
  }

  /// Encodes and writes one event; resolves when the local XPC send barrier fires. Nothing suspends
  /// between a contact tracker assigning an event type and the write.
  func send(messageType: String, payload: some Encodable) async throws {
    try await deliver(encode(messageType: messageType, payload: payload))
  }

  private func deliver(_ object: xpc_object_t) async throws {
    // Make the send visible to flush before the first suspension.
    sendGeneration += 1
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      xpc_connection_send_message(connection, object)
      xpc_connection_send_barrier(connection) {
        continuation.resume()
      }
    }
  }

  /// Allows events sent before this call to reach the guest before disconnecting. The first drain
  /// with outstanding sends waits for a barrier reply plus `replyTailNanos` (or `fallbackDrainNanos`
  /// if unanswered within `replyTimeoutNanos`); later drains wait `drainNanos`. Returns immediately
  /// when nothing is outstanding.
  func flush() async throws {
    let generation = sendGeneration
    guard generation > drainedGeneration else {
      return
    }
    if case .done = coldDrainState {
      try await clock.sleep(timing.drainNanos)
    } else {
      let coldGeneration = try await coldDrain()
      if generation > coldGeneration {
        try await clock.sleep(timing.drainNanos)
      }
    }
    drainedGeneration = max(drainedGeneration, generation)
  }

  private enum ColdDrainState {
    case pending
    case running(Task<Int, Error>)
    case done
  }

  /// Concurrent first flushes share one task; returns the last send it covers. A failed drain
  /// resets to `.pending` so the next flush retries cold.
  private func coldDrain() async throws -> Int {
    if case let .running(task) = coldDrainState {
      return try await task.value
    }
    let generation = sendGeneration
    let task = Task<Int, Error> {
      do {
        try await self.performColdDrain()
      } catch {
        self.coldDrainState = .pending
        throw error
      }
      self.coldDrainState = .done
      return generation
    }
    coldDrainState = .running(task)
    return try await task.value
  }

  private func performColdDrain() async throws {
    do {
      try await clock.awaitBarrierReply(connection, barrierMessage(), timing.replyTimeoutNanos)
    } catch is DTUHIDDrainTimeout {
      try await clock.sleep(timing.fallbackDrainNanos)
      return
    }
    try await clock.sleep(timing.replyTailNanos)
  }

  /// A barrier carrying keyboard usage `0` ("no event indicated"), so the daemon answers without
  /// the guest seeing a keypress.
  private nonisolated func barrierMessage() throws -> xpc_object_t {
    try encode(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: 0, state: .up),
      isBarrier: true)
  }
}

// MARK: - Button usage mapping

extension FBSimulatorHIDButton {

  /// The HID usage (page, code) that drives this hardware button via `dtuhidd`'s `mainScreenButtons`
  /// service. All live-confirmed against a booted Xcode 27 / iOS 26 simulator (Consumer page 0x0C).
  /// Apple Pay has no single usage — it is a double-press of the side button — so it is nil.
  var dtuhidUsage: (page: UInt16, code: UInt16)? {
    switch self {
    case .homeButton:
      return (0x0C, 0x40) // Consumer: Menu
    case .lock:
      return (0x0C, 0x30) // Consumer: Power
    case .sideButton:
      return (0x0C, 0x30) // the side button is the power/lock button
    case .siri:
      return (0x0C, 0xCF) // Consumer: Voice Command
    case .applePay:
      return nil // double-press of the side button; not a single HID usage
    }
  }
}
