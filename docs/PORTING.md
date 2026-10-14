# PORTING — upstream `@earendil-works/pi-agent-core` → Swift `PiAgentCore`

This document records how the Swift port maps to the upstream TypeScript source
(`packages/agent/src/**`, version 1.2.0) and every intentional deviation.

## Status

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 | Types + `Agent` skeleton + single-turn chat (no tools) | ✅ done |
| M2 | Tool loop + lifecycle events | ✅ done |
| M3 | Cancellation + hooks + `reset` | ✅ done |
| M4 | Full test coverage + CI + docs + LICENSE/ATTRIBUTION | ✅ done |
| M5 | `v0.1.0` release metadata | ✅ done |

## File mapping

| Upstream | Swift | Notes |
| --- | --- | --- |
| `types.ts` | `Types.swift` | Public contract: `AgentOptions`, `AgentTool`, `AgentEvent`, `ToolResult`, `AgentError`. |
| `agent.ts` (`Agent` class) | `Agent.swift` | Actor owning transcript, subscriptions, `prompt` / `abort` / `reset` / `isStreaming`. |
| `agent-loop.ts` (`runAgentLoop`, `executeToolCalls`, `streamAssistantResponse`) | `Agent.swift` (private loop) | Assistant request → tool batch → append results → repeat. |
| `agent-loop.ts` (`prepareToolCall` / `finalizeExecutedToolCall`) | `Agent.executeToolCall` | Tool lookup, `beforeToolCall`, execution, `afterToolCall`, error normalization. |
| `stream-fn.ts` | `StreamFn.swift` | `StreamFn` typealias + `ChatProvider.streamFn` adapter. |
| `agent.ts` (event fan-out) | `EventDispatcher.swift` | Ordered, synchronous, thread-safe listener fan-out. |
| upstream partial-message accumulation | `AssistantMessageAccumulator.swift` | Rebuilds partials for `messageUpdate` (PiAI deltas carry no `partial`). |
| `proxy.ts` | — | Out of scope (host/proxy concerns). |

## Public API mapping

| Upstream (`types.ts` / `agent.ts`) | Swift | Notes |
| --- | --- | --- |
| `AgentOptions` (many fields) | `AgentOptions` | Reduced to `systemPrompt` / `model` / `tools` / `provider` / `maxToolRounds` / hooks per `TASK.md`. |
| `AgentTool<TParameters, TDetails>` | `AgentTool` | `label`, `outputSchema`, `prepareArguments`, `replay`, `executionMode` omitted. |
| `AgentToolResult<T>` | `ToolResult` | `structuredContent` / `terminate` omitted. |
| `AgentEvent` (union) | `AgentEvent` | Turn events, `tool_execution_update.args` and `durationMs` omitted. |
| `BeforeToolCallResult` (`{ block, reason, terminate }`) | `beforeToolCall -> Bool` | `false` blocks the call; the reason is a fixed message. |
| `AfterToolCallContext` / `AfterToolCallResult` | `afterToolCall(ToolCall, ToolResult)` | Result mutation is not supported; the hook observes only. |
| `AgentState` | `Agent.transcript` + `isStreaming` | No public mutable state; `model` / `tools` / `systemPrompt` live in `AgentOptions`. |
| `AbortSignal` | `PiAI.CancellationSignal` | `abort()` and `Task.cancel()` both cancel it. |

## Intentional deviations from upstream

1. **Actor instead of mutable class.** Upstream `Agent` mutates a plain object
   with a `Set` of listeners. The Swift port is an `actor`, so the transcript is
   isolated and all public types are `Sendable`. `prompt` runs on the caller's
   task; actor reentrancy lets `abort()` / `isStreaming` interleave while a run
   awaits the provider.

2. **Synchronous listeners.** `TASK.md` fixes
   `subscribe(_ listener: @Sendable (AgentEvent) -> Void) -> () -> Void`.
   Upstream listeners may return a `Promise` that is awaited in subscription
   order. Here listeners are synchronous and invoked in registration order, so
   ordering is guaranteed and `agentEnd` is the last callback before `prompt`
   returns. `EventDispatcher` makes the fan-out thread-safe because tool
   `onUpdate` callbacks can run off the actor.

3. **`agentEnd.messages` are run messages.** Upstream `agent_end` carries the
   messages produced by the run (`newMessages`), not the whole transcript. The
   Swift port matches that.

4. **No turn events.** Upstream emits `turn_start` / `turn_end` and
   per-block `text_start` / `text_delta` / … events. `TASK.md`'s `AgentEvent`
   folds these into `messageStart` / `messageUpdate` / `messageEnd`, so
   `messageUpdate` is emitted once per PiAI delta event.

5. **`maxToolRounds` is new.** Upstream loops until the model stops calling
   tools (or a `finishTurn` decision ends the run). The Swift port additionally
   caps tool batches at `maxToolRounds` (default 8); `0` disables tool
   execution. After the capped batch the loop stops, so the transcript may end
   with a tool result.

6. **`beforeToolCall` is a `Bool`.** Upstream returns
   `{ block, reason, terminate }`. The Swift hook returns `false` to skip; the
   skip is recorded as an error `ToolResult` (`"Tool execution skipped: <name>"`)
   so every `tool_call_id` still has a matching result. `afterToolCall` runs
   only when the tool actually executed, matching upstream.

7. **Errors propagate.** Upstream `Agent.prompt` resolves even when the provider
   fails, after emitting a synthetic failure turn. The Swift `prompt` is
   `async throws`: it records the failure assistant message, emits `agentEnd`,
   then rethrows the provider error (or `CancellationError`). This satisfies the
   `TASK.md` "不吞错" requirement.

8. **`reset()` cannot throw.** Upstream `reset()` throws while a run is active.
   `TASK.md` fixes a non-throwing signature, so `reset()` is a no-op during a
   run. It clears only the transcript; `systemPrompt`, `tools` and `model` are
   retained in `AgentOptions`.

9. **No `streamFn` injection.** Upstream requires a `streamFn` (or a globally
   installed default). `AgentOptions` carries a `ChatProvider` directly;
   `StreamFn.swift` provides the adapter for hosts that want the functional
   form.

10. **Tool argument validation is deferred to the provider.** Upstream validates
    arguments against the tool schema before `beforeToolCall`. The Swift port
    forwards the parsed `ToolCall.arguments` unchanged; schema validation is
    performed by the provider layer (`PiAI`) when building the request.

11. **`AgentOptions.apiKey` is additive.** The `TASK.md` field list has no API
    key, but `PiAI`'s `OpenAICompletionsProvider` reads the key from
    `ChatOptions` at call time. `AgentOptions` therefore carries an optional
    `apiKey` (default `""`) that the agent forwards into every request. No
    listed field is removed or renamed.

## Out of scope

Steering and follow-up queues, `finishTurn` / `prepareRequest` /
`prepareNextTurn`, `convertToLlm` / `transformContext`, model fallbacks,
thinking budgets, transport selection, retry-delay caps, session IDs,
`runToolCall` (nested tool invocation), and `proxy.ts`.
