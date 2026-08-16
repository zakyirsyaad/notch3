/**
 * BNB Agent SDK Facade & Unified Agent Toolkit
 *
 * Provides a consolidated interface for BNB Chain operations, including
 * multi-chain network switching, ERC-8004 identity registration/discovery,
 * x402 autonomous payment settlement, ERC-8056 Scaled UI Amount balance queries,
 * PancakeSwap swaps, and BNB Greenfield storage.
 */

import { type JsonRpcProvider } from 'ethers';
import type {
  TokenBalance,
  X402PaymentChallenge,
  X402PaymentReceipt,
  SwapQuoteParams,
  SwapQuoteResult,
  BuildSwapParams,
  UnsignedTransactionPayload,
  GreenfieldUploadParams,
  GreenfieldUploadResult,
  GreenfieldObjectResult,
  GreenfieldObjectMetadata,
  GreenfieldBackupParams,
  GreenfieldBackupResult,
  NetworkConfig,
  NetworkSwitchResult,
} from '@notch/shared-types';
import type { AgentSession } from '../wallet/session.js';
import { BSC_TESTNET_CHAIN_ID } from './provider.js';
import { NetworkRegistry } from './network.js';
import { fetchTokenScaledBalance } from './erc8056.js';
import {
  estimateSwapQuote,
  buildSwapTransaction,
  buildApproveTransaction,
  getTokenAllowance,
  getPancakeSwapDeployment,
  type BuildApproveParams,
} from './pancakeswap.js';
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
import {
  GreenfieldClient,
  type GreenfieldClientOptions,
} from './greenfield.js';

export interface BnbAgentSdkOptions {
  rpcUrl?: string;
  chainId?: number;
  provider?: JsonRpcProvider;
  registryAddress?: string;
  greenfieldOptions?: GreenfieldClientOptions;
  networkRegistry?: NetworkRegistry;
}

/**
 * Unified BNB Agent SDK Client wrapping autonomous wallet capabilities,
 * multi-chain dynamic network switching across BSC & opBNB,
 * ERC-8004 agent registries, x402 payment settlements on BSC Testnet,
 * and BNB Greenfield decentralized storage.
 */
export class BnbAgentSdk {
  private _session: AgentSession;
  private _chainId: number;
  private _networkRegistry: NetworkRegistry;
  private _greenfield: GreenfieldClient;
  private _provider?: JsonRpcProvider;

  constructor(session: AgentSession, options?: BnbAgentSdkOptions) {
    this._session = session;
    this._networkRegistry =
      options?.networkRegistry ||
      new NetworkRegistry(options?.chainId ?? BSC_TESTNET_CHAIN_ID);

    if (options?.rpcUrl) {
      this._networkRegistry.setRpcUrl(
        this._networkRegistry.getCurrentChainId(),
        options.rpcUrl
      );
    }

    if (options?.provider) {
      this._provider = options.provider;
    }

    this._chainId = this._networkRegistry.getCurrentChainId();
    this._greenfield = new GreenfieldClient({
      session,
      ...options?.greenfieldOptions,
    });
  }

  /**
   * The associated AgentSession managing active signing keys.
   */
  public get session(): AgentSession {
    return this._session;
  }

  /**
   * Active multi-chain NetworkRegistry instance.
   */
  public get networkRegistry(): NetworkRegistry {
    return this._networkRegistry;
  }

  /**
   * Active JsonRpcProvider for the current network.
   */
  public get provider(): JsonRpcProvider {
    return this._provider || this._networkRegistry.getProvider(this._chainId);
  }

  /**
   * Configured Chain ID of the current active network.
   */
  public get chainId(): number {
    return this._chainId;
  }

  /**
   * BNB Greenfield Decentralized Storage client instance.
   */
  public get greenfield(): GreenfieldClient {
    return this._greenfield;
  }

  /**
   * Returns list of all available network configurations.
   */
  public getNetworks(): NetworkConfig[] {
    return this._networkRegistry.getNetworks();
  }

  /**
   * Returns the configuration of the current active network.
   */
  public getCurrentNetwork(): NetworkConfig {
    return this._networkRegistry.getCurrentNetwork();
  }

