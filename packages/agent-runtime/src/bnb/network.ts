/**
 * Multi-Chain Network Configuration & Dynamic Provider Registry
 *
 * Supports BNB Smart Chain (BSC Testnet/Mainnet) and opBNB (Testnet/Mainnet)
 * with dynamic switching, provider caching, and change notification subscriptions.
 */

import { JsonRpcProvider, Network } from 'ethers';
import {
  isNetworkConfig,
  type NetworkConfig,
  type NetworkSwitchResult,
} from '@notch/shared-types';

export const BSC_TESTNET_CHAIN_ID = 97;
export const BSC_MAINNET_CHAIN_ID = 56;
export const OPBNB_TESTNET_CHAIN_ID = 5611;
export const OPBNB_MAINNET_CHAIN_ID = 204;

export const BSC_TESTNET_CONFIG: NetworkConfig = {
  chainId: BSC_TESTNET_CHAIN_ID,
  name: 'BSC Testnet',
  rpcUrl: 'https://data-seed-prebsc-1-s1.binance.org:8545/',
  nativeToken: 'tBNB',
  explorerUrl: 'https://testnet.bscscan.com',
  isTestnet: true,
  currencySymbol: 'tBNB',
};

export const BSC_MAINNET_CONFIG: NetworkConfig = {
  chainId: BSC_MAINNET_CHAIN_ID,
  name: 'BSC Mainnet',
  rpcUrl: 'https://bsc-dataseed.binance.org/',
  nativeToken: 'BNB',
  explorerUrl: 'https://bscscan.com',
  isTestnet: false,
  currencySymbol: 'BNB',
};

export const OPBNB_TESTNET_CONFIG: NetworkConfig = {
  chainId: OPBNB_TESTNET_CHAIN_ID,
  name: 'opBNB Testnet',
  rpcUrl: 'https://opbnb-testnet-rpc.bnbchain.org',
  nativeToken: 'tBNB',
  explorerUrl: 'https://testnet.opbnbscan.com',
  isTestnet: true,
  currencySymbol: 'tBNB',
};

export const OPBNB_MAINNET_CONFIG: NetworkConfig = {
  chainId: OPBNB_MAINNET_CHAIN_ID,
  name: 'opBNB Mainnet',
  rpcUrl: 'https://opbnb-mainnet-rpc.bnbchain.org',
  nativeToken: 'BNB',
  explorerUrl: 'https://opbnbscan.com',
  isTestnet: false,
  currencySymbol: 'BNB',
};

export const DEFAULT_NETWORKS: NetworkConfig[] = [
  BSC_TESTNET_CONFIG,
  BSC_MAINNET_CONFIG,
  OPBNB_TESTNET_CONFIG,
  OPBNB_MAINNET_CONFIG,
];

export type NetworkChangeListener = (
  newNetwork: NetworkConfig,
  previousNetwork?: NetworkConfig
) => void;

export interface NetworkRegistryOptions {
  initialChainId?: number;
  customNetworks?: NetworkConfig[];
}

/**
 * Registry and dynamic switcher managing multiple blockchain networks,
 * cached ethers JsonRpcProvider instances, and network transition events.
 */
export class NetworkRegistry {
  private _networks: Map<number, NetworkConfig> = new Map();
  private _providers: Map<number, JsonRpcProvider> = new Map();
  private _currentChainId: number;
  private _listeners: Set<NetworkChangeListener> = new Set();

  constructor(initialChainIdOrOptions?: number | NetworkRegistryOptions) {
    for (const net of DEFAULT_NETWORKS) {
      this._networks.set(net.chainId, { ...net });
    }

    let initialChainId = BSC_TESTNET_CHAIN_ID;

    if (typeof initialChainIdOrOptions === 'number') {
      initialChainId = initialChainIdOrOptions;
    } else if (
      typeof initialChainIdOrOptions === 'object' &&
      initialChainIdOrOptions !== null
    ) {
      if (Array.isArray(initialChainIdOrOptions.customNetworks)) {
        for (const net of initialChainIdOrOptions.customNetworks) {
          this.registerNetwork(net);
        }
      }
      if (typeof initialChainIdOrOptions.initialChainId === 'number') {
        initialChainId = initialChainIdOrOptions.initialChainId;
      }
    }

    this._currentChainId = this._networks.has(initialChainId)
      ? initialChainId
      : BSC_TESTNET_CHAIN_ID;
  }

