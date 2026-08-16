/**
 * BNB Chain & Multi-Chain RPC Providers and Configuration
 */

import { JsonRpcProvider, Network } from 'ethers';
import {
  NetworkRegistry,
  BSC_TESTNET_CHAIN_ID,
  BSC_MAINNET_CHAIN_ID,
  OPBNB_TESTNET_CHAIN_ID,
  OPBNB_MAINNET_CHAIN_ID,
  DEFAULT_NETWORKS,
} from './network.js';

export {
  BSC_TESTNET_CHAIN_ID,
  BSC_MAINNET_CHAIN_ID,
  OPBNB_TESTNET_CHAIN_ID,
  OPBNB_MAINNET_CHAIN_ID,
  DEFAULT_NETWORKS,
} from './network.js';

export const DEFAULT_BSC_TESTNET_RPC = 'https://data-seed-prebsc-1-s1.binance.org:8545/';
export const BSC_TESTNET_FALLBACK_RPCS = [
  'https://data-seed-prebsc-1-s1.binance.org:8545/',
  'https://bsc-testnet.publicnode.com',
  'https://bsc-testnet-rpc.publicnode.com',
  'https://data-seed-prebsc-2-s1.binance.org:8545/',
];

let globalNetworkRegistry: NetworkRegistry | null = null;

/**
 * Returns the singleton NetworkRegistry instance.
 */
export function getNetworkRegistry(): NetworkRegistry {
  if (!globalNetworkRegistry) {
    globalNetworkRegistry = new NetworkRegistry();
  }
  return globalNetworkRegistry;
}

/**
 * Returns a configured ethers JsonRpcProvider for BSC Testnet (Chain ID 97).
 * Maintains complete backward compatibility with previous SDK callers.
 *
 * @param rpcUrl Optional custom RPC URL. Falls back to process.env.BSC_RPC_URL or default BSC Testnet RPC.
 */
export function getBSCProvider(rpcUrl?: string): JsonRpcProvider {
  const url = rpcUrl || process.env.BSC_RPC_URL;
  if (url) {
    const network = Network.from(BSC_TESTNET_CHAIN_ID);
    return new JsonRpcProvider(url, network, {
      staticNetwork: network,
    });
  }
  return getNetworkRegistry().getProvider(BSC_TESTNET_CHAIN_ID);
}

/**
 * Returns a configured ethers JsonRpcProvider for the specified chain ID.
 *
 * @param chainId Optional chain ID (defaults to current active chain in registry)
 * @param rpcUrl Optional custom RPC URL override
 */
export function getProvider(
  chainId?: number,
  rpcUrl?: string
): JsonRpcProvider {
  const targetChainId = chainId ?? getNetworkRegistry().getCurrentChainId();
  if (rpcUrl) {
    const network = Network.from(targetChainId);
    return new JsonRpcProvider(rpcUrl, network, {
      staticNetwork: network,
    });
  }
  return getNetworkRegistry().getProvider(targetChainId);
}
