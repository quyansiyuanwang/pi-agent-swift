import Foundation
import PiAI
import Testing

@testable import PiAgentCore

@Suite("Agent loop")
struct AgentLoopTests {
    // MARK: - Single turn

    @Test("single turn without tools streams one assistant message")
    func singleTurn() async throws {
        let provider = MockProvider(steps: [.message(makeAssistant(text: "Hello!", stopReason: .stop))])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        try await agent.prompt("Hi")

        let transcript = await agent.transcript
        #expect(provider.callCount == 1)
        #expect(transcript.count == 2)
        #expect(assistantText(transcript.last) == "Hello!")
        #expect(log.labels == [
            "agentStart",
            "messageStart", "messageEnd",
            "messageStart", "messageEnd",
            "agentEnd"
        ])
    }

    @Test("streaming deltas produce messageUpdate with growing partials")
    func messageUpdates() async throws {
        let final = makeAssistant(text: "Hello", stopReason: .stop)
        let provider = MockProvider(steps: [
            .events([
                .start,
                .textDelta("Hel"),
                .textDelta("lo"),
                .done(final)
            ])
        ])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        try await agent.prompt("Hi")

        let updates = log.events.compactMap { event -> Message? in
            if case .messageUpdate(let message, _) = event { return message }
            return nil
        }
        let transcript = await agent.transcript
        #expect(updates.count == 2)
        #expect(assistantText(updates.first) == "Hel")
        #expect(assistantText(updates.last) == "Hello")
        #expect(assistantText(transcript.last) == "Hello")
    }

    // MARK: - Tool loop

    @Test("assistant tool call executes, appends a tool result, and continues")
    func multiTurnToolCall() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let call = makeToolCall(id: "call_1", name: "add", arguments: .object(["a": .int(2), "b": .int(3)]))
        let provider = MockProvider(steps: [
            .message(makeAssistant(toolCalls: [call], stopReason: .toolUse)),
            .message(makeAssistant(text: "The sum is 5", stopReason: .stop))
        ])
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            tools: [tool],
            provider: provider
        ))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        try await agent.prompt("add 2 and 3")

        let transcript = await agent.transcript
        #expect(provider.callCount == 2)
        #expect(spy.executions.count == 1)
        #expect(transcript.count == 4)

        // The second request must carry the tool result associated by tool_call_id.
        let secondContext = try #require(provider.contexts.dropFirst().first)
        let toolResult = secondContext.messages.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message { return result }
            return nil
        }.first
        #expect(toolResult?.toolCallId == "call_1")
        #expect(toolResult?.toolName == "add")
        #expect(toolResult?.isError == false)
        #expect(toolResult?.content.first == .text(TextContent(text: "5")))

        #expect(log.labels.contains("toolExecutionStart"))
        #expect(log.labels.contains("toolExecutionUpdate"))
        #expect(log.labels.contains("toolExecutionEnd"))
        #expect(log.labels.last == "agentEnd")
    }

    @Test("maxToolRounds caps tool execution rounds")
    func maxToolRounds() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let call = makeToolCall(id: "call", name: "add", arguments: .object(["a": .int(1), "b": .int(1)]))
        let provider = MockProvider(steps: Array(
            repeating: .message(makeAssistant(toolCalls: [call], stopReason: .toolUse)),
            count: 5
        ))
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            tools: [tool],
            provider: provider,
            maxToolRounds: 2
        ))

        try await agent.prompt("loop")

        let transcript = await agent.transcript
        #expect(provider.callCount == 2)
        #expect(spy.executions.count == 2)
        // Transcript: user + (assistant + toolResult) x2.
        #expect(transcript.count == 5)
        if case .toolResult = transcript.last {
            // expected: the loop stopped after the capped batch
        } else {
            Issue.record("expected the transcript to end with a tool result")
        }
    }

    @Test("zero maxToolRounds never executes tools")
    func zeroToolRounds() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let call = makeToolCall(id: "call", name: "add", arguments: .object([:]))
        let provider = MockProvider(steps: [.message(makeAssistant(toolCalls: [call], stopReason: .toolUse))])
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            tools: [tool],
            provider: provider,
            maxToolRounds: 0
        ))

        try await agent.prompt("loop")

        let transcript = await agent.transcript
        #expect(provider.callCount == 1)
        #expect(spy.executions.isEmpty)
        #expect(transcript.count == 2)
    }

    @Test("unknown tools are recorded as error results")
    func unknownTool() async throws {
        let call = makeToolCall(id: "call_9", name: "missing", arguments: .object([:]))
        let provider = MockProvider(steps: [
            .message(makeAssistant(toolCalls: [call], stopReason: .toolUse)),
            .message(makeAssistant(text: "done", stopReason: .stop))
        ])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        try await agent.prompt("go")

        let end = log.events.compactMap { event -> (String, ToolResult, Bool)? in
            if case .toolExecutionEnd(let id, _, let result, let isError) = event {
                return (id, result, isError)
            }
            return nil
        }.first
        #expect(end?.0 == "call_9")
        #expect(end?.2 == true)
        #expect(end?.1.content.first == .text(TextContent(text: "Tool missing not found")))
    }

    @Test("throwing tools become error results without aborting the run")
    func throwingTool() async throws {
        let provider = MockProvider(steps: [
            .message(makeAssistant(
                toolCalls: [makeToolCall(id: "call_b", name: "boom", arguments: .object([:]))],
                stopReason: .toolUse
            )),
            .message(makeAssistant(text: "recovered", stopReason: .stop))
        ])
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            tools: [FailingTool()],
            provider: provider
        ))

        try await agent.prompt("go")

        let transcript = await agent.transcript
        #expect(provider.callCount == 2)
        let result = transcript.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message { return result }
            return nil
        }.first
        #expect(result?.isError == true)
        #expect(assistantText(transcript.last) == "recovered")
    }

    // MARK: - Hooks

    @Test("beforeToolCall returning false skips execution and records the skip")
    func beforeHookBlocks() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let call = makeToolCall(id: "call_x", name: "add", arguments: .object(["a": .int(1), "b": .int(2)]))
        let provider = MockProvider(steps: [
            .message(makeAssistant(toolCalls: [call], stopReason: .toolUse)),
            .message(makeAssistant(text: "ok", stopReason: .stop))
        ])
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            tools: [tool],
            provider: provider,
            beforeToolCall: { _ in false },
            afterToolCall: { call, result in spy.recordAfter(call, result) }
        ))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        try await agent.prompt("go")

        let transcript = await agent.transcript
        #expect(spy.executions.isEmpty)
        #expect(spy.afterCalls.isEmpty)
        let result = transcript.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message { return result }
            return nil
        }.first
        #expect(result?.isError == true)
        #expect(result?.content.first == .text(TextContent(text: "Tool execution skipped: add")))
        #expect(log.labels.contains("toolExecutionEnd"))
    }

    @Test("beforeToolCall returning true runs the tool and afterToolCall fires")
    func afterHookRuns() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let call = makeToolCall(id: "call_y", name: "add", arguments: .object(["a": .int(4), "b": .int(5)]))
        let provider = MockProvider(steps: [
            .message(makeAssistant(toolCalls: [call], stopReason: .toolUse)),
            .message(makeAssistant(text: "ok", stopReason: .stop))
        ])
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            tools: [tool],
            provider: provider,
            beforeToolCall: { _ in true },
            afterToolCall: { call, result in spy.recordAfter(call, result) }
        ))

        try await agent.prompt("go")

        #expect(spy.executions.count == 1)
        #expect(spy.afterCalls.count == 1)
        #expect(spy.afterCalls.first?.0.id == "call_y")
        #expect(spy.afterCalls.first?.1.content.first == .text(TextContent(text: "9")))
    }

    // MARK: - Multiple calls and option forwarding

    @Test("multiple tool calls in one message execute sequentially and in order")
    func sequentialToolCalls() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let calls = [
            makeToolCall(id: "a", name: "add", arguments: .object(["a": .int(1), "b": .int(1)])),
            makeToolCall(id: "b", name: "add", arguments: .object(["a": .int(2), "b": .int(2)]))
        ]
        let provider = MockProvider(steps: [
            .message(makeAssistant(toolCalls: calls, stopReason: .toolUse)),
            .message(makeAssistant(text: "done", stopReason: .stop))
        ])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, tools: [tool], provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        try await agent.prompt("go")

        #expect(spy.executions.map(\.id) == ["a", "b"])
        let starts = log.events.compactMap { event -> String? in
            if case .toolExecutionStart(let id, _, _) = event { return id }
            return nil
        }
        #expect(starts == ["a", "b"])
        let transcript = await agent.transcript
        let resultIds = transcript.compactMap { message -> String? in
            if case .toolResult(let result) = message { return result.toolCallId }
            return nil
        }
        #expect(resultIds == ["a", "b"])
    }

    @Test("the API key is forwarded to the provider")
    func apiKeyForwarded() async throws {
        let provider = MockProvider(steps: [.message(makeAssistant(text: "ok"))])
        let agent = Agent(options: AgentOptions(
            model: Fixtures.model,
            provider: provider,
            apiKey: "sk-test"
        ))

        try await agent.prompt("hi")

        #expect(provider.apiKeys == ["sk-test"])
    }
}
