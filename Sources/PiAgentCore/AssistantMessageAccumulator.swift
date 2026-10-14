import Foundation
import PiAI

/// Rebuilds a partial ``AssistantMessage`` from the streaming events of
/// ``ChatProvider``.
///
/// PiAI's ``AssistantMessageEvent`` does not carry a shared `partial` message
/// the way upstream does, so the agent accumulates text, thinking, and tool-call
/// fragments itself. The accumulator is only used for `messageUpdate` payloads;
/// the final message always comes from `.done`.
struct AssistantMessageAccumulator {
    private(set) var message: AssistantMessage

    private var text = ""
    private var thinking = ""
    private var toolCalls: [Int: PartialToolCall] = [:]
    private var toolCallOrder: [Int] = []

    private struct PartialToolCall {
        var id: String?
        var name: String?
        var arguments = ""
    }

    init(model: Model) {
        message = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .pending,
            timestamp: Clock.nowMillis()
        )
    }

    /// Applies one provider event and refreshes ``message`` for deltas.
    mutating func apply(_ event: AssistantMessageEvent) {
        switch event {
        case .start:
            break
        case .textDelta(let delta):
            text += delta
            rebuildContent()
        case .thinkingDelta(let delta):
            thinking += delta
            rebuildContent()
        case .toolCallDelta(let index, let id, let name, let fragment):
            var partial = toolCalls[index] ?? PartialToolCall()
            if let id { partial.id = id }
            if let name { partial.name = name }
            partial.arguments += fragment
            if toolCalls[index] == nil { toolCallOrder.append(index) }
            toolCalls[index] = partial
            rebuildContent()
        case .done(let final):
            message = final
        case .error:
            break
        }
    }

    private mutating func rebuildContent() {
        var content: [ContentBlock] = []
        if !thinking.isEmpty {
            content.append(.thinking(ThinkingContent(thinking: thinking)))
        }
        if !text.isEmpty {
            content.append(.text(TextContent(text: text)))
        }
        for index in toolCallOrder {
            guard let partial = toolCalls[index] else { continue }
            content.append(.toolCall(ToolCall(
                id: partial.id ?? "",
                name: partial.name ?? "",
                arguments: Self.parseArguments(partial.arguments)
            )))
        }
        message.content = content
    }

    /// Best-effort parse of accumulated argument fragments. Invalid (still
    /// streaming) JSON falls back to an empty object.
    private static func parseArguments(_ fragment: String) -> JSONValue {
        guard !fragment.isEmpty, let data = fragment.data(using: .utf8) else { return .object([:]) }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
    }
}
