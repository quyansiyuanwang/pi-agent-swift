import Foundation
import PiAI

// MARK: - Tool result

/// The final or partial result produced by a tool execution.
///
/// Mirrors upstream `AgentToolResult` (`packages/agent/src/types.ts`). The
/// agent turns this into a ``ToolResultMessage`` before appending it to the
/// transcript.
public struct ToolResult: Sendable, Equatable {
    /// Text or image content returned to the model.
    public var content: [ContentBlock]
    /// Arbitrary structured details for logs or UI rendering. Not sent to the model.
    public var details: JSONValue?
    /// Usage from the tool execution itself, if available.
    public var usage: Usage?
    /// Report a failure without throwing. The model sees `content` as an error result.
    public var isError: Bool

    public init(
        content: [ContentBlock] = [],
        details: JSONValue? = nil,
        usage: Usage? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.details = details
        self.usage = usage
        self.isError = isError
    }

    /// Convenience initializer for the common single-text-block result.
    public init(
        text: String,
        details: JSONValue? = nil,
        usage: Usage? = nil,
        isError: Bool = false
    ) {
        self.init(
            content: [.text(TextContent(text: text))],
            details: details,
            usage: usage,
            isError: isError
        )
    }
}

// MARK: - Tool protocol

/// A tool the agent can execute.
///
/// Mirrors the subset of upstream `AgentTool` described by `TASK.md`. Tools are
/// value-semantics friendly: declare them as `struct`s (or thread-safe
/// `final class`es) and store any mutable bookkeeping behind a lock or actor.
public protocol AgentTool: Sendable {
    /// Unique tool name used in the model's `tool_calls`.
    var name: String { get }
    /// Human-readable description shown to the model.
    var description: String { get }
    /// JSON Schema for the tool arguments, as a raw ``JSONValue``.
    var parametersJSONSchema: JSONValue { get }
    /// Execute one call.
    ///
    /// - Parameters:
    ///   - call: The model-issued tool call (id, name, parsed arguments).
    ///   - onUpdate: Optional callback for streaming partial results. Call it
    ///     zero or more times while executing; calls after `execute` returns are
    ///     ignored by the agent.
    /// - Returns: The tool result. Return ``ToolResult/isError`` instead of
    ///   throwing for expected failures; throw only for unexpected ones.
    func execute(
        _ call: ToolCall,
        onUpdate: ((ToolResult) -> Void)?
    ) async throws -> ToolResult
}

// MARK: - Events

/// Lifecycle events emitted by an ``Agent``.
///
/// The event set is the `TASK.md` contract, a simplified form of upstream
/// `AgentEvent`: turn-level events and the fine-grained per-block assistant
/// events are folded into ``messageUpdate(_:_:)`` / ``messageEnd(_:)``.
///
/// `agentEnd` is always the final event of a run; awaited subscribers finish
/// before `prompt(_:)` returns.
public enum AgentEvent: Sendable {
    /// The run started.
    case agentStart
    /// The run ended. `messages` are the messages produced during this run.
    case agentEnd(messages: [Message])
    /// A message was added to the transcript (user, assistant, or tool result).
    case messageStart(Message)
    /// An assistant message changed while streaming.
    case messageUpdate(Message, AssistantMessageEvent)
    /// An assistant or tool-result message finished.
    case messageEnd(Message)
    /// A tool call started.
    case toolExecutionStart(toolCallId: String, name: String, arguments: JSONValue)
    /// A tool produced a partial result.
    case toolExecutionUpdate(toolCallId: String, partial: ToolResult)
    /// A tool call finished. `isError` is `true` for failures and skips.
    case toolExecutionEnd(toolCallId: String, name: String, result: ToolResult, isError: Bool)
}

// MARK: - Options

/// Construction options for an ``Agent``.
///
/// Public API per `TASK.md`. `systemPrompt`, `model` and `tools` are retained
/// across ``Agent/reset()``; only the transcript is cleared.
public struct AgentOptions: Sendable {
    /// System prompt sent with every request.
    public var systemPrompt: String
    /// Model used for every request.
    public var model: Model
    /// Executable tools.
    public var tools: [any AgentTool]
    /// Streaming chat provider.
    public var provider: any ChatProvider
    /// API key forwarded to the provider in ``PiAI/ChatOptions``.
    ///
    /// Additive to the `TASK.md` field list: `OpenAICompletionsProvider` reads
    /// the key from the request options, so the agent must be able to pass one.
    public var apiKey: String
    /// Maximum number of tool-call rounds before the loop stops. Defaults to 8.
    public var maxToolRounds: Int
    /// Return `false` to skip a tool call. The skip is recorded as an error
    /// tool result so the transcript stays well formed.
    public var beforeToolCall: (@Sendable (ToolCall) async -> Bool)?
    /// Called after each tool execution with the finalized result.
    public var afterToolCall: (@Sendable (ToolCall, ToolResult) async -> Void)?

    public init(
        systemPrompt: String = "",
        model: Model,
        tools: [any AgentTool] = [],
        provider: any ChatProvider,
        apiKey: String = "",
        maxToolRounds: Int = 8,
        beforeToolCall: (@Sendable (ToolCall) async -> Bool)? = nil,
        afterToolCall: (@Sendable (ToolCall, ToolResult) async -> Void)? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.tools = tools
        self.provider = provider
        self.apiKey = apiKey
        self.maxToolRounds = maxToolRounds
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
    }
}

// MARK: - Errors

/// Errors thrown by ``Agent``.
public enum AgentError: Error, Sendable, Equatable {
    /// ``Agent/prompt(_:)`` was called while another run is in flight.
    case alreadyRunning
    /// The provider stream finished without yielding a final message.
    case streamEndedWithoutResult
}

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Agent is already processing. Wait for completion before prompting again."
        case .streamEndedWithoutResult:
            return "Provider stream ended without producing a final assistant message."
        }
    }
}

// MARK: - Clock

/// Millisecond timestamps matching the upstream `Date.now()` convention.
enum Clock {
    static func nowMillis() -> Int {
        Int((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