  /**
   * Switches the active network across supported chains.
   *
   * @param chainId Target network chain ID
   * @returns NetworkSwitchResult indicating success status and active network
   */
  public switchNetwork(chainId: number): NetworkSwitchResult {
    const result = this._networkRegistry.switchNetwork(chainId);
    if (result.success) {
      this._chainId = result.activeNetwork.chainId;
      this._provider = undefined;
    }
    return result;
  }

  /**
   * Queries agent wallet balance with ERC-8056 scaling support.
   *
   * @param tokenAddress Optional token contract address (defaults to native BNB)
   * @returns Formatted TokenBalance
   */
  public async getBalance(tokenAddress?: string): Promise<TokenBalance> {
    const address = this._session.getAddress();
    return fetchTokenScaledBalance(tokenAddress || '', address, this.provider);
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
      provider: this.provider,
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
      provider: this.provider,
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
    return discoverAgents(filter, this.provider, {
      chainId: this._chainId,
    });
  }

  /**
   * Retrieves an agent identity record by ID or owner address.
   */
  public async getAgent(agentIdOrAddress: string): Promise<AgentIdentityRecord | null> {
    return getAgentIdentity(agentIdOrAddress);
  }

  /**
   * Estimates output amount and minimum received amount after slippage for PancakeSwap swaps.
   *
   * @param params Swap quote parameters
   * @returns Formatted SwapQuoteResult
   */
  public async estimateSwapQuote(
    params: SwapQuoteParams
  ): Promise<SwapQuoteResult> {
    return estimateSwapQuote(
      { ...params, chainId: params.chainId ?? this._chainId },
      this.provider
    );
  }

  /**
   * Builds an unsigned transaction payload for PancakeSwap Router V2 on BSC Testnet.
   *
   * @param params Parameters including recipient, amounts, and route
   * @returns UnsignedTransactionPayload
   */
  public async buildSwapTransaction(
    params: BuildSwapParams
  ): Promise<UnsignedTransactionPayload> {
    return buildSwapTransaction(
      { ...params, chainId: params.chainId ?? this._chainId },
      this.provider
    );
  }

  /**
   * Returns the raw ERC-20 allowance the owner granted to the given spender
   * (defaults to the PancakeSwap router of the active chain).
   */
  public async getTokenAllowance(
    tokenAddress: string,
    owner: string,
    spender?: string
  ): Promise<string> {
    const resolvedSpender =
      spender || getPancakeSwapDeployment(this._chainId).router;
    return getTokenAllowance(tokenAddress, owner, resolvedSpender, this.provider);
  }

  /**
   * Builds an unsigned ERC-20 approve transaction for the active chain's
   * PancakeSwap router (unlimited approval by default).
   */
  public async buildApproveTransaction(
    params: Omit<BuildApproveParams, 'chainId'> & { chainId?: number }
  ): Promise<UnsignedTransactionPayload> {
    return buildApproveTransaction(
      { ...params, chainId: params.chainId ?? this._chainId },
      this.provider
    );
  }

  /**
   * Uploads an object to BNB Greenfield decentralized storage.
   *
   * @param params Greenfield upload parameters
   * @returns Formatted GreenfieldUploadResult
   */
  public async uploadToGreenfield(
    params: GreenfieldUploadParams
  ): Promise<GreenfieldUploadResult> {
    return this._greenfield.uploadObject(params);
  }

  /**
   * Retrieves an object from BNB Greenfield decentralized storage.
   *
   * @param bucket Bucket name
   * @param objectName Object name
   * @returns Formatted GreenfieldObjectResult
   */
  public async getFromGreenfield(
    bucket: string,
    objectName: string
  ): Promise<GreenfieldObjectResult> {
    return this._greenfield.getObject(bucket, objectName);
  }

  /**
   * Lists objects in a Greenfield bucket.
   *
   * @param bucket Bucket name
   * @param prefix Optional path prefix
   * @returns Formatted GreenfieldObjectMetadata array
   */
  public async listGreenfieldObjects(
    bucket: string,
    prefix?: string
  ): Promise<GreenfieldObjectMetadata[]> {
    return this._greenfield.listObjects(bucket, prefix);
  }

  /**
   * Backs up encrypted chat history to BNB Greenfield decentralized storage.
   *
   * @param params Session backup parameters
   * @returns Formatted GreenfieldBackupResult
   */
  public async backupChatHistory(
    params: GreenfieldBackupParams
  ): Promise<GreenfieldBackupResult> {
    return this._greenfield.backupChatHistory(params);
  }
}
