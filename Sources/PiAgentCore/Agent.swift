import Foundation
import PiAI

/// A stateful, `Sendable` agent that owns a transcript and drives the tool loop.
///
/// Mirrors upstream `Agent` (`packages/agent/src/agent.ts`) reduced to the
/// `TASK.md` public contract: `prompt`, `abort`, `reset`, `subscribe` and
/// `isStreaming`. Steering / follow-up queues, turn events and pluggable
/// context transforms are out of scope for M1–M5.
///
/// The actor owns the transcript. `prompt(_:)` runs on the caller's task, so
/// `Task.cancel()` on that task (or ``abort()``) interrupts both the provider
/// stream and tool execution.
public actor Agent {
    private let dispatcher: EventDispatcher
    private let options: AgentOptions

    private var messages: [Message] = []
    private var streaming = false
    private var cancellation: CancellationSignal?

    public init(options: AgentOptions) {
        self.options = options
        self.dispatcher = EventDispatcher()
    }

    // MARK: - State

    /// Whether a prompt/continuation is currently running.
    public var isStreaming: Bool { streaming }

    /// A snapshot of the current transcript.
    public var transcript: [Message] { messages }

    // MARK: - Subscription

    /// Subscribes to lifecycle events.
    ///
    /// Listeners are invoked synchronously in registration order while the run
    /// executes. `agentEnd` is the last event delivered for a run.
    ///
    /// - Returns: A closure that removes the listener. It is safe to call more
    ///   than once.
    public nonisolated func subscribe(_ listener: @escaping @Sendable (AgentEvent) -> Void) -> () -> Void {
        let id = dispatcher.add(listener)
        return { [dispatcher] in dispatcher.remove(id) }
    }

    // MARK: - Control

    /// Runs one prompt to completion, executing tools as needed.
    ///
    /// - Throws: `CancellationError` when ``abort()`` or `Task.cancel()` stops
    ///   the run; any provider error otherwise. `agentEnd` is still emitted
    ///   before the error propagates.
    public func prompt(_ text: String) async throws {
        guard !streaming else { throw AgentError.alreadyRunning }

        let startIndex = messages.count
        let userMessage = Message.user(UserMessage(content: text, timestamp: Clock.nowMillis()))
        messages.append(userMessage)

        streaming = true
        let signal = CancellationSignal()
        cancellation = signal
        defer {
            streaming = false
            cancellation = nil
        }

        emit(.agentStart)
        emit(.messageStart(userMessage))
        emit(.messageEnd(userMessage))

        do {
            try await withTaskCancellationHandler {
                try await runLoop(signal: signal)
            } onCancel: {
                signal.cancel()
            }
        } catch {
            emit(.agentEnd(messages: Array(messages[startIndex...])))
            throw error
        }

        emit(.agentEnd(messages: Array(messages[startIndex...])))
    }

    /// Cancels the in-flight run, if any. The interrupted ``prompt(_:)`` throws
    /// `CancellationError`.
    public func abort() {
        cancellation?.cancel()
    }

    /// Clears the transcript while retaining `systemPrompt`, `tools` and `model`.
    ///
    /// Does nothing while a run is in flight (upstream throws instead); the
    /// no-throw signature is fixed by `TASK.md`.
    public func reset() {
        guard !streaming else { return }
        messages.removeAll()
    }

    /// Replaces the transcript with `messages`.
    ///
    /// Used to restore a previously saved conversation. Does nothing while a
    /// run is in flight.
    public func setTranscript(_ messages: [Message]) {
        guard !streaming else { return }
        self.messages = messages
    }

    // MARK: - Event emission

    private nonisolated func emit(_ event: AgentEvent) {
        dispatcher.emit(event)
    }

    // MARK: - Loop

    /// Drives assistant requests and tool batches until the model stops calling
    /// tools or `maxToolRounds` is reached.
    private func runLoop(signal: CancellationSignal) async throws {
        var rounds = 0
        while true {
            try Task.checkCancellation()
            if signal.isCancelled { throw CancellationError() }

            let assistant = try await streamAssistant(signal: signal)
            let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                if case .toolCall(let call) = block { return call }
                return nil
            }

            if toolCalls.isEmpty { break }
            // `maxToolRounds == 0` means "never execute tools".
            if rounds >= options.maxToolRounds { break }

            for call in toolCalls {
                try Task.checkCancellation()
                if signal.isCancelled { throw CancellationError() }
                try await executeToolCall(call, signal: signal)
            }

            rounds += 1
            if rounds >= options.maxToolRounds { break }
        }
    }

    /// Streams one assistant response, emitting message lifecycle events and
    /// appending the finalized message to the transcript.
    private func streamAssistant(signal: CancellationSignal) async throws -> AssistantMessage {
        var accumulator = AssistantMessageAccumulator(model: options.model)
        var started = false
        var final: AssistantMessage?

        func ensureStarted(_ message: AssistantMessage) {
            if !started {
                started = true
                emit(.messageStart(.assistant(message)))
            }
        }

        let stream = options.provider.stream(
            model: options.model,
            context: makeContext(),
            options: ChatOptions(apiKey: options.apiKey, signal: signal)
        )

        var failure: Error?
        do {
            for try await event in stream {
                try Task.checkCancellation()
                if signal.isCancelled { throw CancellationError() }

                switch event {
                case .start:
                    ensureStarted(accumulator.message)
                case .textDelta, .thinkingDelta, .toolCallDelta:
                    accumulator.apply(event)
                    ensureStarted(accumulator.message)
                    emit(.messageUpdate(.assistant(accumulator.message), event))
                case .done(let message):
                    accumulator.apply(event)
                    ensureStarted(message)
                    emit(.messageEnd(.assistant(message)))
                    final = message
                case .error(let error):
                    if error is CancellationError || signal.isCancelled || Task.isCancelled {
                        throw CancellationError()
                    }
                    throw error
                }
            }
        } catch {
            failure = error
        }

        if let failure {
            let cancelled = failure is CancellationError
            let message = failureMessage(
                stopReason: cancelled ? .aborted : .error,
                errorMessage: cancelled ? "Operation cancelled" : String(describing: failure)
            )
            ensureStarted(message)
            emit(.messageEnd(.assistant(message)))
            messages.append(.assistant(message))
            throw failure
        }

        guard let final else {
            let message = failureMessage(stopReason: .error, errorMessage: "Stream ended without a result")
            ensureStarted(message)
            emit(.messageEnd(.assistant(message)))
            messages.append(.assistant(message))
            throw AgentError.streamEndedWithoutResult
        }

        messages.append(.assistant(final))
        return final
    }

    /// Executes one tool call: hooks, execution, events and transcript append.
    private func executeToolCall(_ call: ToolCall, signal: CancellationSignal) async throws {
        emit(.toolExecutionStart(toolCallId: call.id, name: call.name, arguments: call.arguments))

        var result: ToolResult
        var isError: Bool
        var executed = false

        if let tool = options.tools.first(where: { $0.name == call.name }) {
            if let before = options.beforeToolCall, await before(call) == false {
                result = ToolResult(text: "Tool execution skipped: \(call.name)", isError: true)
                isError = true
            } else {
                executed = true
                let gate = UpdateGate()
                let onUpdate: @Sendable (ToolResult) -> Void = { [dispatcher] partial in
                    gate.forward {
                        dispatcher.emit(.toolExecutionUpdate(toolCallId: call.id, partial: partial))
                    }
                }
                do {
                    result = try await tool.execute(call, onUpdate: onUpdate)
                    isError = result.isError
                } catch is CancellationError {
                    gate.close()
                    throw CancellationError()
                } catch {
                    gate.close()
                    if signal.isCancelled || Task.isCancelled {
                        throw CancellationError()
                    }
                    result = ToolResult(text: error.localizedDescription, isError: true)
                    isError = true
                }
                gate.close()
            }
        } else {
            result = ToolResult(text: "Tool \(call.name) not found", isError: true)
            isError = true
        }

        if executed, let after = options.afterToolCall {
            await after(call, result)
        }

        emit(.toolExecutionEnd(
            toolCallId: call.id,
            name: call.name,
            result: result,
            isError: isError
        ))

        let message = Message.toolResult(ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            content: result.content,
            details: result.details,
            usage: result.usage,
            isError: isError,
            timestamp: Clock.nowMillis()
        ))
        messages.append(message)
        emit(.messageStart(message))
        emit(.messageEnd(message))
    }

    // MARK: - Helpers

    private func makeContext() -> ChatContext {
        let tools: [Tool] = options.tools.map { tool in
            let parameters = (try? JSONSchema(jsonValue: tool.parametersJSONSchema)) ?? JSONSchema()
            return Tool(name: tool.name, description: tool.description, parameters: parameters)
        }
        return ChatContext(systemPrompt: options.systemPrompt, messages: messages, tools: tools)
    }

    private func failureMessage(stopReason: StopReason, errorMessage: String?) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: options.model.api,
            provider: options.model.provider,
            model: options.model.id,
            stopReason: stopReason,
            errorMessage: errorMessage,
            timestamp: Clock.nowMillis()
        )
    }
}
