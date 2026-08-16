/**
 * BNB Chain (BSC) Testnet RPC Provider & Configuration
 */

import { JsonRpcProvider, Network } from 'ethers';

export const BSC_TESTNET_CHAIN_ID = 97;
export const DEFAULT_BSC_TESTNET_RPC = 'https://data-seed-prebsc-1-s1.binance.org:8545/';
export const BSC_TESTNET_FALLBACK_RPCS = [
  'https://data-seed-prebsc-1-s1.binance.org:8545/',
  'https://bsc-testnet.publicnode.com',
  'https://bsc-testnet-rpc.publicnode.com',
  'https://data-seed-prebsc-2-s1.binance.org:8545/',
];

/**
 * Returns a configured ethers JsonRpcProvider for BSC Testnet (Chain ID 97)
 * @param rpcUrl Optional custom RPC URL. Falls back to process.env.BSC_RPC_URL or default BSC Testnet RPC.
 */
export function getBSCProvider(rpcUrl?: string): JsonRpcProvider {
  const url = rpcUrl || process.env.BSC_RPC_URL || DEFAULT_BSC_TESTNET_RPC;
  const network = Network.from(BSC_TESTNET_CHAIN_ID);
  return new JsonRpcProvider(url, network, {
    staticNetwork: network,
  });
}
