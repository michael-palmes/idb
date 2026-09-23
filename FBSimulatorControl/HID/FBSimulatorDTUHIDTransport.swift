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
/// policy is unit-testable without a live `dtuhidd`; the transport never sleeps directly, it goes
/// through `DTUHIDDrainClock`.
struct DTUHIDTiming: Equatable, Sendable {
  /// Warm drain: how long a connection whose services are already open is kept up after a gesture.
  var drainNanos: UInt64 = 80_000_000
  /// Settle after the first post-send barrier reply, covering device dispatch.
  var replyTailNanos: UInt64 = 200_000_000
  /// Deadline for a drain barrier reply before taking `fallbackDrainNanos` instead.
  var replyTimeoutNanos: UInt64 = 2_000_000_000
  /// Wait taken when a drain barrier goes unanswered. Degrades, never fails.
  var fallbackDrainNanos: UInt64 = 1_000_000_000

  static let standard = DTUHIDTiming()
}

// MARK: - Injectable clock

/// Injectable waits for the DTUHID transport.
struct DTUHIDDrainClock: Sendable {
  let sleep: @Sendable (UInt64) async throws -> Void
  /// Sends a barrier and resolves on any reply (including an XPC error); throws
  /// `DTUHIDDrainTimeout.expired` at the deadline.
  let awaitBarrierReply: @Sendable (xpc_connection_t, xpc_object_t, UInt64) async throws -> Void

  static let live = DTUHIDDrainClock(
    sleep: { try await Task.sleep(nanoseconds: $0) },
    awaitBarrierReply: { connection, message, timeout in
      // Any reply ends the await: a dead connection is past protecting, and the tail is harmless.
      _ = try await awaitXPCReply(connection, message, timeoutNanos: timeout)
    })
}

/// A drain barrier deadline expired; `flush()` takes the fallback drain.
enum DTUHIDDrainTimeout: Error {
  case expired
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
/// `dtuhidd` `start` / `position` / `end` model: the first `.down` is a `start`, subsequent `.down`s
/// (a drag/swipe) are `position`s, and `.up` is the `end`.
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

/**
 The DTUHID transport (Xcode 27 / macOS 26 / iOS 26+).

 Drives the modern `dtuhidd` daemon: events cross the host→guest boundary as plain-XPC dictionaries
 delivered to the `com.apple.coredevice.feature.remote.hid.digitizer` service. Each message is built
 as an `Encodable` model (e.g. `IndigoDigitizerEvent`) wrapped in a `DTUHIDMessage` envelope and
 serialized with `XPCEncoder`, rather than hand-rolled `xpc_dictionary_set_*` calls. The host XPC
 connection is built from the simulator's Mach port via the private `_4sim` endpoint symbols
 (resolved with `dlsym`) and must be marked simulator-to-host with `xpc_connection_enable_sim2host_4sim`
 before messages reach the service handler.

 Capabilities are added one per commit; not-yet-implemented primitives throw
 `notImplementedOnDTUHIDTransport` rather than silently falling back to Indigo.

 An `actor`: the mutable contact state is actor-isolated, so the type needs no `@unchecked Sendable`.
 The XPC connection handle is thread-safe, so `disconnect()` cancels it from a `nonisolated` context.
 */
actor FBSimulatorDTUHIDTransport: FBSimulatorHIDTransport {

  static let digitizerServiceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  // Private XPC endpoint functions, resolved at runtime (not in the XPC module headers).
  private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
  private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
  private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

  /// The host→guest XPC connection to `dtuhidd`. XPC connections are thread-safe, so it is marked
  /// `nonisolated(unsafe)` to be read from the `nonisolated` `disconnect()` as well as the
  /// actor-isolated send path.
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

  /// Builds a DTUHID transport for the provided Simulator, establishing the host XPC connection to
  /// `dtuhidd`. Async so that connecting can wait on the daemon before the transport is handed out.
  static func dtuhid(for simulator: FBSimulator) async throws -> FBSimulatorDTUHIDTransport {
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

    return FBSimulatorDTUHIDTransport(
      connection: connection,
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale)
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
