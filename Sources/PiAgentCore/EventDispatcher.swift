import Foundation

/// A thread-safe, ordered event fan-out.
///
/// Listeners are invoked synchronously in registration order. Synchronous
/// invocation (rather than upstream's awaited `Promise` listeners) is the
/// `TASK.md` contract and gives the strongest ordering guarantee: by the time
/// ``emit(_:)`` returns, every listener has observed the event.
final class EventDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [(id: UUID, body: @Sendable (AgentEvent) -> Void)] = []

    /// Registers a listener and returns its token.
    func add(_ listener: @escaping @Sendable (AgentEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners.append((id, listener))
        lock.unlock()
        return id
    }

    /// Removes a previously registered listener.
    func remove(_ id: UUID) {
        lock.lock()
        listeners.removeAll { $0.id == id }
        lock.unlock()
    }

    /// Delivers `event` to every listener in registration order.
    func emit(_ event: AgentEvent) {
        lock.lock()
        let snapshot = listeners.map(\.body)
        lock.unlock()
        for listener in snapshot {
            listener(event)
        }
    }
}

/// A one-shot gate that stops forwarding tool updates once execution settles.
final class UpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    /// Forwards `body` only while the gate is open.
    func forward(_ body: () -> Void) {
        lock.lock()
        let isOpen = open
        lock.unlock()
        if isOpen { body() }
    }

    /// Closes the gate; later ``forward(_:)`` calls become no-ops.
    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}
