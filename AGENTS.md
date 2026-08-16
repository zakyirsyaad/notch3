# AGENTS.md — Notch Agent workspace guide

Personal macOS AI assistant living in the MacBook notch/menu bar (Swift/SwiftUI/AppKit shell) with sovereign web3 commerce on BNB Smart Chain, powered by a local TypeScript/Node.js agent runtime. The two halves communicate exclusively via newline-delimited JSON-RPC 2.0 over stdin/stdout pipes — zero TCP/WebSocket ports.

## Layout

- `apps/macos/` — Native Swift package. Library `NotchAgentCore` at `Sources/NotchAgentCore` (`App/` AppDelegate+LifecycleManager, `UI/`, `Security/` incl. `Crypto/` EIP-155 signer, `IPC/` incl. `AgentProcessRunner`, `JSONRPCClient`, `TransactionPipeline`), executable `NotchAgent` at `Sources/NotchAgentMain`. Tests in `apps/macos/Tests/{AppTests,IPCTests,SecurityTests,UITests}`.
- `packages/shared-types/` — `@notch/shared-types`: all JSON-RPC 2.0 schemas and DTOs shared by both sides.
- `packages/agent-runtime/` — `@notch/agent-runtime`: RPC dispatcher, agent tool loop, agent wallet/session, BNB SDK adapters (ERC-8004, ERC-8056, x402, PancakeSwap, Greenfield, Ask AI, network switcher), MPP HTTP 402 server.
- `tests/` — cross-subsystem integration tests (`tests/integration/`) and `tests/mocks/mock-x402-server.ts` for deterministic payment tests.
- `scripts/build-macos-app.sh` / `build-macos-dmg.sh` — package the Swift shell plus copied `packages/*/dist` output into `build/NotchAgent.app` / `.dmg`.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design specs and implementation plans per phase. `ARCHITECTURE_PLAN.md` (root) is the master plan, written in Indonesian.

## Commands

```bash
pnpm install                          # workspace deps (pnpm v9+, Node 20+)
pnpm run build                        # tsc -b for packages/* (required before swift run / bundling)
pnpm test                             # root Vitest: packages/*/tests + tests/ (30s timeout, node env)
pnpm run test:packages                # per-package Vitest
pnpm run test:e2e                     # only tests/ (cross-subsystem integration)
pnpm run lint                         # = tsc --noEmit per package (no ESLint configured)
swift test --package-path apps/macos  # Swift unit tests (Xcode 15+/Swift 5.10, macOS 14+)
swift run --package-path apps/macos   # launch native shell
pnpm run bundle:app                   # standalone .app bundle into build/
pnpm run bundle:dmg                   # distributable .dmg
```

## Architecture boundaries (do not break)

- **Dual-wallet trust boundary**: the agent runtime only ever holds the *agent* wallet. The *user* wallet lives in the Swift shell (Keychain + Touch ID, manual confirmation per transfer/swap). Never give the runtime access to user-wallet keys or add automated signing for it.
- **Secrets hygiene**: seed phrases, private keys, and API keys must never reach the AI model, logs, or Greenfield uploads. Use `safeLog`/`redactSecrets` from `packages/agent-runtime/src/utils/redact.ts` for all runtime logging.
- **stdout is the RPC channel**: in runtime code, log only via `safeLog` (writes to stderr). Never `console.log` — it corrupts the JSON-RPC stream the Swift parent is reading.
- **IPC contract changes** require three synchronized edits: types in `packages/shared-types/src/`, method registration in `createAgentDispatcher` (`packages/agent-runtime/src/index.ts`, currently ~26 methods: `agent.*`, `wallet.*`, `mpp.*`, `greenfield.*`, `network.*`), and the Swift mirror in `apps/macos/Sources/NotchAgentCore/IPC/{JSONRPCClient,Models}.swift`. The Swift `AgentStatus`/`AgentConfig` models must match the runtime's actual JSON field names (e.g. `lockState`, `balance`, `openaiApiKey`).
- **Money math**: token amounts are BigInt/strings end-to-end. Use ERC-8056 UI-amount conversion (`toUIAmount`/`fromUIAmount`/`balanceOfUI`) for display and convert back to raw amounts before building transactions.
- **Lifecycle**: screen lock (`com.apple.screenIsLocked`), display sleep, or the kill switch must lock the agent session and purge keys — see `LifecycleManager.swift` and `wallet/session.ts`.

## TypeScript conventions

- ESM everywhere (`"type": "module"`), `module: NodeNext`, `strict: true`, target ES2022. Relative imports **must** use `.js` extensions (e.g. `./rpc/dispatcher.js`) — NodeNext requirement.
- Cross-package imports use `@notch/shared-types` (wired via `workspace:*` in pnpm and aliased to `src/` in `vitest.config.ts`, so tests run against source without building).
- Package entry points export from `src/index.ts` only; consumers import the package root, not deep paths.

## Gotchas

- The agent runtime daemon entrypoint is `packages/agent-runtime/src/daemon.ts` (built to `dist/daemon.js`). `swift run --package-path apps/macos` spawns it via `AgentProcessRunner` — Node binary is located via `NOTCH_NODE_BIN` (fallback: homebrew paths), script via `NOTCH_RUNTIME_SCRIPT` (fallback: bundle Resources or the repo checkout). Always `pnpm run build` before `swift run`/bundling so `dist/daemon.js` exists.
- Swift test targets use `.unsafeFlags` pointing at `/Library/Developer/CommandLineTools/...` framework paths (`apps/macos/Package.swift`) — build failures there are usually toolchain-path related, not code. On CommandLineTools-only machines `swift test` builds and links the Swift Testing bundle but cannot *execute* it (needs Xcode's `xctest` runner); use `swift build` to validate compilation.
- Default network is BSC Testnet (chainId 97); runtime network switching supports 97/56 (BSC mainnet)/5611/204 (opBNB). Tests are deterministic via the mock x402 server — don't add tests that hit live testnet services in unit suites.
- Before changing wallet/IPC/MPP/Greenfield/x402 behavior, read the relevant spec in `docs/superpowers/specs/` — each phase (core, PancakeSwap+MPP, ecosystem) has a design doc that the tests encode.
