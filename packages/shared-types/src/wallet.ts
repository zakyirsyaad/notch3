/**
 * Wallet, Token (ERC-20 / ERC-8056), and x402 Payment Data Models & Type Guards
 */

export interface TokenBalance {
  tokenAddress: string;
  name: string;
  symbol: string;
  decimals: number;
  rawBalance: string;
  uiBalance: string;
  multiplier?: string;
  isERC8056?: boolean;
}

export interface ERC8056Metadata {
  decimals: number;
  multiplier: string;
  symbol?: string;
  name?: string;
}

export interface X402PaymentChallenge {
  token: string;
  amount: string;
  recipient: string;
  chainId: number;
  resource?: string;
  description?: string;
  nonce?: string;
  extra?: Record<string, unknown>;
}

export interface X402PaymentReceipt {
  txHash: string;
  token: string;
  amount: string;
  recipient: string;
  chainId: number;
  timestamp: number;
  blockNumber?: number;
  status: 'success' | 'failed' | 'pending';
  error?: string;
}

export interface WalletKeypairExport {
  address: string;
  keystoreJson: string;
}

export interface TransactionRequestPayload {
  to: string;
  value?: string;
  data?: string;
  chainId?: number;
  gasLimit?: string;
  gasPrice?: string;
  maxFeePerGas?: string;
  maxPriorityFeePerGas?: string;
  nonce?: number;
}

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

/**
 * Validates whether an unknown object conforms to TokenBalance
 */
export function isTokenBalance(val: unknown): val is TokenBalance {
  if (!isRecord(val)) return false;
  if (typeof val['tokenAddress'] !== 'string') return false;
  if (typeof val['name'] !== 'string') return false;
  if (typeof val['symbol'] !== 'string') return false;
  if (typeof val['decimals'] !== 'number') return false;
  if (typeof val['rawBalance'] !== 'string') return false;
  if (typeof val['uiBalance'] !== 'string') return false;
  if ('multiplier' in val && val['multiplier'] !== undefined && typeof val['multiplier'] !== 'string') {
    return false;
  }
  if ('isERC8056' in val && val['isERC8056'] !== undefined && typeof val['isERC8056'] !== 'boolean') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to ERC8056Metadata
 */
export function isERC8056Metadata(val: unknown): val is ERC8056Metadata {
  if (!isRecord(val)) return false;
  if (typeof val['decimals'] !== 'number') return false;
  if (typeof val['multiplier'] !== 'string') return false;
  if ('symbol' in val && val['symbol'] !== undefined && typeof val['symbol'] !== 'string') {
    return false;
  }
  if ('name' in val && val['name'] !== undefined && typeof val['name'] !== 'string') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to X402PaymentChallenge
 */
export function isX402PaymentChallenge(val: unknown): val is X402PaymentChallenge {
  if (!isRecord(val)) return false;
  if (typeof val['token'] !== 'string') return false;
  if (typeof val['amount'] !== 'string') return false;
  if (typeof val['recipient'] !== 'string') return false;
  if (typeof val['chainId'] !== 'number') return false;
  if ('resource' in val && val['resource'] !== undefined && typeof val['resource'] !== 'string') {
    return false;
  }
  if ('description' in val && val['description'] !== undefined && typeof val['description'] !== 'string') {
    return false;
  }
  if ('nonce' in val && val['nonce'] !== undefined && typeof val['nonce'] !== 'string') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to X402PaymentReceipt
 */
export function isX402PaymentReceipt(val: unknown): val is X402PaymentReceipt {
  if (!isRecord(val)) return false;
  if (typeof val['txHash'] !== 'string') return false;
  if (typeof val['token'] !== 'string') return false;
  if (typeof val['amount'] !== 'string') return false;
  if (typeof val['recipient'] !== 'string') return false;
  if (typeof val['chainId'] !== 'number') return false;
  if (typeof val['timestamp'] !== 'number') return false;
  if (!['success', 'failed', 'pending'].includes(val['status'] as string)) return false;
  if ('blockNumber' in val && val['blockNumber'] !== undefined && typeof val['blockNumber'] !== 'number') {
    return false;
  }
  if ('error' in val && val['error'] !== undefined && typeof val['error'] !== 'string') {
    return false;
  }
  return true;
}
