# Notch Agent Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase 3 features for Notch Agent: BNB Greenfield decentralized storage adapter, multi-chain network switcher (BSC Testnet, BSC Mainnet, opBNB), native macOS UI controls, and an automated standalone `NotchAgent.app` bundler script.

**Architecture:** Extend `@notch/shared-types`, implement `src/bnb/greenfield.ts` and `src/bnb/network.ts` in `@notch/agent-runtime`, wire RPC methods, build SwiftUI `NetworkSwitcherView` & `GreenfieldStorageView`, and build `scripts/build-macos-app.sh`.

**Tech Stack:** TypeScript, `ethers` v6, Node.js, SwiftUI/AppKit, Vitest, Swift Testing, Bash/zsh.

---

## Global Constraints

- **Greenfield Testnet SP:** `https://gnfd-testnet-sp1.bnbchain.org` (Chain ID `5600`).
- **Supported Chains:** BSC Testnet (97), BSC Mainnet (56), opBNB Testnet (5611), opBNB Mainnet (204).
- **Security Boundaries:** Chat history backups must be encrypted client-side before Greenfield upload. Network switching must safely update active RPC providers without invalidating in-memory keystores.
- **Standalone App Standard:** Bundled `NotchAgent.app` must include `Contents/Info.plist` with `LSUIElement=true` for Menu Bar / Notch accessory presentation.

---

## Task Decomposition

### Task 1: Shared Types Phase 3 Schemas (`packages/shared-types`)

**Files:**
- Create: `packages/shared-types/src/greenfield.ts`
- Create: `packages/shared-types/src/network.ts`
- Modify: `packages/shared-types/src/index.ts`
- Test: `packages/shared-types/tests/phase3-types.test.ts`

- [ ] **Step 1: Write failing type validation tests**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement Greenfield and Network types and type guards**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(shared-types): add Greenfield storage and multi-chain network schemas`)**

---

### Task 2: BNB Greenfield Decentralized Storage Adapter (`packages/agent-runtime/src/bnb/`)

**Files:**
- Create: `packages/agent-runtime/src/bnb/greenfield.ts`
- Modify: `packages/agent-runtime/src/bnb/index.ts`
- Test: `packages/agent-runtime/tests/greenfield.test.ts`

- [ ] **Step 1: Write failing Greenfield storage tests**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement `GreenfieldClient` with upload, download, object listing, and encrypted backup helpers**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(agent-runtime): implement BNB Greenfield decentralized storage adapter`)**

---

### Task 3: Multi-Chain Network Switcher & Dynamic Provider (`packages/agent-runtime/src/bnb/`)

**Files:**
- Create: `packages/agent-runtime/src/bnb/network.ts`
- Modify: `packages/agent-runtime/src/bnb/provider.ts`
- Modify: `packages/agent-runtime/src/bnb/index.ts`
- Test: `packages/agent-runtime/tests/network-switcher.test.ts`

- [ ] **Step 1: Write failing network switcher and provider registry tests**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement `NetworkRegistry` and dynamic provider switching**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(agent-runtime): implement multi-chain network switcher and provider registry`)**

---

### Task 4: JSON-RPC Dispatcher Phase 3 Method Bindings

**Files:**
- Modify: `packages/agent-runtime/src/index.ts`
- Test: `packages/agent-runtime/tests/phase3-rpc.test.ts`

- [ ] **Step 1: Write failing RPC tests for Greenfield and Network endpoints**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Register `greenfield.*` and `network.*` methods in `createAgentDispatcher`**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(agent-runtime): wire Greenfield and Network switcher RPC endpoints`)**

---

### Task 5: Native macOS UI - Network Switcher & Greenfield Drawer (`apps/macos/`)

**Files:**
- Create: `apps/macos/Sources/UI/NetworkSwitcherView.swift`
- Create: `apps/macos/Sources/UI/GreenfieldStorageView.swift`
- Modify: `apps/macos/Sources/UI/NotchHUDView.swift`
- Modify: `apps/macos/Sources/UI/MenuBarController.swift`
- Test: `apps/macos/Tests/UITests/Phase3UITests.swift`

- [ ] **Step 1: Write failing SwiftUI view model tests for Phase 3 components**
- [ ] **Step 2: Run test to verify failure**
- [ ] **Step 3: Implement `NetworkSwitcherView` and `GreenfieldStorageView` and integrate into HUD drawer**
- [ ] **Step 4: Run test to verify pass**
- [ ] **Step 5: Commit (`feat(macos): implement Network Switcher and Greenfield Storage UI`)**

---

### Task 6: Standalone macOS Application Bundler (`scripts/`)

**Files:**
- Create: `scripts/build-macos-app.sh`
- Modify: `package.json`

- [ ] **Step 1: Write automated `scripts/build-macos-app.sh` build & bundle pipeline**
- [ ] **Step 2: Run bundle script and verify `NotchAgent.app` directory structure and `Info.plist`**
- [ ] **Step 3: Run full verification suite across the monorepo (`pnpm test` and `swift test`)**
- [ ] **Step 4: Commit (`build(macos): add standalone NotchAgent.app packaging script`)**
