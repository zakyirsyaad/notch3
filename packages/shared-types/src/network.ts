/**
 * Multi-Chain Network Configuration, Switching Models & Type Guards
 */

export const SUPPORTED_CHAIN_IDS = [97, 56, 5611, 204] as const;

export type SupportedChainId = (typeof SUPPORTED_CHAIN_IDS)[number];

export interface NetworkConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  nativeToken: string;
  explorerUrl: string;
  isTestnet: boolean;
  wsRpcUrl?: string;
  currencySymbol?: string;
}

export interface NetworkSwitchParams {
  chainId: number;
}

export interface NetworkSwitchResult {
  success: boolean;
  activeNetwork: NetworkConfig;
  previousChainId?: number;
}

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

/**
 * Validates whether an unknown value is a SupportedChainId
 */
export function isSupportedChainId(val: unknown): val is SupportedChainId {
  return typeof val === 'number' && (SUPPORTED_CHAIN_IDS as readonly number[]).includes(val);
}

/**
 * Validates whether an unknown object conforms to NetworkConfig
 */
export function isNetworkConfig(val: unknown): val is NetworkConfig {
  if (!isRecord(val)) return false;
  if (typeof val['chainId'] !== 'number') return false;
  if (typeof val['name'] !== 'string') return false;
  if (typeof val['rpcUrl'] !== 'string') return false;
  if (typeof val['nativeToken'] !== 'string') return false;
  if (typeof val['explorerUrl'] !== 'string') return false;
  if (typeof val['isTestnet'] !== 'boolean') return false;
  if ('wsRpcUrl' in val && val['wsRpcUrl'] !== undefined && typeof val['wsRpcUrl'] !== 'string') {
    return false;
  }
  if ('currencySymbol' in val && val['currencySymbol'] !== undefined && typeof val['currencySymbol'] !== 'string') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to NetworkSwitchParams
 */
export function isNetworkSwitchParams(val: unknown): val is NetworkSwitchParams {
  if (!isRecord(val)) return false;
  if (typeof val['chainId'] !== 'number') return false;
  return true;
}

/**
 * Validates whether an unknown object conforms to NetworkSwitchResult
 */
export function isNetworkSwitchResult(val: unknown): val is NetworkSwitchResult {
  if (!isRecord(val)) return false;
  if (typeof val['success'] !== 'boolean') return false;
  if (!isNetworkConfig(val['activeNetwork'])) return false;
  if ('previousChainId' in val && val['previousChainId'] !== undefined && typeof val['previousChainId'] !== 'number') {
    return false;
  }
  return true;
}
