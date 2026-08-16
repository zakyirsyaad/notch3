import { describe, it, expect, vi, beforeEach } from 'vitest';
import { JsonRpcProvider } from 'ethers';
import {
  NetworkRegistry,
  getNetworkRegistry,
  getProvider,
  getBSCProvider,
  BSC_TESTNET_CHAIN_ID,
  BSC_MAINNET_CHAIN_ID,
  OPBNB_TESTNET_CHAIN_ID,
  OPBNB_MAINNET_CHAIN_ID,
  DEFAULT_NETWORKS,
  BSC_TESTNET_CONFIG,
  BSC_MAINNET_CONFIG,
  OPBNB_TESTNET_CONFIG,
  OPBNB_MAINNET_CONFIG,
  type NetworkChangeListener,
} from '../src/bnb/index.js';
import {
  isNetworkConfig,
  isNetworkSwitchResult,
  type NetworkConfig,
} from '@notch/shared-types';
import { AgentSession } from '../src/wallet/session.js';
import { BnbAgentSdk } from '../src/bnb/bnb-sdk.js';

describe('Multi-Chain Network Switcher & Dynamic Provider', () => {
  describe('Constants & Configuration', () => {
    it('exports supported chain ID constants', () => {
      expect(BSC_TESTNET_CHAIN_ID).toBe(97);
      expect(BSC_MAINNET_CHAIN_ID).toBe(56);
      expect(OPBNB_TESTNET_CHAIN_ID).toBe(5611);
      expect(OPBNB_MAINNET_CHAIN_ID).toBe(204);
    });

    it('exports standard network configurations', () => {
      expect(BSC_TESTNET_CONFIG).toEqual({
        chainId: 97,
        name: 'BSC Testnet',
        rpcUrl: 'https://bsc-testnet-rpc.publicnode.com',
        nativeToken: 'tBNB',
        explorerUrl: 'https://testnet.bscscan.com',
        isTestnet: true,
        currencySymbol: 'tBNB',
      });

      expect(BSC_MAINNET_CONFIG).toEqual({
        chainId: 56,
        name: 'BSC Mainnet',
        rpcUrl: 'https://bsc.publicnode.com',
        nativeToken: 'BNB',
        explorerUrl: 'https://bscscan.com',
        isTestnet: false,
        currencySymbol: 'BNB',
      });

      expect(OPBNB_TESTNET_CONFIG).toEqual({
        chainId: 5611,
        name: 'opBNB Testnet',
        rpcUrl: 'https://opbnb-testnet-rpc.bnbchain.org',
        nativeToken: 'tBNB',
        explorerUrl: 'https://testnet.opbnbscan.com',
        isTestnet: true,
        currencySymbol: 'tBNB',
      });

      expect(OPBNB_MAINNET_CONFIG).toEqual({
        chainId: 204,
        name: 'opBNB Mainnet',
        rpcUrl: 'https://opbnb-mainnet-rpc.bnbchain.org',
        nativeToken: 'BNB',
        explorerUrl: 'https://opbnbscan.com',
        isTestnet: false,
        currencySymbol: 'BNB',
      });
    });

    it('exports DEFAULT_NETWORKS containing all 4 supported chains validated by isNetworkConfig', () => {
      expect(DEFAULT_NETWORKS).toHaveLength(4);
      for (const net of DEFAULT_NETWORKS) {
        expect(isNetworkConfig(net)).toBe(true);
      }
      const chainIds = DEFAULT_NETWORKS.map((n) => n.chainId);
      expect(chainIds).toContain(97);
      expect(chainIds).toContain(56);
      expect(chainIds).toContain(5611);
      expect(chainIds).toContain(204);
    });
  });

  describe('NetworkRegistry Class', () => {
    let registry: NetworkRegistry;

    beforeEach(() => {
      registry = new NetworkRegistry();
    });

    it('initializes with BSC Testnet (97) by default', () => {
      expect(registry.getCurrentChainId()).toBe(97);
      const current = registry.getCurrentNetwork();
      expect(current.chainId).toBe(97);
      expect(current.name).toBe('BSC Testnet');
      expect(current.isTestnet).toBe(true);
    });

    it('allows initialization with a specific chain ID', () => {
      const customRegistry = new NetworkRegistry(56);
      expect(customRegistry.getCurrentChainId()).toBe(56);
      expect(customRegistry.getCurrentNetwork().name).toBe('BSC Mainnet');
    });

    it('falls back to default chain ID if initial chain ID is unsupported', () => {
      const customRegistry = new NetworkRegistry(999999);
      expect(customRegistry.getCurrentChainId()).toBe(97);
    });

    it('returns all supported networks via getNetworks()', () => {
      const networks = registry.getNetworks();
      expect(networks).toHaveLength(4);
      expect(networks.map((n) => n.chainId)).toEqual([97, 56, 5611, 204]);
    });

    it('retrieves specific network by chainId via getNetwork()', () => {
      const opbnb = registry.getNetwork(5611);
      expect(opbnb).toBeDefined();
      expect(opbnb?.name).toBe('opBNB Testnet');
      expect(registry.getNetwork(12345)).toBeUndefined();
    });

    it('switches network to BSC Mainnet successfully', () => {
      const result = registry.switchNetwork(56);
      expect(isNetworkSwitchResult(result)).toBe(true);
      expect(result.success).toBe(true);
      expect(result.activeNetwork.chainId).toBe(56);
      expect(result.previousChainId).toBe(97);

      expect(registry.getCurrentChainId()).toBe(56);
      expect(registry.getCurrentNetwork().name).toBe('BSC Mainnet');
    });

    it('switches network across multiple chains sequentially', () => {
      let res = registry.switchNetwork(5611);
      expect(res.success).toBe(true);
      expect(res.activeNetwork.chainId).toBe(5611);
      expect(res.previousChainId).toBe(97);

      res = registry.switchNetwork(204);
      expect(res.success).toBe(true);
      expect(res.activeNetwork.chainId).toBe(204);
      expect(res.previousChainId).toBe(5611);

      res = registry.switchNetwork(97);
      expect(res.success).toBe(true);
      expect(res.activeNetwork.chainId).toBe(97);
      expect(res.previousChainId).toBe(204);
    });

    it('returns success: false when switching to an unsupported chain ID without altering active network', () => {
      const initial = registry.getCurrentNetwork();
      const result = registry.switchNetwork(88888);

      expect(result.success).toBe(false);
      expect(result.activeNetwork.chainId).toBe(initial.chainId);
      expect(registry.getCurrentChainId()).toBe(initial.chainId);
    });

    it('handles switching to the already active network gracefully', () => {
      const res = registry.switchNetwork(97);
      expect(res.success).toBe(true);
      expect(res.activeNetwork.chainId).toBe(97);
      expect(res.previousChainId).toBe(97);
    });

    it('allows registering a custom network configuration', () => {
      const customNet: NetworkConfig = {
        chainId: 1337,
        name: 'Local Devnet',
        rpcUrl: 'http://127.0.0.1:8545',
        nativeToken: 'ETH',
        explorerUrl: 'http://127.0.0.1:8545/explorer',
        isTestnet: true,
      };

      registry.registerNetwork(customNet);
      expect(registry.getNetworks()).toHaveLength(5);
      expect(registry.getNetwork(1337)).toEqual(customNet);

      const res = registry.switchNetwork(1337);
      expect(res.success).toBe(true);
      expect(res.activeNetwork.chainId).toBe(1337);
    });

    it('allows overriding RPC URL for an existing network', () => {
      const customRpc = 'https://custom-bsc-rpc.example.com';
      registry.setRpcUrl(97, customRpc);

      const net = registry.getNetwork(97);
      expect(net?.rpcUrl).toBe(customRpc);
      expect(registry.getCurrentNetwork().rpcUrl).toBe(customRpc);
    });
  });

  describe('Listeners & Subscriptions', () => {
    let registry: NetworkRegistry;

    beforeEach(() => {
      registry = new NetworkRegistry();
    });

    it('notifies registered listeners when active network switches', () => {
      const listener = vi.fn();
      const unsubscribe = registry.onNetworkChange(listener);

      registry.switchNetwork(56);
      expect(listener).toHaveBeenCalledTimes(1);
      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({ chainId: 56, name: 'BSC Mainnet' }),
        expect.objectContaining({ chainId: 97, name: 'BSC Testnet' })
      );

      registry.switchNetwork(204);
      expect(listener).toHaveBeenCalledTimes(2);
      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({ chainId: 204, name: 'opBNB Mainnet' }),
        expect.objectContaining({ chainId: 56, name: 'BSC Mainnet' })
      );

      unsubscribe();
      registry.switchNetwork(97);
      expect(listener).toHaveBeenCalledTimes(2);
    });

    it('does not trigger listeners on failed network switch', () => {
      const listener = vi.fn();
      registry.onNetworkChange(listener);

      registry.switchNetwork(999999);
      expect(listener).not.toHaveBeenCalled();
    });

    it('supports addListener and removeListener explicitly', () => {
      const listener: NetworkChangeListener = vi.fn();
      registry.addListener(listener);

      registry.switchNetwork(5611);
      expect(listener).toHaveBeenCalledTimes(1);

      registry.removeListener(listener);
      registry.switchNetwork(97);
      expect(listener).toHaveBeenCalledTimes(1);
    });
  });

  describe('Dynamic Provider Management', () => {
    let registry: NetworkRegistry;

    beforeEach(() => {
      registry = new NetworkRegistry();
    });

    it('returns a JsonRpcProvider for current network', () => {
      const provider = registry.getProvider();
      expect(provider).toBeDefined();
      expect(provider).toBeInstanceOf(JsonRpcProvider);
    });

    it('returns a JsonRpcProvider for specified chain ID', () => {
      const providerBsc = registry.getProvider(56);
      expect(providerBsc).toBeDefined();
      expect(providerBsc).toBeInstanceOf(JsonRpcProvider);

      const providerOpbnb = registry.getProvider(5611);
      expect(providerOpbnb).toBeDefined();
      expect(providerOpbnb).toBeInstanceOf(JsonRpcProvider);
    });

    it('caches provider instances for subsequent requests to same chain ID', () => {
      const provider1 = registry.getProvider(97);
      const provider2 = registry.getProvider(97);
      expect(provider1).toBe(provider2);

      const providerBsc1 = registry.getProvider(56);
      const providerBsc2 = registry.getProvider(56);
      expect(providerBsc1).toBe(providerBsc2);
      expect(providerBsc1).not.toBe(provider1);
    });

    it('invalidates cached provider when RPC URL is updated', () => {
      const providerBefore = registry.getProvider(97);
      registry.setRpcUrl(97, 'https://new-bsc-rpc.example.com');
      const providerAfter = registry.getProvider(97);

      expect(providerAfter).not.toBe(providerBefore);
    });

    it('throws error when requesting provider for an unregistered network', () => {
      expect(() => registry.getProvider(99999)).toThrow(
        /Unsupported network chain ID: 99999/
      );
    });
  });

  describe('Global Provider Functions (`provider.ts`)', () => {
    it('provides getNetworkRegistry() returning singleton registry', () => {
      const reg1 = getNetworkRegistry();
      const reg2 = getNetworkRegistry();
      expect(reg1).toBeDefined();
      expect(reg1).toBe(reg2);
    });

    it('maintains backward compatibility with getBSCProvider()', () => {
      const provider = getBSCProvider();
      expect(provider).toBeDefined();
      expect(provider).toBeInstanceOf(JsonRpcProvider);

      const customProvider = getBSCProvider('https://custom-rpc.example.com');
      expect(customProvider).toBeDefined();
      expect(customProvider).toBeInstanceOf(JsonRpcProvider);
    });

    it('provides getProvider(chainId, rpcUrl) helper', () => {
      const p1 = getProvider(56);
      expect(p1).toBeDefined();
      expect(p1).toBeInstanceOf(JsonRpcProvider);

      const p2 = getProvider(5611, 'https://custom-opbnb.example.com');
      expect(p2).toBeDefined();
      expect(p2).toBeInstanceOf(JsonRpcProvider);
    });
  });

  describe('BnbAgentSdk Dynamic Switching Integration', () => {
    let session: AgentSession;

    beforeEach(() => {
      session = new AgentSession();
    });

    it('initializes with default NetworkRegistry and exposes active network properties', () => {
      const sdk = new BnbAgentSdk(session);
      expect(sdk.networkRegistry).toBeDefined();
      expect(sdk.chainId).toBe(97);
      expect(sdk.getCurrentNetwork().name).toBe('BSC Testnet');
      expect(sdk.getNetworks()).toHaveLength(4);
      expect(sdk.provider).toBeDefined();
    });

    it('allows initializing SDK with custom chain ID', () => {
      const sdk = new BnbAgentSdk(session, { chainId: 56 });
      expect(sdk.chainId).toBe(56);
      expect(sdk.getCurrentNetwork().name).toBe('BSC Mainnet');
    });

    it('switches network dynamically via sdk.switchNetwork()', () => {
      const sdk = new BnbAgentSdk(session);
      const providerBefore = sdk.provider;

      const result = sdk.switchNetwork(5611);
      expect(result.success).toBe(true);
      expect(sdk.chainId).toBe(5611);
      expect(sdk.getCurrentNetwork().name).toBe('opBNB Testnet');
      expect(sdk.provider).not.toBe(providerBefore);
    });

    it('allows injecting a custom NetworkRegistry instance into BnbAgentSdk', () => {
      const customRegistry = new NetworkRegistry(204);
      const sdk = new BnbAgentSdk(session, { networkRegistry: customRegistry });

      expect(sdk.networkRegistry).toBe(customRegistry);
      expect(sdk.chainId).toBe(204);
      expect(sdk.getCurrentNetwork().name).toBe('opBNB Mainnet');
    });
  });
});
