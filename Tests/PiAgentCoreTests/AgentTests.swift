import Foundation
import PiAI
import Testing

@testable import PiAgentCore

@Suite("Agent lifecycle")
struct AgentTests {
    // MARK: - Subscription

    @Test("subscribe delivers events in order and unsubscribe stops delivery")
    func subscribeAndUnsubscribe() async throws {
        let provider = MockProvider(steps: [
            .message(makeAssistant(text: "one")),
            .message(makeAssistant(text: "two"))
        ])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }

        try await agent.prompt("first")
        let countAfterFirst = log.events.count
        #expect(countAfterFirst == 6)

        unsubscribe()
        try await agent.prompt("second")
        #expect(log.events.count == countAfterFirst)
    }

    // MARK: - Reset

    @Test("reset clears the transcript but keeps prompt, tools and model")
    func resetKeepsConfiguration() async throws {
        let spy = ToolSpy()
        let tool = AddTool(spy: spy)
        let provider = MockProvider(steps: [
            .message(makeAssistant(text: "one")),
            .message(makeAssistant(text: "two"))
        ])
        let agent = Agent(options: AgentOptions(
            systemPrompt: "You are a test.",
            model: Fixtures.model,
            tools: [tool],
            provider: provider
        ))

        try await agent.prompt("first")
        #expect(await agent.transcript.count == 2)

        await agent.reset()
        #expect(await agent.transcript.isEmpty)

        try await agent.prompt("second")
        #expect(await agent.transcript.count == 2)

        let context = provider.contexts.last
        #expect(context?.systemPrompt == "You are a test.")
        #expect(context?.tools.count == 1)
        #expect(context?.tools.first?.name == "add")
    }

    @Test("setTranscript replaces the transcript")
    func setTranscriptReplaces() async throws {
        let provider = MockProvider(steps: [.message(makeAssistant(text: "one"))])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))

        try await agent.prompt("first")
        #expect(await agent.transcript.count == 2)

        let seeded: [Message] = [
            .user(UserMessage(content: "hello", timestamp: 1)),
            .assistant(makeAssistant(text: "hi there")),
        ]
        await agent.setTranscript(seeded)

        let transcript = await agent.transcript
        #expect(transcript.count == 2)
        #expect(transcript.first == seeded.first)
        #expect(transcript.last == seeded.last)
    }

    @Test("reset is a no-op while streaming")
    func resetDuringRunIsNoOp() async throws {
        let provider = MockProvider(steps: [.hang, .hang])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))

        let task = Task { try await agent.prompt("hi") }
        let started = await waitUntil { await agent.isStreaming }
        #expect(started)

        await agent.reset()
        #expect(await agent.transcript.count == 1)

        await agent.abort()
        await expectCancellation(task)
    }

    // MARK: - Cancellation

    @Test("abort interrupts the stream and throws CancellationError")
    func abortInterruptsRun() async throws {
        let provider = MockProvider(steps: [.hang, .hang])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        let task = Task { try await agent.prompt("hi") }
        let started = await waitUntil { await agent.isStreaming }
        #expect(started)

        await agent.abort()
        await expectCancellation(task)

        #expect(await waitUntil { await !agent.isStreaming })
        #expect(log.labels.last == "agentEnd")
        let transcript = await agent.transcript
        if case .assistant(let message) = transcript.last {
            #expect(message.stopReason == .aborted)
        } else {
            Issue.record("expected an aborted assistant message")
        }
    }

    @Test("Task.cancel interrupts the stream and throws CancellationError")
    func taskCancelInterruptsRun() async throws {
        let provider = MockProvider(steps: [.hang, .hang])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        let task = Task { try await agent.prompt("hi") }
        let started = await waitUntil { await agent.isStreaming }
        #expect(started)

        task.cancel()
        await expectCancellation(task)

        #expect(await waitUntil { await !agent.isStreaming })
        #expect(log.labels.last == "agentEnd")
    }

    @Test("a second prompt while streaming throws alreadyRunning")
    func concurrentPromptRejected() async throws {
        let provider = MockProvider(steps: [.hang, .hang])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))

        let task = Task { try await agent.prompt("hi") }
        let started = await waitUntil { await agent.isStreaming }
        #expect(started)

        do {
            try await agent.prompt("again")
            Issue.record("expected AgentError.alreadyRunning")
        } catch let error as AgentError {
            #expect(error == .alreadyRunning)
        }

        await agent.abort()
        await expectCancellation(task)
    }

    // MARK: - Provider failures

    @Test("a thrown provider failure emits agentEnd and rethrows")
    func providerFailure() async throws {
        let provider = MockProvider(steps: [.failure(TestProviderError(message: "provider exploded"))])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        do {
            try await agent.prompt("hi")
            Issue.record("expected the provider error to propagate")
        } catch let error as TestProviderError {
            #expect(error.message == "provider exploded")
        }

        #expect(log.labels.last == "agentEnd")
        let transcript = await agent.transcript
        #expect(transcript.count == 2)
        if case .assistant(let message) = transcript.last {
            #expect(message.stopReason == .error)
            #expect(message.errorMessage?.contains("provider exploded") == true)
        } else {
            Issue.record("expected an error assistant message")
        }
    }

    @Test("an .error event is converted into an error message and rethrown")
    func errorEvent() async throws {
        let provider = MockProvider(steps: [
            .events([.start, .error(TestProviderError(message: "stream failed"))])
        ])
        let agent = Agent(options: AgentOptions(model: Fixtures.model, provider: provider))
        let log = EventLog()
        let unsubscribe = agent.subscribe { log.append($0) }
        defer { unsubscribe() }

        do {
            try await agent.prompt("hi")
            Issue.record("expected the provider error to propagate")
        } catch let error as TestProviderError {
            #expect(error.message == "stream failed")
        }

        #expect(log.labels.last == "agentEnd")
        let transcript = await agent.transcript
        if case .assistant(let message) = transcript.last {
            #expect(message.stopReason == .error)
        } else {
            Issue.record("expected an error assistant message")
        }
    }
}

// MARK: - Cancellation helper

/// Asserts that `task` finishes by throwing `CancellationError`.
func expectCancellation(_ task: Task<Void, Error>) async {
    do {
        try await task.value
        Issue.record("expected CancellationError")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("expected CancellationError, got \(error)")
    }
}
