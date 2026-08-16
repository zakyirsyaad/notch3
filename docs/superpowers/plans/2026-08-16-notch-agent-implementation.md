# Notch Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Notch Agent — a native macOS companion (SwiftUI/AppKit in Notch and Menu Bar) with a local TypeScript/Node.js agent runtime on BSC Testnet (Chain ID 97), featuring a dual-wallet security model, zero-port Stdin/Stdout JSON-RPC 2.0 IPC, `@bnbagent/sdk` ERC-8004 & x402 payments, ERC-8056 Scaled UI Amount formatting, and read-only BNB Ask AI knowledge queries.

**Architecture:** A modular monorepo containing `apps/macos` (SwiftUI/AppKit shell managing UI, Touch ID, Keychain, and User Keystore manual signing) and `packages/agent-runtime` (Node.js daemon running `@bnbagent/sdk`, x402 client, BSC Testnet provider, and AI tool loop) communicating via line-delimited JSON-RPC 2.0 over Stdin/Stdout pipes.

**Tech Stack:** 
- Native macOS: Swift 5.10+, SwiftUI, AppKit, LocalAuthentication (Touch ID), Security (Keychain Services), SQLite3 / GRDB.
- Agent Runtime: Node.js (v20+), TypeScript, `@bnbagent/sdk`, `ethers` v6 / `viem`, `zod`, `dotenv`.
- Protocol: JSON-RPC 2.0 over Stdin/Stdout.

---

## Global Constraints

- **BSC Testnet Target:** Chain ID `97`, RPC `https://data-seed-prebsc-1-s1.binance.org:8545/`.
- **Dual-Wallet Boundary:** User Wallet keys must NEVER enter the Node.js runtime. User actions require manual UI confirmation. Agent Wallet is auto-signing for x402 payments only, bounded strictly by its own allocated balance.
- **Zero-Port IPC:** Communication between Swift and Node.js must exclusively use Stdin/Stdout pipes. No local TCP/WebSocket listening ports.
- **ERC-8056 Compliance:** All token amount displays and inputs must handle scaling via `toUIAmount` and `fromUIAmount`.
- **Read-Only Ecosystem MCP:** External ecosystem MCP tools must have write operations stripped; Ask AI queries must include source citation URLs.
- **Screen Lock Security:** Any screen lock (`com.apple.screenIsLocked`) or display sleep must immediately trigger agent lock and clear signing keys from memory.

---

## Task Decomposition & Execution Plan

### Task 1: Monorepo Root & Workspace Setup

**Files:**
- Create: `package.json`
- Create: `pnpm-workspace.yaml`
- Create: `tsconfig.base.json`
- Create: `.gitignore`

**Interfaces:**
- Produces: Root monorepo configuration supporting `packages/*` and `apps/*`.

- [ ] **Step 1: Write root package.json and workspace configuration**

```json
{
  "name": "notch-agent-monorepo",
  "private": true,
  "scripts": {
    "build": "pnpm --filter \"./packages/*\" run build",
    "test": "pnpm --filter \"./packages/*\" run test",
    "lint": "pnpm --filter \"./packages/*\" run lint"
  },
  "devDependencies": {
    "typescript": "^5.4.5",
    "vitest": "^1.6.0"
  }
}
```

- [ ] **Step 2: Create pnpm-workspace.yaml and tsconfig.base.json**

```yaml
packages:
  - 'packages/*'
  - 'apps/*'
```

- [ ] **Step 3: Create .gitignore**

Include `node_modules`, `dist`, `.build`, `.DS_Store`, `*.keystore`, `.env`.

- [ ] **Step 4: Verify monorepo scaffolding**

Run: `git status`
Expected: Monorepo configuration files tracked.

- [ ] **Step 5: Commit**

```bash
git add package.json pnpm-workspace.yaml tsconfig.base.json .gitignore
git commit -m "chore: initialize monorepo workspace structure"
```

---

### Task 2: Shared Types Package (`packages/shared-types`)

**Files:**
- Create: `packages/shared-types/package.json`
- Create: `packages/shared-types/tsconfig.json`
- Create: `packages/shared-types/src/index.ts`
- Create: `packages/shared-types/src/rpc.ts`
- Create: `packages/shared-types/src/wallet.ts`
- Create: `packages/shared-types/src/agent.ts`
- Test: `packages/shared-types/tests/rpc-types.test.ts`

