# PiAgentCore

[![CI](https://github.com/quyansiyuanwang/pi-agent-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/quyansiyuanwang/pi-agent-swift/actions/workflows/ci.yml)

A native Swift port of the agent runtime from
[`@earendil-works/pi-agent-core`](https://github.com/earendil-works/pi)
(upstream version **1.2.0**, MIT).

PiAgentCore links directly into macOS / iOS apps and has **no runtime dependency
on Node.js** and **no third-party Swift packages**. It provides a `Sendable`
actor that owns a transcript, drives the assistant ↔ tool loop over any
[`PiAI`](../pi-ai-swift) `ChatProvider`, emits lifecycle events, supports
cooperative cancellation, and exposes `beforeToolCall` / `afterToolCall` hooks.

> Ported from `earendil-works/pi@1.2.0`. See [`ATTRIBUTION.md`](ATTRIBUTION.md)
> and [`docs/PORTING.md`](docs/PORTING.md) for the upstream mapping and every
> intentional deviation.

## Features

- ✅ `Agent` actor: `prompt`, `abort`, `reset`, `isStreaming`, `subscribe`
- ✅ Tool loop: assistant `tool_calls` → execute → append results → continue
- ✅ `maxToolRounds` cap (default 8; `0` disables tool execution)
- ✅ Lifecycle events: `agentStart` … `agentEnd` (always last)
- ✅ Cooperative cancellation via `abort()` **and** `Task.cancel()`
- ✅ `beforeToolCall` / `afterToolCall` hooks, with skipped calls recorded
- ✅ Transcript preserved / cleared by `reset()` while config is retained
- ✅ Swift 6 strict concurrency, `Sendable` public types, zero warnings
- ✅ Tested with a programmable mock `ChatProvider` (no network)

## Requirements

| | |
| --- | --- |
| Swift | 6.0+ (`swift-tools-version:6.0`) |
| Platforms | macOS 13+, iOS 16+ |
| Dependencies | [`PiAI`](../pi-ai-swift) |

## Installation

Add PiAgentCore and PiAI to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/pi-agent-swift.git", from: "0.1.0"),
    .package(url: "https://github.com/<owner>/pi-ai-swift.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["PiAgentCore", "PiAI"])
]
```

## Quick start

```swift
import PiAgentCore
import PiAI

// 1. Define a tool.
struct WeatherTool: AgentTool {
    var name: String { "get_weather" }
    var description: String { "Get the current weather for a city." }

    var parametersJSONSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "city": .object([
                    "type": "string",
                    "description": "City name."
                ])
            ]),
            "required": .array([.string("city")])
        ])
    }

    func execute(_ call: ToolCall, onUpdate: ((ToolResult) -> Void)?) async throws -> ToolResult {
        let city = call.arguments["city"].stringValue ?? "unknown"
        onUpdate?(ToolResult(text: "Looking up \(city)…"))
        return ToolResult(text: "It is sunny in \(city).")
    }
}

// 2. Build the agent.
let model = Model(
    id: "gpt-4o-mini",
    name: "GPT-4o mini",
    api: "openai-completions",
    provider: "openai",
    baseURL: "https://api.openai.com/v1",
    contextWindow: 128_000,
    maxTokens: 16_384
)

let agent = Agent(options: AgentOptions(
    systemPrompt: "You are a helpful assistant.",
    model: model,
    tools: [WeatherTool()],
    provider: OpenAICompletionsProvider(),
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
))

// 3. Observe lifecycle events.
let unsubscribe = agent.subscribe { event in
    switch event {
    case .agentStart:
        print("agent started")
    case .messageUpdate(_, let update):
        if case .textDelta(let delta) = update { print(delta, terminator: "") }
    case .toolExecutionStart(_, let name, let arguments):
        print("\n→ \(name) \(arguments)")
    case .toolExecutionEnd(_, let name, let result, let isError):
        print("← \(name) error=\(isError) result=\(result.content)")
    case .agentEnd(let messages):
        print("\nagent finished with \(messages.count) new message(s)")
    default:
        break
    }
}

// 4. Run it.
try await agent.prompt("What's the weather in Paris?")
unsubscribe()
```

## API

### `AgentOptions`

```swift
public struct AgentOptions: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var tools: [any AgentTool]
    public var provider: any ChatProvider
    public var apiKey: String
    public var maxToolRounds: Int
    public var beforeToolCall: (@Sendable (ToolCall) async -> Bool)?
    public var afterToolCall: (@Sendable (ToolCall, ToolResult) async -> Void)?
}
```

`apiKey` is an additive field: `PiAI`'s providers read the key from the request
options, so the agent must be able to forward one.

### `AgentTool`

```swift
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersJSONSchema: JSONValue { get }
    func execute(_ call: ToolCall, onUpdate: ((ToolResult) -> Void)?) async throws -> ToolResult
}
```

Return `ToolResult(isError: true)` for expected failures; throw only for
unexpected ones (the agent converts a throw into an error tool result and keeps
the run alive).

### `AgentEvent`

| Event | When |
| --- | --- |
| `agentStart` | run begins |
| `messageStart` | user prompt, assistant partial, or tool result is added |
| `messageUpdate` | an assistant delta arrives (`AssistantMessageEvent`) |
| `messageEnd` | an assistant or tool-result message is finalized |
| `toolExecutionStart` | a tool call begins |
| `toolExecutionUpdate` | a tool emits a partial result via `onUpdate` |
| `toolExecutionEnd` | a tool call finishes (or was skipped) |
| `agentEnd` | last event of the run |

### `Agent`

```swift
public actor Agent {
    public init(options: AgentOptions)
    public var isStreaming: Bool { get }
    public var transcript: [Message] { get }
    public func prompt(_ text: String) async throws
    public func abort()
    public func reset()
    public func subscribe(_ listener: @escaping @Sendable (AgentEvent) -> Void) -> () -> Void
}
```

## Cancellation

`prompt` runs on the caller's task, so both of these interrupt the provider
stream and any in-flight tool:

```swift
// Explicit abort.
let task = Task { try await agent.prompt("…") }
await agent.abort()          // task throws CancellationError

// Or cancel the surrounding task.
task.cancel()                // same
```

`agentEnd` is emitted before the `CancellationError` propagates; the transcript
records an assistant message with `stopReason == .aborted`.

## Hooks

```swift
let agent = Agent(options: AgentOptions(
    model: model,
    tools: [tool],
    provider: provider,
    beforeToolCall: { call in
        // Return false to skip the call. The skip is recorded as an error
        // tool result so every tool_call_id still has a matching result.
        return call.name != "dangerous"
    },
    afterToolCall: { call, result in
        print("ran \(call.name): \(result.isError ? "error" : "ok")")
    }
))
```

## Relationship to upstream

PiAgentCore is an independent, faithful port of the agent runtime subset of
`@earendil-works/pi-agent-core`. The tool loop, event ordering, cancellation and
hook semantics track upstream; every intentional deviation (actor instead of
mutable class, synchronous listeners, no turn events, `maxToolRounds`,
`Bool`-returning `beforeToolCall`, thrown errors) is recorded in
[`docs/PORTING.md`](docs/PORTING.md). Upstream copyright and license are
retained in [`ATTRIBUTION.md`](ATTRIBUTION.md).

## Development

```sh
swift build -Xswiftc -warnings-as-errors
swift test  -Xswiftc -warnings-as-errors
```

CI runs both commands on a macOS runner
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## License

MIT. See [`LICENSE`](LICENSE) and [`ATTRIBUTION.md`](ATTRIBUTION.md).