  /**
   * Returns all currently registered network configurations.
   */
  public getNetworks(): NetworkConfig[] {
    return Array.from(this._networks.values()).map((net) => ({ ...net }));
  }

  /**
   * Retrieves a specific network configuration by its chain ID.
   */
  public getNetwork(chainId: number): NetworkConfig | undefined {
    const net = this._networks.get(chainId);
    return net ? { ...net } : undefined;
  }

  /**
   * Returns the configuration of the currently active network.
   */
  public getCurrentNetwork(): NetworkConfig {
    return { ...this._networks.get(this._currentChainId)! };
  }

  /**
   * Returns the chain ID of the currently active network.
   */
  public getCurrentChainId(): number {
    return this._currentChainId;
  }

  /**
   * Registers or updates a network configuration in the registry.
   */
  public registerNetwork(config: NetworkConfig): void {
    if (!isNetworkConfig(config)) {
      throw new Error('Invalid NetworkConfig object');
    }
    this._networks.set(config.chainId, { ...config });
    this._providers.delete(config.chainId);
  }

  /**
   * Overrides the RPC URL for a registered network and refreshes its provider cache.
   */
  public setRpcUrl(chainId: number, rpcUrl: string): void {
    const net = this._networks.get(chainId);
    if (!net) {
      throw new Error(`Network ${chainId} not registered`);
    }
    net.rpcUrl = rpcUrl;
    this._providers.delete(chainId);
  }

  /**
   * Switches the active network to the specified chain ID.
   *
   * @param chainId Target network chain ID
   * @returns NetworkSwitchResult indicating success and active network
   */
  public switchNetwork(chainId: number): NetworkSwitchResult {
    const targetNetwork = this._networks.get(chainId);
    if (!targetNetwork) {
      return {
        success: false,
        activeNetwork: this.getCurrentNetwork(),
      };
    }

    const prevChainId = this._currentChainId;
    const prevNetwork = this._networks.get(prevChainId);
    this._currentChainId = chainId;

    const activeNetwork = this.getCurrentNetwork();
    const result: NetworkSwitchResult = {
      success: true,
      activeNetwork,
      previousChainId: prevChainId,
    };

    this._notifyListeners(
      activeNetwork,
      prevNetwork ? { ...prevNetwork } : undefined
    );

    return result;
  }

  /**
   * Retrieves a cached JsonRpcProvider for the specified chain ID (or current active network).
   *
   * @param chainId Optional chain ID (defaults to current active chain ID)
   */
  public getProvider(chainId?: number): JsonRpcProvider {
    const targetChainId = chainId ?? this._currentChainId;
    const net = this._networks.get(targetChainId);

    if (!net) {
      throw new Error(`Unsupported network chain ID: ${targetChainId}`);
    }

    if (!this._providers.has(targetChainId)) {
      const network = Network.from(targetChainId);
      const provider = new JsonRpcProvider(net.rpcUrl, network, {
        staticNetwork: network,
      });
      this._providers.set(targetChainId, provider);
    }

    return this._providers.get(targetChainId)!;
  }

  /**
   * Subscribes a listener callback to network change events.
   *
   * @param listener Callback invoked when active network changes
   * @returns Unsubscribe function
   */
  public onNetworkChange(listener: NetworkChangeListener): () => void {
    this._listeners.add(listener);
    return () => this.removeListener(listener);
  }

  /**
   * Adds an active network change listener.
   */
  public addListener(listener: NetworkChangeListener): void {
    this._listeners.add(listener);
  }

  /**
   * Removes a registered network change listener.
   */
  public removeListener(listener: NetworkChangeListener): void {
    this._listeners.delete(listener);
  }

  private _notifyListeners(
    newNetwork: NetworkConfig,
    previousNetwork?: NetworkConfig
  ): void {
    for (const listener of this._listeners) {
      try {
        listener(newNetwork, previousNetwork);
      } catch (err) {
        console.error('Error in network change listener:', err);
      }
    }
  }
}
