/**
 * Agent Runtime Configuration, Status, and Execution Data Models & Type Guards
 */

import type { X402PaymentReceipt } from './wallet.js';

export type AgentLockState = 'unlocked' | 'locked' | 'uninitialized';

export type AgentState = 'active' | 'paused' | 'locked' | 'uninitialized' | 'error';

export interface AgentConfig {
  chainId: number;
  rpcUrl: string;
  openaiApiKey?: string;
  openaiBaseUrl?: string;
  openaiModel?: string;
  agentName?: string;
  customPrompt?: string;
}

export interface AgentStatus {
  state: AgentState;
  address?: string;
  balance?: string;
  activeTasks?: number;
  lastActivity?: number;
  lockState: AgentLockState;
  error?: string;
}

export interface ToolCallExecution {
  name: string;
  args: Record<string, unknown>;
  result: unknown;
}

export interface AgentExecutionResult {
  response: string;
  toolCallsExecuted: ToolCallExecution[];
  receipts?: X402PaymentReceipt[];
  citations?: string[];
}

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

/**
 * Validates whether an unknown value is an AgentLockState
 */
export function isAgentLockState(val: unknown): val is AgentLockState {
  return typeof val === 'string' && ['unlocked', 'locked', 'uninitialized'].includes(val);
}

/**
 * Validates whether an unknown value is an AgentState
 */
export function isAgentState(val: unknown): val is AgentState {
  return (
    typeof val === 'string' &&
    ['active', 'paused', 'locked', 'uninitialized', 'error'].includes(val)
  );
}

/**
 * Validates whether an unknown object conforms to AgentConfig
 */
export function isAgentConfig(val: unknown): val is AgentConfig {
  if (!isRecord(val)) return false;
  if (typeof val['chainId'] !== 'number') return false;
  if (typeof val['rpcUrl'] !== 'string') return false;
  if ('openaiApiKey' in val && val['openaiApiKey'] !== undefined && typeof val['openaiApiKey'] !== 'string') {
    return false;
  }
  if ('openaiBaseUrl' in val && val['openaiBaseUrl'] !== undefined && typeof val['openaiBaseUrl'] !== 'string') {
    return false;
  }
  if ('openaiModel' in val && val['openaiModel'] !== undefined && typeof val['openaiModel'] !== 'string') {
    return false;
  }
  if ('agentName' in val && val['agentName'] !== undefined && typeof val['agentName'] !== 'string') {
    return false;
  }
  if ('customPrompt' in val && val['customPrompt'] !== undefined && typeof val['customPrompt'] !== 'string') {
    return false;
  }
  return true;
}

/**
 * Validates whether an unknown object conforms to AgentStatus
 */
export function isAgentStatus(val: unknown): val is AgentStatus {
  if (!isRecord(val)) return false;
  if (!isAgentState(val['state'])) return false;
  if (!isAgentLockState(val['lockState'])) return false;
  if ('address' in val && val['address'] !== undefined && typeof val['address'] !== 'string') {
    return false;
  }
  if ('balance' in val && val['balance'] !== undefined && typeof val['balance'] !== 'string') {
    return false;
  }
  if ('activeTasks' in val && val['activeTasks'] !== undefined && typeof val['activeTasks'] !== 'number') {
    return false;
  }
  if ('lastActivity' in val && val['lastActivity'] !== undefined && typeof val['lastActivity'] !== 'number') {
    return false;
  }
  if ('error' in val && val['error'] !== undefined && typeof val['error'] !== 'string') {
    return false;
  }
  return true;
}
