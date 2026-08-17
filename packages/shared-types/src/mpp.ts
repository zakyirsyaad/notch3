/**
 * Agent Maker Mode (MPP HTTP 402 Server) Data Models & Type Guards
 */

export interface MPPServerConfig {
  port?: number;
  host?: string;
  recipient?: string;
  chainId?: number;
  defaultPrice?: string;
  token?: string;
  replayStorePath?: string;
  allowedEndpoints?: string[];
}

export interface MPPServerStatus {
  running: boolean;
  port?: number;
  host?: string;
  recipient?: string;
  chainId?: number;
  totalSales?: number;
  totalRevenue?: string;
  uptime?: number;
  activeEndpoints?: string[];
}

export type MPPSaleStatus = 'settled' | 'refunded' | 'failed';

export interface MPPSaleReceipt {
  txHash: string;
  payer: string;
  recipient: string;
  amount: string;
  token: string;
  chainId: number;
  endpoint: string;
  timestamp: number;
  blockNumber?: number;
  status: MPPSaleStatus;
}

export interface MPPReplayRecord {
  txHash: string;
  payer: string;
  recipient: string;
  amount: string;
  token: string;
  chainId: number;
  endpoint: string;
  timestamp: number;
  blockNumber?: number;
  status?: 'reserved' | 'completed' | 'failed';
}

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

/**
 * Validates whether an unknown object conforms to MPPServerConfig
 */
export function isMPPServerConfig(val: unknown): val is MPPServerConfig {
  if (!isRecord(val)) return false;
  if ('port' in val && val['port'] !== undefined && typeof val['port'] !== 'number') {
    return false;
  }
  if ('host' in val && val['host'] !== undefined && typeof val['host'] !== 'string') {
    return false;
  }
  if ('recipient' in val && val['recipient'] !== undefined && typeof val['recipient'] !== 'string') {
    return false;
  }
  if ('chainId' in val && val['chainId'] !== undefined && typeof val['chainId'] !== 'number') {
    return false;
  }
  if ('defaultPrice' in val && val['defaultPrice'] !== undefined && typeof val['defaultPrice'] !== 'string') {
    return false;
  }
  if ('token' in val && val['token'] !== undefined && typeof val['token'] !== 'string') {
    return false;
  }
  if (
    'replayStorePath' in val &&
    val['replayStorePath'] !== undefined &&
    typeof val['replayStorePath'] !== 'string'
  ) {
    return false;
  }
  if ('allowedEndpoints' in val && val['allowedEndpoints'] !== undefined) {
    if (
      !Array.isArray(val['allowedEndpoints']) ||
      !val['allowedEndpoints'].every((ep) => typeof ep === 'string')
    ) {
      return false;
    }
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to MPPServerStatus
 */
export function isMPPServerStatus(val: unknown): val is MPPServerStatus {
  if (!isRecord(val)) return false;
  if (typeof val['running'] !== 'boolean') return false;
  if ('port' in val && val['port'] !== undefined && typeof val['port'] !== 'number') {
    return false;
  }
  if ('host' in val && val['host'] !== undefined && typeof val['host'] !== 'string') {
    return false;
  }
  if ('recipient' in val && val['recipient'] !== undefined && typeof val['recipient'] !== 'string') {
    return false;
  }
  if ('chainId' in val && val['chainId'] !== undefined && typeof val['chainId'] !== 'number') {
    return false;
  }
  if ('totalSales' in val && val['totalSales'] !== undefined && typeof val['totalSales'] !== 'number') {
    return false;
  }
  if ('totalRevenue' in val && val['totalRevenue'] !== undefined && typeof val['totalRevenue'] !== 'string') {
    return false;
  }
  if ('uptime' in val && val['uptime'] !== undefined && typeof val['uptime'] !== 'number') {
    return false;
  }
  if ('activeEndpoints' in val && val['activeEndpoints'] !== undefined) {
    if (
      !Array.isArray(val['activeEndpoints']) ||
      !val['activeEndpoints'].every((ep) => typeof ep === 'string')
    ) {
      return false;
    }
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to MPPSaleReceipt
 */
export function isMPPSaleReceipt(val: unknown): val is MPPSaleReceipt {
  if (!isRecord(val)) return false;
  if (typeof val['txHash'] !== 'string') return false;
  if (typeof val['payer'] !== 'string') return false;
  if (typeof val['recipient'] !== 'string') return false;
  if (typeof val['amount'] !== 'string') return false;
  if (typeof val['token'] !== 'string') return false;
  if (typeof val['chainId'] !== 'number') return false;
  if (typeof val['endpoint'] !== 'string') return false;
  if (typeof val['timestamp'] !== 'number') return false;
  if (!['settled', 'refunded', 'failed'].includes(val['status'] as string)) {
    return false;
  }
  if ('blockNumber' in val && val['blockNumber'] !== undefined && typeof val['blockNumber'] !== 'number') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to MPPReplayRecord
 */
export function isMPPReplayRecord(val: unknown): val is MPPReplayRecord {
  if (!isRecord(val)) return false;
  if (typeof val['txHash'] !== 'string') return false;
  if (typeof val['payer'] !== 'string') return false;
  if (typeof val['recipient'] !== 'string') return false;
  if (typeof val['amount'] !== 'string') return false;
  if (typeof val['token'] !== 'string') return false;
  if (typeof val['chainId'] !== 'number') return false;
  if (typeof val['endpoint'] !== 'string') return false;
  if (typeof val['timestamp'] !== 'number') return false;
  if ('blockNumber' in val && val['blockNumber'] !== undefined && typeof val['blockNumber'] !== 'number') {
    return false;
  }
  if ('status' in val && val['status'] !== undefined && typeof val['status'] !== 'string') {
    return false;
  }
  return true;
}
