/**
 * BNB Agent SDK Facade & Unified Agent Toolkit
 *
 * Provides a consolidated interface for BNB Chain operations, including
 * ERC-8004 identity registration/discovery, x402 autonomous payment settlement,
 * and ERC-8056 Scaled UI Amount balance queries.
 */

import { type JsonRpcProvider } from 'ethers';
import type {
  TokenBalance,
  X402PaymentChallenge,
  X402PaymentReceipt,
} from '@notch/shared-types';
import type { AgentSession } from '../wallet/session.js';
import { getBSCProvider, BSC_TESTNET_CHAIN_ID } from './provider.js';
import { fetchTokenScaledBalance } from './erc8056.js';
import {
  parseX402Challenge,
  executeX402Payment,
  createX402PaymentHeaders,
  type X402PaymentOptions,
} from './x402-client.js';
import {
  registerAgentIdentity,
  discoverAgents,
  getAgentIdentity,
  type AgentIdentityMetadata,
  type AgentIdentityRecord,
  type DiscoverAgentsFilter,
  type RegisterAgentIdentityOptions,
} from './erc8004.js';

export interface BnbAgentSdkOptions {
  rpcUrl?: string;
  chainId?: number;
  registryAddress?: string;
}

/**
 * Unified BNB Agent SDK Client wrapping autonomous wallet capabilities,
 * ERC-8004 agent registries, and x402 payment settlements on BSC Testnet.
 */
export class BnbAgentSdk {
  private _session: AgentSession;
  private _provider: JsonRpcProvider;
  private _chainId: number;

  constructor(session: AgentSession, options?: BnbAgentSdkOptions) {
    this._session = session;
    this._chainId = options?.chainId ?? BSC_TESTNET_CHAIN_ID;
    this._provider = getBSCProvider(options?.rpcUrl);
  }

  /**
   * The associated AgentSession managing active signing keys.
   */
  public get session(): AgentSession {
    return this._session;
  }

  /**
   * Active BSC Testnet JsonRpcProvider.
   */
  public get provider(): JsonRpcProvider {
    return this._provider;
  }

  /**
   * Configured Chain ID (default 97 for BSC Testnet).
   */
  public get chainId(): number {
    return this._chainId;
  }

  /**
   * Queries agent wallet balance with ERC-8056 scaling support.
   *
   * @param tokenAddress Optional token contract address (defaults to native BNB)
   * @returns Formatted TokenBalance
   */
  public async getBalance(tokenAddress?: string): Promise<TokenBalance> {
    const address = this._session.getAddress();
    return fetchTokenScaledBalance(tokenAddress || '', address, this._provider);
  }

  /**
   * Parses an x402 HTTP challenge from response headers and/or body.
   */
  public parseChallenge(
    headers: Record<string, string | string[] | undefined>,
    body?: unknown
  ): X402PaymentChallenge {
    return parseX402Challenge(headers, body);
  }

  /**
   * Executes an x402 payment challenge using the active agent session.
   *
   * @param challenge Parsed x402 challenge or HTTP headers object
   * @param options Optional payment options and safety limits
   * @returns Completed X402PaymentReceipt
   */
  public async payX402(
    challenge: X402PaymentChallenge,
    options?: X402PaymentOptions
  ): Promise<X402PaymentReceipt> {
    return executeX402Payment(challenge, this._session, {
      provider: this._provider,
      ...options,
    });
  }

  /**
   * Formats HTTP headers containing payment proof for subsequent service requests.
   */
  public createPaymentHeaders(
    receipt: X402PaymentReceipt | { txHash: string }
  ): Record<string, string> {
    return createX402PaymentHeaders(receipt);
  }

  /**
   * Registers an ERC-8004 identity for this agent on BSC Testnet.
   *
   * @param metadata Agent identity metadata
   * @param options Optional registration parameters
   * @returns Registered agent ID string
   */
  public async registerIdentity(
    metadata: AgentIdentityMetadata,
    options?: RegisterAgentIdentityOptions
  ): Promise<string> {
    return registerAgentIdentity(metadata, this._session, {
      provider: this._provider,
      chainId: this._chainId,
      ...options,
    });
  }

  /**
   * Discovers registered agents on BSC Testnet matching filter criteria.
   *
   * @param filter Optional search query, tags, or limits
   * @returns Matching AgentIdentityRecord array
   */
  public async discover(
    filter?: DiscoverAgentsFilter
  ): Promise<AgentIdentityRecord[]> {
    return discoverAgents(filter, this._provider, {
      chainId: this._chainId,
    });
  }

  /**
   * Retrieves an agent identity record by ID or owner address.
   */
  public async getAgent(agentIdOrAddress: string): Promise<AgentIdentityRecord | null> {
    return getAgentIdentity(agentIdOrAddress);
  }
}
