# Notch Agent

> **Personal macOS AI Assistant living in the Notch & Menu Bar with sovereign web3 commerce on BNB Smart Chain (BSC) Testnet.**

Notch Agent combines a native macOS desktop shell (SwiftUI & AppKit) with a local TypeScript/Node.js agent runtime built on [`ethers`](https://docs.ethers.org).

---

## 🌟 Key Features

- 🖥️ **macOS Notch & Menu Bar UX**: Native floating HUD panel hugging the MacBook Notch, status item in the menu bar, Touch ID biometric authentication, and local notifications.
- 🔐 **Dual-Wallet Security Boundary**:
  - **User Wallet**: Stored in a local encrypted Web3 Keystore v3 with master keys in macOS Keychain. All transfers and PancakeSwap swaps require manual confirmation. Private keys are wiped from volatile memory immediately after signing (`memset_s`).
  - **Agent Wallet**: Autonomous wallet generated deterministically and funded by the user. Automatically authorizes and settles x402 payment challenges from its own allocated balance without user prompt.
- ⚡ **Zero-Port Secure IPC**: Bidirectional JSON-RPC 2.0 communication over standard Stdin/Stdout subprocess pipes. Zero listening TCP/WebSocket ports.
- 🌐 **BNB Chain Capability Layer** (status per adapter):
  - **Real (RPC-backed)**: x402 payment settlement (agent wallet), ERC-8056 UI amounts, PancakeSwap V2 quotes + unsigned swap building (BSC Testnet), MPP HTTP 402 maker server with durable replay store, multi-chain network switching (97/56/5611/204), `wallet.sendRawTransaction` broadcast.
  - **Simulated (in-memory, integration pending)**: ERC-8004 identity registration/discovery and BNB Greenfield storage/chat backups — these adapters currently use local in-memory stores, not on-chain/network calls. "Ask AI" is a curated local BNB knowledge base.
  - Ask AI & BNB MCP: read-only documentation search with verified markdown source citations (local index).
- 🛑 **System Lifecycle & Kill Switch**: Automatically locks agent and purges session keys on screen lock (`com.apple.screenIsLocked`), display sleep, or manual kill switch toggle.

---

## 📂 Architecture & Monorepo Structure

```text
notch3/
├── apps/
│   └── macos/               # Native macOS App (Swift 6 / SwiftUI / AppKit)
│       ├── Sources/
│       │   ├── App/         # AppDelegate, LifecycleManager
│       │   ├── UI/          # NotchHUDView, ChatView, WalletView, QRReceiveView, Modal
│       │   ├── Security/    # KeychainService, TouchIDAuthenticator, UserKeystoreManager
│       │   └── IPC/         # AgentProcessRunner, JSONRPCClient
│       └── Tests/           # AppTests, IPCTests, SecurityTests, UITests
├── packages/
│   ├── shared-types/        # Shared JSON-RPC 2.0 schemas & TypeScript DTOs
│   └── agent-runtime/       # Local Node.js Agent Runtime (@bnbagent/sdk & tool loop)
├── tests/
│   ├── mocks/               # Mock x402 HTTP server
│   └── integration/         # Cross-subsystem End-to-End integration suite
└── docs/superpowers/
    ├── specs/               # Architecture & design specifications
    └── plans/               # Bite-sized implementation plans
```

---

## 🚀 Getting Started

### Prerequisites
- macOS Sonoma (14.0) or later
- Xcode 15+ / Swift 5.10+
- Node.js v20+ & pnpm v9+

### Installation & Build

```bash
# 1. Install workspace dependencies
pnpm install

# 2. Build TypeScript packages
pnpm run build

# 3. Run all tests (Vitest + Swift Testing)
pnpm test
swift test --package-path apps/macos
```

### Running Locally & Packaging

```bash
# Start the agent runtime as a standalone daemon (JSON-RPC 2.0 on stdin/stdout)
pnpm --filter @notch/agent-runtime run start

# Launch the native macOS app
# (the app locates Node + dist/daemon.js itself and spawns the runtime)
swift run --package-path apps/macos

# Package into a standalone macOS .app bundle
pnpm run bundle:app

# Package into a distributable macOS installer disk image (.dmg)
pnpm run bundle:dmg
```

---

## 🧪 Testing

```bash
# Run Vitest test suites (336 unit & integration tests, deterministic — no live chain calls)
pnpm test

# Build & link the Swift test bundle
# (executing the Swift Testing suite requires Xcode's xctest runner)
swift test --package-path apps/macos
```

---

## 📄 License
MIT License
