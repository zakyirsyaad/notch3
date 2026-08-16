# Notch Agent Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase 2 features for Notch Agent: live PancakeSwap Swap Router adapter on BSC Testnet 97 with slippage & Touch ID confirmation, and Agent Maker Mode (embedded HTTP 402 server with on-chain settlement verification and durable double-spend replay protection).

**Architecture:** Extend `@notch/shared-types`, `@notch/agent-runtime` (`src/bnb/pancakeswap.ts` and `src/mpp/`), expose new JSON-RPC methods, build SwiftUI `SwapView` & `MakerModeDashboardView`, and integrate full E2E cross-agent commerce tests.

**Tech Stack:** TypeScript, `@bnbagent/sdk`, `ethers` v6, Node.js HTTP, SwiftUI/AppKit, Vitest, Swift Testing.

---

## Global Constraints

- **BSC Testnet Target:** Chain ID `97`.
- **PancakeSwap Router v2 (Testnet):** `0xD99D1c33F9fC3444f8101754aBC46c52416550D1`.
- **User Wallet Exclusivity for Swaps:** The Agent Wallet must NEVER sign user token swaps. Swaps produce unsigned transaction payloads for the native Swift User Wallet.
- **Durable Replay Protection:** The MPP server must record redeemed `txHash`es in `MPPReplayStore` and reject any duplicate transaction hashes with HTTP `403 Forbidden`.
- **Zero Flakiness:** All integration and mock tests must run reliably offline using ephemeral ports and mock contracts/servers.

---

## Task Decomposition

### Task 1: Shared Types Expansion (`packages/shared-types`)

**Files:**
- Modify: `packages/shared-types/src/wallet.ts`
- Create: `packages/shared-types/src/mpp.ts`
- Modify: `packages/shared-types/src/index.ts`
- Test: `packages/shared-types/tests/phase2-types.test.ts`

- [ ] **Step 1: Write failing type validation tests**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement swap and MPP interfaces and type guards**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(shared-types): add PancakeSwap and MPP Maker Mode schemas`)**

---

### Task 2: PancakeSwap Router Adapter (`packages/agent-runtime/src/bnb/`)

**Files:**
- Create: `packages/agent-runtime/src/bnb/pancakeswap.ts`
- Modify: `packages/agent-runtime/src/bnb/index.ts`
- Test: `packages/agent-runtime/tests/pancakeswap.test.ts`

- [ ] **Step 1: Write failing PancakeSwap quote & tx builder tests**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement `estimateSwapQuote` and `buildSwapTransaction`**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(agent-runtime): implement PancakeSwap BSC Testnet swap router adapter`)**

---

### Task 3: Agent Maker Mode MPP Server & Replay Store (`packages/agent-runtime/src/mpp/`)

**Files:**
- Create: `packages/agent-runtime/src/mpp/replay-store.ts`
- Create: `packages/agent-runtime/src/mpp/server.ts`
- Create: `packages/agent-runtime/src/mpp/index.ts`
- Test: `packages/agent-runtime/tests/mpp-server.test.ts`

- [ ] **Step 1: Write failing MPP 402 challenge and replay protection tests**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement `MPPReplayStore` and `MPPServer` with on-chain settlement verification**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(agent-runtime): implement Agent Maker Mode HTTP 402 server and replay store`)**

---

### Task 4: JSON-RPC Dispatcher Phase 2 Method Bindings

**Files:**
- Modify: `packages/agent-runtime/src/index.ts`
- Test: `packages/agent-runtime/tests/phase2-rpc.test.ts`

- [x] **Step 1: Write failing RPC method tests for swap & MPP endpoints**
- [x] **Step 2: Run test to verify failure**
- [x] **Step 3: Register `wallet.estimateSwapQuote`, `wallet.buildSwapTx`, `mpp.startServer`, `mpp.stopServer`, `mpp.getStatus`, `mpp.getSalesHistory` in `createAgentDispatcher`**
- [x] **Step 4: Run test to verify pass**
- [x] **Step 5: Commit (`feat(agent-runtime): wire Phase 2 swap and MPP RPC endpoints into dispatcher`)**

---

### Task 5: Native macOS UI - Swap View & Maker Mode Dashboard (`apps/macos/`)

**Files:**
- Create: `apps/macos/Sources/UI/SwapView.swift`
- Create: `apps/macos/Sources/UI/MakerModeDashboardView.swift`
- Modify: `apps/macos/Sources/UI/WalletView.swift`
- Modify: `apps/macos/Sources/UI/NotchHUDView.swift`
- Test: `apps/macos/Tests/UITests/Phase2UITests.swift`

- [ ] **Step 1: Write failing Swift UI view model tests for Swap & Maker Mode**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement SwiftUI `SwapView` and `MakerModeDashboardView` with live quote calculations**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(macos): implement Swap View and Maker Mode Dashboard UI`)**

---

### Task 6: End-to-End Phase 2 Integration Suite (`tests/`)

**Files:**
- Create: `tests/integration/phase2-e2e.test.ts`

- [ ] **Step 1: Write comprehensive Phase 2 E2E test suite (Swap calculation + Autonomous Maker-Buyer cycle with replay attack protection)**
- [ ] **Step 2: Run test to verify pass**
- [ ] **Step 3: Verify full monorepo (`pnpm test` and `swift test`)**
- [ ] **Step 4: Commit (`test(e2e): add Phase 2 PancakeSwap and Maker Mode integration tests`)**