**Interfaces:**
- Produces:
  - `JSONRPCRequest<T>`, `JSONRPCResponse<T>`, `JSONRPCNotification<T>`, `JSONRPCError`
  - `AgentConfig`, `AgentStatus`, `AgentLockState`
  - `X402PaymentChallenge`, `X402PaymentReceipt`
  - `TokenBalance`, `ERC8056Metadata`

- [ ] **Step 1: Write the failing type serialization test**

```typescript
// packages/shared-types/tests/rpc-types.test.ts
import { describe, it, expect } from 'vitest';
import { isJSONRPCRequest, isJSONRPCResponse } from '../src/rpc';

describe('JSON-RPC Type Guards', () => {
  it('correctly validates a valid JSON-RPC 2.0 request', () => {
    const req = { jsonrpc: '2.0', id: '1', method: 'agent.getStatus', params: {} };
    expect(isJSONRPCRequest(req)).toBe(true);
  });

  it('rejects invalid JSON-RPC payloads', () => {
    const invalid = { id: '1', method: 'test' };
    expect(isJSONRPCRequest(invalid)).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/shared-types test`
Expected: FAIL (types and guards not yet implemented).

- [ ] **Step 3: Implement shared types and type guards**

Create `src/rpc.ts`, `src/wallet.ts`, `src/agent.ts`, and re-export in `src/index.ts`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/shared-types test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/shared-types
git commit -m "feat(shared-types): implement JSON-RPC 2.0 and agent data schemas"
```

---

### Task 3: Agent Runtime Core & Stdin/Stdout JSON-RPC Dispatcher (`packages/agent-runtime`)

**Files:**
- Create: `packages/agent-runtime/package.json`
- Create: `packages/agent-runtime/tsconfig.json`
- Create: `packages/agent-runtime/src/rpc/dispatcher.ts`
- Create: `packages/agent-runtime/src/rpc/transport.ts`
- Create: `packages/agent-runtime/src/index.ts`
- Test: `packages/agent-runtime/tests/rpc-dispatcher.test.ts`

**Interfaces:**
- Consumes: `@notch/shared-types` (JSON-RPC contracts).
- Produces: `RPCDispatcher.registerMethod(name, handler)`, `RPCTransport.start()`, `RPCTransport.sendNotification(method, params)`.

- [ ] **Step 1: Write failing RPC dispatcher test**

```typescript
// packages/agent-runtime/tests/rpc-dispatcher.test.ts
import { describe, it, expect } from 'vitest';
import { RPCDispatcher } from '../src/rpc/dispatcher';

