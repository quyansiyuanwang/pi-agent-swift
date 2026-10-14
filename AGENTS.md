# Project context — pi-agent-swift

- GitHub: https://github.com/quyansiyuanwang/pi-agent-swift
- Product / target: `PiAgentCore` (Swift package)
- **Owner username: `quyansiyuanwang`.** Use it in every URL, badge, and
  `Package.swift` example. Never write `<owner>` or any other placeholder.
- Native Swift port of upstream `@earendil-works/pi-agent-core`. Depends on
  `pi-ai-swift` (product `PiAI`). Keep attribution in `ATTRIBUTION.md` and the
  porting map in `docs/PORTING.md`.
- Zero third-party dependencies beyond `pi-ai-swift`. Swift 6 strict concurrency,
  zero warnings.
- Tests use Swift Testing (`@Suite` / `@Test` / `#expect`).
- `.tmp/pi` is a symlink to the upstream TypeScript reference; it is gitignored and
  must never be committed.
