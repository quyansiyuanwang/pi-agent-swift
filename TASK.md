# TASK — PiAgentCore: pi-agent-core 的 Swift 移植

你是本仓库的开发 agent。请阅读本文件后按里程碑推进，**每个里程碑保证 `swift build && swift test` 通过并提交**。

## 前置依赖
本包依赖同级的 `../pi-ai-swift`（产品 `PiAI`），其提供类型、`ChatProvider`、`AssistantMessageEvent`。
**开始前先确认 `../pi-ai-swift` 已至少完成 M3（流式 + 工具调用）**，否则先做接口对接的占位与测试替身。

## 目标
把上游 `@earendil-works/pi-agent-core` 移植为原生 Swift 包 `PiAgentCore`：负责 transcript 状态、
工具调用循环、生命周期事件、取消与钩子。最终供 macOS 应用直接链接，运行期不依赖 Node.js。

## 上游参考（唯一事实来源）
`.tmp/pi/packages/agent/src/`：
- `agent.ts`        → `Agent.swift`（状态、订阅、prompt、abort、reset、steer/followUp）
- `agent-loop.ts`   → `AgentLoop.swift`（核心循环）
- `stream-fn.ts`    → `StreamFn.swift`
- `types.ts`        → `Types.swift`（AgentState/AgentEvent/AgentTool/结果类型）
- `proxy.ts`        → 视需要
测试参考 `.tmp/pi/packages/agent/test/**`。上游版本 1.2.0，MIT。

## 公共 API（务必稳定，供消费方机械对接）
```swift
public struct AgentOptions: Sendable {
    public var systemPrompt: String
    public var model: Model                       // from PiAI
    public var tools: [any AgentTool]
    public var provider: any ChatProvider         // from PiAI
    public var maxToolRounds: Int                 // 默认 8
    public var beforeToolCall: (@Sendable (ToolCall) async -> Bool)?
    public var afterToolCall: (@Sendable (ToolCall, ToolResult) async -> Void)?
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersJSONSchema: JSONValue { get }
    func execute(_ call: ToolCall, onUpdate: ((ToolResult) -> Void)?) async throws -> ToolResult
}

public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [Message])
    case messageStart(Message)
    case messageUpdate(Message, AssistantMessageEvent)
    case messageEnd(Message)
    case toolExecutionStart(toolCallId: String, name: String, arguments: JSONValue)
    case toolExecutionUpdate(toolCallId: String, partial: ToolResult)
    case toolExecutionEnd(toolCallId: String, name: String, result: ToolResult, isError: Bool)
}

public actor Agent {
    public init(options: AgentOptions)
    public var isStreaming: Bool { get }
    public func prompt(_ text: String) async throws
    public func abort()
    public func reset()
    public func subscribe(_ listener: @Sendable (AgentEvent) -> Void) -> () -> Void
}
```

## 行为规范
1. 工具循环：assistant 返回 tool_calls → 逐个执行 → 追加 tool 结果 → 继续请求，直到无 tool_calls 或达 `maxToolRounds`。
2. 事件语义：`agentStart` 在运行开始时；`agentEnd` 是本次运行最后事件；`subscribe` 监听按注册顺序 await。
3. 取消：`abort()` 与 `Task.cancel()` 必须中断流与工具执行；被取消时给出明确结果，不吞错。
4. 钩子：`beforeToolCall` 返回 false 时跳过该工具并记录；`afterToolCall` 在每次执行后调用。
5. assistant `content=null` 且有 tool_calls 时正确入 transcript；tool 结果用 `tool_call_id` 关联。
6. `reset()` 清空 transcript 并保留 systemPrompt / tools / model。

## 工程要求
- SwiftPM，`swift-tools-version:6.0`，macOS 13+ / iOS 16+，**零第三方依赖**（依赖 PiAI）。
- Swift 6 严格并发零警告；`Agent` 用 actor 保证状态安全；公共类型 `Sendable`。
- 测试：用假 `ChatProvider`（可编程返回若干轮 tool_calls）覆盖：单轮、多轮工具、达上限、取消、reset、事件顺序、钩子。
- CI：GitHub Actions（macOS）`swift build && swift test`。
- 文档：README（快速开始）、`docs/PORTING.md`（上游对照表）。

## 里程碑
- M1 类型 + Agent 骨架 + 单轮对话（无工具）
- M2 工具循环 + 事件
- M3 取消 + 钩子 + reset
- M4 测试补全 + CI + 文档
- M5 `v0.1.0` tag

## Definition of Done
- [ ] `swift build && swift test` 全绿、零警告
- [ ] `.tmp/` 未被提交
- [ ] 公共 API 与本文件一致，README 有完整示例
- [ ] CI 通过，`v0.1.0` tag
- [ ] `LICENSE`(MIT) 与 `ATTRIBUTION.md` 就位

## 工作方式
按里程碑提交，每步可编译可测试。全部代码 MIT，保留上游归属。