describe('RPCDispatcher', () => {
  it('dispatches registered methods and returns formatted JSON-RPC response', async () => {
    const dispatcher = new RPCDispatcher();
    dispatcher.registerMethod('ping', async (params) => ({ pong: true }));

    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', id: 'test-1', method: 'ping', params: {} })
    );

    const parsed = JSON.parse(res!);
    expect(parsed.result).toEqual({ pong: true });
    expect(parsed.id).toBe('test-1');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: FAIL.

- [ ] **Step 3: Implement RPCDispatcher and Stdin/Stdout Transport**

Implement newline-delimited JSON stream reader with `readline` on `process.stdin` and formatted output on `process.stdout`. Add secret redaction filter for logging.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/agent-runtime/src/rpc packages/agent-runtime/tests
git commit -m "feat(agent-runtime): implement Stdin/Stdout JSON-RPC 2.0 dispatcher"
```

---

### Task 4: Agent Wallet & Keystore Management (`packages/agent-runtime/src/wallet/`)

**Files:**
- Create: `packages/agent-runtime/src/wallet/keystore.ts`
- Create: `packages/agent-runtime/src/wallet/session.ts`
- Test: `packages/agent-runtime/tests/keystore.test.ts`

**Interfaces:**
- Produces:
  - `generateAgentKeystore(passphrase: string): Promise<{ address: string; keystoreJson: string }>`
  - `AgentSession.unlock(keystoreJson: string, passphrase: string): Promise<string>`
  - `AgentSession.lock(): void`
  - `AgentSession.getSigner(): ethers.Wallet`

- [ ] **Step 1: Write failing keystore & session test**

```typescript
// packages/agent-runtime/tests/keystore.test.ts
import { describe, it, expect } from 'vitest';
import { generateAgentKeystore, AgentSession } from '../src/wallet';

describe('Agent Keystore & Session', () => {
  it('creates encrypted keystore and unlocks signer in session', async () => {
    const mockAuthKey = 'example-user-input-key';
    const { address, keystoreJson } = await generateAgentKeystore(mockAuthKey);
    expect(address).toMatch(/^0x[a-fA-F0-9]{40}$/);

    const session = new AgentSession();
    expect(session.isUnlocked()).toBe(false);

    await session.unlock(keystoreJson, mockAuthKey);
    expect(session.isUnlocked()).toBe(true);
    expect(session.getAddress()).toBe(address);

    session.lock();
    expect(session.isUnlocked()).toBe(false);
    expect(() => session.getSigner()).toThrow(/Agent wallet is locked/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: FAIL.

- [ ] **Step 3: Implement Web3 v3 Keystore and AgentSession**

Implement AES-GCM / PBKDF2 Web3 v3 keystore format using `ethers.Wallet.encrypt` / `fromEncryptedJson` with memory zeroing on `.lock()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/agent-runtime/src/wallet packages/agent-runtime/tests/keystore.test.ts
git commit -m "feat(agent-runtime): implement agent keystore encryption and session lifecycle"
```

---

### Task 5: BNB Chain Provider & ERC-8056 Scaled UI Amount Adapter

**Files:**
- Create: `packages/agent-runtime/src/bnb/provider.ts`
- Create: `packages/agent-runtime/src/bnb/erc8056.ts`
- Test: `packages/agent-runtime/tests/erc8056.test.ts`

**Interfaces:**
- Produces:
  - `getBSCProvider(rpcUrl?: string): ethers.JsonRpcProvider`
  - `toUIAmount(rawAmount: bigint, decimals: number, multiplier?: bigint): string`
  - `fromUIAmount(uiAmount: string, decimals: number, multiplier?: bigint): bigint`
  - `fetchTokenScaledBalance(tokenAddress: string, walletAddress: string): Promise<TokenBalance>`

- [ ] **Step 1: Write failing ERC-8056 math and conversion tests**

```typescript
// packages/agent-runtime/tests/erc8056.test.ts
import { describe, it, expect } from 'vitest';
import { toUIAmount, fromUIAmount } from '../src/bnb/erc8056';

describe('ERC-8056 Scaled UI Amount conversion', () => {
  it('correctly converts standard 18 decimal token without multiplier', () => {
    const raw = 1500000000000000000n; // 1.5 ether
    expect(toUIAmount(raw, 18)).toBe('1.5');
    expect(fromUIAmount('1.5', 18)).toBe(raw);
  });

  it('correctly applies custom scaling multiplier for ERC-8056 token', () => {
    // 6 decimals, multiplier = 2x (e.g. 2 * 10^6)
    const raw = 1000000n;
    const multiplier = 2000000n; // 2.0x scale
    expect(toUIAmount(raw, 6, multiplier)).toBe('2');
    expect(fromUIAmount('2', 6, multiplier)).toBe(raw);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: FAIL.

- [ ] **Step 3: Implement BSC Provider and ERC-8056 Scaler logic**

Implement precise BigInt arithmetic conversion avoiding float precision loss.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/agent-runtime/src/bnb packages/agent-runtime/tests/erc8056.test.ts
git commit -m "feat(agent-runtime): implement BSC provider and ERC-8056 token scaler"
```

---

### Task 6: `@bnbagent/sdk` ERC-8004 Identity & x402 Payment Client

**Files:**
- Create: `packages/agent-runtime/src/bnb/bnb-sdk.ts`
- Create: `packages/agent-runtime/src/bnb/x402-client.ts`
- Create: `packages/agent-runtime/src/bnb/erc8004.ts`
- Test: `packages/agent-runtime/tests/x402-client.test.ts`

**Interfaces:**
- Consumes: `AgentSession` (for signing txs), `getBSCProvider`.
- Produces:
  - `parseX402Challenge(headers: Record<string, string>, body?: any): X402PaymentChallenge`
  - `executeX402Payment(challenge: X402PaymentChallenge, session: AgentSession): Promise<X402PaymentReceipt>`
  - `registerAgentIdentity(metadata: { name: string; description: string }): Promise<string>`

- [ ] **Step 1: Write failing x402 challenge parsing & payment test**

```typescript
// packages/agent-runtime/tests/x402-client.test.ts
import { describe, it, expect } from 'vitest';
import { parseX402Challenge } from '../src/bnb/x402-client';

describe('x402 Payment Client', () => {
  it('parses standard 402 Payment Required response challenge', () => {
    const headers = {
      'www-authenticate': 'x402 token="tBNB", amount="0.001", recipient="0x1111111111111111111111111111111111111111", chainId="97"'
    };
    const challenge = parseX402Challenge(headers);
    expect(challenge.amount).toBe('0.001');
    expect(challenge.token).toBe('tBNB');
    expect(challenge.chainId).toBe(97);
    expect(challenge.recipient).toBe('0x1111111111111111111111111111111111111111');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: FAIL.

- [ ] **Step 3: Implement x402 challenge parser and payment execution using @bnbagent/sdk**

Integrate BSC Testnet transaction generation, balance pre-check, and tx broadcast.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/agent-runtime/src/bnb/x402-client.ts packages/agent-runtime/src/bnb/erc8004.ts packages/agent-runtime/tests/x402-client.test.ts
git commit -m "feat(agent-runtime): implement x402 payment challenge parsing and settlement"
```

---

### Task 7: Read-Only BNB Documentation & Ask AI Adapter

**Files:**
- Create: `packages/agent-runtime/src/bnb/ask-ai.ts`
- Test: `packages/agent-runtime/tests/ask-ai.test.ts`

**Interfaces:**
- Produces: `queryBNBDocumentation(query: string): Promise<{ answer: string; citations: string[] }>`

- [ ] **Step 1: Write failing doc search & citation test**

```typescript
// packages/agent-runtime/tests/ask-ai.test.ts
import { describe, it, expect } from 'vitest';
import { sanitizeBNBResponse } from '../src/bnb/ask-ai';

describe('Ask AI & BNB Documentation Adapter', () => {
  it('formats citations and ensures write-operations are blocked', () => {
    const rawAnswer = "To deploy on BSC Testnet, use chainId 97.";
    const sources = ["https://docs.bnbchain.org/docs/testnet/"];
    const formatted = sanitizeBNBResponse(rawAnswer, sources);
    expect(formatted.answer).toContain(rawAnswer);
    expect(formatted.citations[0]).toBe("https://docs.bnbchain.org/docs/testnet/");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: FAIL.

- [ ] **Step 3: Implement Ask AI adapter with strict read-only tool filtering**

Filter out any modifying tool calls and inject markdown citations.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/agent-runtime/src/bnb/ask-ai.ts packages/agent-runtime/tests/ask-ai.test.ts
git commit -m "feat(agent-runtime): implement read-only Ask AI BNB ecosystem knowledge adapter"
```

---

### Task 8: AI Tool Loop & Agent Prompt Executor (`packages/agent-runtime/src/agent/`)

**Files:**
- Create: `packages/agent-runtime/src/agent/loop.ts`
- Create: `packages/agent-runtime/src/agent/tools.ts`
- Test: `packages/agent-runtime/tests/agent-loop.test.ts`

**Interfaces:**
- Consumes: `AgentSession`, `x402Client`, `askAI`.
- Produces: `AgentExecutor.executePrompt(prompt: string, streamCb?: (chunk: string) => void): Promise<AgentExecutionResult>`.

- [ ] **Step 1: Write failing tool loop executor test**

```typescript
// packages/agent-runtime/tests/agent-loop.test.ts
import { describe, it, expect } from 'vitest';
import { AgentExecutor } from '../src/agent/loop';

describe('AgentExecutor Tool Loop', () => {
  it('dispatches registered tools based on tool call requests', async () => {
    const executor = new AgentExecutor({ apiKey: 'mock-key' });
    executor.registerTool('get_balance', async () => ({ balance: '0.05 tBNB' }));
    
    const res = await executor.runTool('get_balance', {});
    expect(res).toEqual({ balance: '0.05 tBNB' });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: FAIL.

- [ ] **Step 3: Implement OpenAI-compatible tool loop with tool definitions**

Register tools: `pay_x402_service`, `check_agent_balance`, `query_bnb_docs`, `discover_erc8004_agents`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @notch/agent-runtime test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/agent-runtime/src/agent packages/agent-runtime/tests/agent-loop.test.ts
git commit -m "feat(agent-runtime): implement AI tool loop and execution engine"
```

---

### Task 9: Native macOS Shell - Swift Package & Subprocess IPC Runner

**Files:**
- Create: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/IPC/AgentProcessRunner.swift`
- Create: `apps/macos/Sources/IPC/JSONRPCClient.swift`
- Create: `apps/macos/Sources/IPC/Models.swift`
- Test: `apps/macos/Tests/IPCTests/JSONRPCClientTests.swift`

**Interfaces:**
- Produces:
  - `AgentProcessRunner.start(nodeBinaryPath: String, scriptPath: String) throws`
  - `JSONRPCClient.sendRequest<T, R>(method: String, params: T) async throws -> R`
  - `JSONRPCClient.onNotification(method: String, handler: @escaping (Data) -> Void)`

- [ ] **Step 1: Write failing Swift JSON-RPC Client tests**

```swift
// apps/macos/Tests/IPCTests/JSONRPCClientTests.swift
import XCTest
@testable import NotchAgentCore

final class JSONRPCClientTests: XCTestCase {
    func testRequestSerialization() throws {
        let client = JSONRPCClient()
        let requestData = try client.encodeRequest(id: "1", method: "agent.getStatus", params: EmptyParams())
        let jsonString = String(data: requestData, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(jsonString.contains("\"method\":\"agent.getStatus\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/macos`
Expected: FAIL.

- [ ] **Step 3: Implement Swift JSONRPCClient and AgentProcessRunner**

Use `Foundation.Process`, `Pipe` for standard input and standard output, and structured `async/await` request-response matching by ID.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/macos`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "feat(macos): implement Swift Package and JSON-RPC Stdin/Stdout subprocess runner"
```

---

### Task 10: macOS Security Layer & User Keystore Custody

**Files:**
- Create: `apps/macos/Sources/Security/KeychainService.swift`
- Create: `apps/macos/Sources/Security/TouchIDAuthenticator.swift`
- Create: `apps/macos/Sources/Security/UserKeystoreManager.swift`
- Test: `apps/macos/Tests/SecurityTests/KeystoreSecurityTests.swift`

**Interfaces:**
- Produces:
  - `KeychainService.saveSecret(key: String, data: Data) throws`
  - `KeychainService.loadSecret(key: String) throws -> Data?`
  - `TouchIDAuthenticator.authenticateUser(reason: String) async throws -> Bool`
  - `UserKeystoreManager.importSeedPhrase(mnemonic: String, password: String) throws -> String`
  - `UserKeystoreManager.signTransaction(txData: Data, password: String) throws -> Data`

- [ ] **Step 1: Write failing Keystore security tests**

```swift
// apps/macos/Tests/SecurityTests/KeystoreSecurityTests.swift
import XCTest
@testable import NotchAgentCore

final class KeystoreSecurityTests: XCTestCase {
    func testKeystoreSeparationAndZeroing() throws {
        let manager = UserKeystoreManager()
        // Ensure private key is not retained in memory after signing
        XCTAssertNil(manager.inMemoryPrivateKey)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/macos`
Expected: FAIL.

- [ ] **Step 3: Implement KeychainService and UserKeystoreManager**

Implement `kSecClassGenericPassword` with `kSecAccessControlBiometryAny` access control and explicit in-memory wiping.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/macos`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Security apps/macos/Tests/SecurityTests
git commit -m "feat(macos): implement macOS Keychain integration and secure User Keystore custody"
```

---

### Task 11: Native macOS UI - Notch HUD Panel & Menu Bar

**Files:**
- Create: `apps/macos/Sources/UI/NotchHUDView.swift`
- Create: `apps/macos/Sources/UI/MenuBarController.swift`
- Create: `apps/macos/Sources/UI/NotchWindowController.swift`

**Interfaces:**
- Produces:
  - `MenuBarController.setupStatusItem()`
  - `NotchWindowController.toggleNotchPanel()`
  - `NotchHUDView`: SwiftUI View showing status pill, agent balance, quick pause button, and drawer navigation.

- [ ] **Step 1: Write SwiftUI View structure for NotchHUDView**

Implement NotchHUD with status indicator (🟢 Active / ⏸️ Paused / 🔒 Locked), balance chip (`0.05 tBNB`), quick toggle, and chat/wallet tabs.

- [ ] **Step 2: Implement MenuBarController & NotchWindowController**

Implement borderless `NSPanel` floating window positioned under the MacBook Notch (or top center screen fallback).

- [ ] **Step 3: Verify preview & compilation**

Run: `swift build --package-path apps/macos`
Expected: Build SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/UI/NotchHUDView.swift apps/macos/Sources/UI/MenuBarController.swift apps/macos/Sources/UI/NotchWindowController.swift
git commit -m "feat(macos): implement Notch HUD panel and Menu Bar status item"
```

---

### Task 12: Native macOS UI - Chat, Wallet & Manual Confirmation Modal

**Files:**
- Create: `apps/macos/Sources/UI/ChatView.swift`
- Create: `apps/macos/Sources/UI/WalletView.swift`
- Create: `apps/macos/Sources/UI/TransactionConfirmationModal.swift`
- Create: `apps/macos/Sources/UI/QRReceiveView.swift`

**Interfaces:**
- Produces:
  - `ChatView`: AI chat stream with markdown citations and x402 payment receipt cards.
  - `WalletView`: Balance cards (BNB + ERC-20 with ERC-8056 formatting), transaction history, Fund Agent button.
  - `TransactionConfirmationModal`: Touch ID confirmation sheet for User Wallet manual transfers & swaps.

- [ ] **Step 1: Write ChatView and WalletView SwiftUI views**

Implement interactive chat message feed, markdown rendering, token balances with ERC-8056 format, and QR receive sheet.

- [ ] **Step 2: Implement TransactionConfirmationModal**

Implement manual confirmation sheet requiring explicit biometric (Touch ID) or password prompt before invoking `UserKeystoreManager.signTransaction`.

- [ ] **Step 3: Verify build**

Run: `swift build --package-path apps/macos`
Expected: Build SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/UI/ChatView.swift apps/macos/Sources/UI/WalletView.swift apps/macos/Sources/UI/TransactionConfirmationModal.swift apps/macos/Sources/UI/QRReceiveView.swift
git commit -m "feat(macos): implement Chat, Wallet, QR Receive, and User Confirmation Modal UI"
```

---

### Task 13: System Lifecycle, Screen Lock & Kill Switch

**Files:**
- Create: `apps/macos/Sources/App/LifecycleManager.swift`
- Create: `apps/macos/Sources/App/AppDelegate.swift`
- Test: `apps/macos/Tests/AppTests/LifecycleManagerTests.swift`

**Interfaces:**
- Produces: `LifecycleManager.startMonitoring()`, `LifecycleManager.triggerKillSwitch()`.

- [ ] **Step 1: Write failing screen lock lifecycle test**

```swift
// apps/macos/Tests/AppTests/LifecycleManagerTests.swift
import XCTest
@testable import NotchAgentCore

final class LifecycleManagerTests: XCTestCase {
    func testScreenLockTriggersAgentLock() async {
        let runner = MockAgentProcessRunner()
        let manager = LifecycleManager(processRunner: runner)
        manager.handleScreenLockEvent()
        XCTAssertTrue(runner.lockIssued)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/macos`
Expected: FAIL.

- [ ] **Step 3: Implement LifecycleManager and AppDelegate notification listeners**

Subscribe to `NSDistributedNotificationCenter` for `com.apple.screenIsLocked` and `screensDidSleepNotification`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/macos`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/App apps/macos/Tests/AppTests
git commit -m "feat(macos): implement screen lock, display sleep lifecycle handler and kill switch"
```

---

### Task 14: End-to-End Mock Integration & Verification Suite

**Files:**
- Create: `tests/mocks/mock-x402-server.ts`
- Create: `tests/integration/e2e-flow.test.ts`

**Interfaces:**
- Produces: Mock HTTP 402 server serving paid agent API endpoints and full integration test verifying IPC, x402 challenge, payment, and receipt generation.

- [ ] **Step 1: Write Mock x402 Server**

```typescript
// tests/mocks/mock-x402-server.ts
import http from 'http';

export function createMockX402Server(port: number) {
  return http.createServer((req, res) => {
    const authHeader = req.headers['authorization'];
    if (!authHeader || !authHeader.startsWith('Bearer 0x')) {
      res.writeHead(402, {
        'WWW-Authenticate': 'x402 token="tBNB", amount="0.001", recipient="0x1111111111111111111111111111111111111111", chainId="97"',
        'Content-Type': 'application/json'
      });
      res.end(JSON.stringify({ error: 'Payment Required' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: true, data: 'Premium Forecast Data' }));
  });
}
```

- [ ] **Step 2: Write End-to-End integration test**

Verify agent runtime startup -> wallet unlock -> x402 challenge receive -> auto tx settlement -> successful data retrieval.

- [ ] **Step 3: Run E2E test suite**

Run: `pnpm test`
Expected: ALL PASS.

- [ ] **Step 4: Commit**

```bash
git add tests
git commit -m "test(e2e): add mock x402 server and end-to-end integration test suite"
```
