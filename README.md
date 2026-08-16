# Notch Agent

> **Personal macOS AI Assistant living in the Notch & Menu Bar with sovereign web3 commerce on BNB Smart Chain (BSC) Testnet.**

Notch Agent combines a native macOS desktop shell (SwiftUI & AppKit) with a local TypeScript/Node.js agent runtime powered by [`@bnbagent/sdk`](https://github.com/bnb-chain/bnbagent-sdk).

---

## 🌟 Key Features

- 🖥️ **macOS Notch & Menu Bar UX**: Native floating HUD panel hugging the MacBook Notch, status item in the menu bar, Touch ID biometric authentication, and local notifications.
- 🔐 **Dual-Wallet Security Boundary**:
  - **User Wallet**: Stored in a local encrypted Web3 Keystore v3 with master keys in macOS Keychain. All transfers and PancakeSwap swaps require manual confirmation. Private keys are wiped from volatile memory immediately after signing (`memset_s`).
  - **Agent Wallet**: Autonomous wallet generated deterministically and funded by the user. Automatically authorizes and settles x402 payment challenges from its own allocated balance without user prompt.
- ⚡ **Zero-Port Secure IPC**: Bidirectional JSON-RPC 2.0 communication over standard Stdin/Stdout subprocess pipes. Zero listening TCP/WebSocket ports.
- 🌐 **BNB Chain Developer Kit Layer**:
  - **`@bnbagent/sdk`**: ERC-8004 identity registration/discovery and x402 payment client.
  - **ERC-8056 Scaled UI Amount**: Exact BigInt arithmetic formatting (`toUIAmount`, `fromUIAmount`, `balanceOfUI`).
  - **Ask AI & BNB MCP**: Read-only documentation search with verified markdown source citations.
  - **PancakeSwap V2 Router**: Live testnet swap quotes with slippage control and Touch ID signing.
  - **Agent Maker Mode**: Embedded HTTP 402 server with durable anti-replay protection.
  - **BNB Greenfield Storage**: Decentralized object storage & client-side AES-256 encrypted chat backups.
  - **Multi-Chain Network Switcher**: Dynamic runtime toggle between BSC Testnet (97), BSC Mainnet (56), opBNB Testnet (5611), and opBNB Mainnet (204).
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
# Start the agent runtime in daemon mode
pnpm --filter @notch/agent-runtime run start

# Launch the native macOS companion app
swift run --package-path apps/macos

# Package into a standalone macOS .app bundle
pnpm run bundle:app

# Package into a distributable macOS installer disk image (.dmg)
pnpm run bundle:dmg
```

---

## 🧪 Testing

```bash
# Run Vitest test suites (138 unit & integration tests)
pnpm test

# Run Swift Package Manager unit tests (31 test cases)
swift test --package-path apps/macos
```

---

## 📄 License
MIT License
