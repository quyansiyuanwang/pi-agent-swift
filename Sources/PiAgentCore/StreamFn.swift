import PiAI

/// A streaming chat function.
///
/// Mirrors upstream `StreamFn` (`packages/agent/src/types.ts`): it takes a
/// model, a request context, and stream options, and returns the provider's
/// assistant-message event stream.
///
/// This package's `AgentOptions` carries a ``ChatProvider`` directly, so the
/// type is mostly a compatibility seam for hosts that want to build loops
/// around a raw function. ``ChatProvider/streamFn`` adapts a provider.
public typealias StreamFn = @Sendable (
    Model,
    ChatContext,
    ChatOptions
) -> AsyncThrowingStream<AssistantMessageEvent, any Error>

extension ChatProvider {
    /// The provider as a ``StreamFn``.
    public var streamFn: StreamFn {
        { model, context, options in
            self.stream(model: model, context: context, options: options)
        }
    }
}
