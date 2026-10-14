# Attribution

PiAgentCore is a native Swift port of [`@earendil-works/pi-agent-core`](https://github.com/earendil-works/pi),
version **1.2.0**.

- Upstream package: `@earendil-works/pi-agent-core` (npm)
- Upstream source: [`packages/agent/src`](https://github.com/earendil-works/pi/tree/main/packages/agent/src)
- Upstream version ported: **1.2.0**
- Upstream license: **MIT**
- Upstream copyright: **Copyright (c) 2025 Mario Zechner**

The Swift sources mirror the structure and behavior of the upstream
TypeScript files listed in [`docs/PORTING.md`](docs/PORTING.md). Where a direct
port was not possible — Swift value semantics, an actor instead of a mutable
class, the simplified public contract defined by `TASK.md`, and no runtime
dependency on Node.js — the deviation is documented there.

PiAgentCore depends on [`PiAI`](../pi-ai-swift), the Swift port of
`@earendil-works/pi-ai`, for `Model`, `ChatProvider`, `AssistantMessageEvent`,
messages, tools and `JSONValue` / `JSONSchema`.

## Upstream license

The upstream project is distributed under the MIT License. Its license text is
reproduced verbatim below and its copyright notice is retained in this
repository's [`LICENSE`](LICENSE).

```
MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Scope

Only the agent runtime subset required to run a tool loop over a
`ChatProvider` is ported: transcript state, the tool loop, lifecycle events,
cooperative cancellation and the `beforeToolCall` / `afterToolCall` hooks.
Steering / follow-up queues, turn-level events, context transforms, model
fallbacks, session resources, `proxy.ts` and the CLI are intentionally out of
scope. See [`docs/PORTING.md`](docs/PORTING.md) for the file-by-file mapping.
