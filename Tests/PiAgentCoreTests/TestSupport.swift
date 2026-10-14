import Foundation
import PiAI
import Testing

@testable import PiAgentCore

// MARK: - Shared fixtures

enum Fixtures {
    static let model = Model(
        id: "test-model",
        name: "Test Model",
        api: "openai-completions",
        provider: "test",
        baseURL: "https://example.test/v1",
        contextWindow: 128_000,
        maxTokens: 4_096
    )
}

func makeAssistant(
    text: String? = nil,
    toolCalls: [ToolCall] = [],
    stopReason: StopReason = .stop
) -> AssistantMessage {
    var content: [ContentBlock] = []
    if let text {
        content.append(.text(TextContent(text: text)))
    }
    content.append(contentsOf: toolCalls.map(ContentBlock.toolCall))
    return AssistantMessage(
        content: content,
        api: Fixtures.model.api,
        provider: Fixtures.model.provider,
        model: Fixtures.model.id,
        stopReason: stopReason,
        timestamp: 0
    )
}

func makeToolCall(id: String, name: String, arguments: JSONValue) -> ToolCall {
    ToolCall(id: id, name: name, arguments: arguments)
}

/// The first text block of an assistant message, if any.
func assistantText(_ message: Message?) -> String? {
    guard case .assistant(let assistant) = message else { return nil }
    for block in assistant.content {
        if case .text(let text) = block { return text.text }
    }
    return nil
}

// MARK: - Programmable provider

/// A `ChatProvider` that returns scripted steps in order.
final class MockProvider: ChatProvider, @unchecked Sendable {
    enum Step: Sendable {
        /// Emits `.start` then `.done(message)`.
        case message(AssistantMessage)
        /// Emits the given events verbatim.
        case events([AssistantMessageEvent])
        /// Finishes the stream by throwing.
        case failure(any Error & Sendable)
        /// Emits `.start` and stays open until cancelled.
        case hang
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recordedContexts: [ChatContext] = []
    private var recordedApiKeys: [String] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var contexts: [ChatContext] {
        lock.lock()
        defer { lock.unlock() }
        return recordedContexts
    }

    var apiKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedApiKeys
    }

    var callCount: Int { contexts.count }

    func stream(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        lock.lock()
        recordedContexts.append(context)
        recordedApiKeys.append(options.apiKey)
        let step = steps.isEmpty ? Step.message(AssistantMessage()) : steps.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            switch step {
            case .message(let message):
                continuation.yield(.start)
                continuation.yield(.done(message))
                continuation.finish()
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .hang:
                continuation.yield(.start)
                options.signal?.onCancel {
                    continuation.finish(throwing: CancellationError())
                }
                continuation.onTermination = { termination in
                    if case .cancelled = termination {
                        continuation.finish(throwing: CancellationError())
                    }
                }
            }
        }
    }
}

struct TestProviderError: Error, Sendable, Equatable {
    let message: String
}

// MARK: - Tool spies

/// Thread-safe bookkeeping for tool and hook assertions.
final class ToolSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _executions: [ToolCall] = []
    private var _afterCalls: [(ToolCall, ToolResult)] = []

    func recordExecution(_ call: ToolCall) {
        lock.lock()
        _executions.append(call)
        lock.unlock()
    }

    func recordAfter(_ call: ToolCall, _ result: ToolResult) {
        lock.lock()
        _afterCalls.append((call, result))
        lock.unlock()
    }

    var executions: [ToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return _executions
    }

    var afterCalls: [(ToolCall, ToolResult)] {
        lock.lock()
        defer { lock.unlock() }
        return _afterCalls
    }
}

/// A tool that adds two integer arguments and reports progress once.
struct AddTool: AgentTool {
    let spy: ToolSpy

    var name: String { "add" }
    var description: String { "Add two numbers" }
    var parametersJSONSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "a": .object(["type": .string("integer")]),
                "b": .object(["type": .string("integer")])
            ])
        ])
    }

    func execute(_ call: ToolCall, onUpdate: ((ToolResult) -> Void)?) async throws -> ToolResult {
        spy.recordExecution(call)
        onUpdate?(ToolResult(text: "adding"))
        let a = call.arguments["a"].intValue ?? 0
        let b = call.arguments["b"].intValue ?? 0
        return ToolResult(text: "\(a + b)", details: .object(["sum": .int(a + b)]))
    }
}

/// A tool that always throws.
struct FailingTool: AgentTool {
    var name: String { "boom" }
    var description: String { "Always fails" }
    var parametersJSONSchema: JSONValue { .object(["type": .string("object")]) }

    func execute(_ call: ToolCall, onUpdate: ((ToolResult) -> Void)?) async throws -> ToolResult {
        throw TestProviderError(message: "kaboom")
    }
}

// MARK: - Event log

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    var events: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    var labels: [String] { events.map(\.label) }
}

extension AgentEvent {
    var label: String {
        switch self {
        case .agentStart: return "agentStart"
        case .agentEnd: return "agentEnd"
        case .messageStart: return "messageStart"
        case .messageUpdate: return "messageUpdate"
        case .messageEnd: return "messageEnd"
        case .toolExecutionStart: return "toolExecutionStart"
        case .toolExecutionUpdate: return "toolExecutionUpdate"
        case .toolExecutionEnd: return "toolExecutionEnd"
        }
    }
}

// MARK: - Async polling

@discardableResult
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
