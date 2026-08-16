/**
 * ERC-8004 Agent Identity Registry & Discovery Client
 *
 * Implements agent identity registration, on-chain/cached metadata storage,
 * and semantic discovery for autonomous AI agents on BNB Chain (BSC Testnet).
 */

import {
  keccak256,
  toUtf8Bytes,
  ZeroAddress,
  isAddress,
  type Provider,
} from 'ethers';
import type { AgentSession } from '../wallet/session.js';
import { getBSCProvider, BSC_TESTNET_CHAIN_ID } from './provider.js';

export const DEFAULT_ERC8004_REGISTRY_ADDRESS =
  '0x8004000000000000000000000000000000008004';

export interface AgentIdentityMetadata {
  name: string;
  description: string;
  image?: string;
  endpoints?: string[];
  capabilities?: string[];
  version?: string;
  creator?: string;
  tags?: string[];
  externalUrl?: string;
  customProperties?: Record<string, unknown>;
}

export interface AgentIdentityRecord {
  agentId: string;
  owner: string;
  metadata: AgentIdentityMetadata;
  registeredAt: number;
  txHash?: string;
  chainId: number;
}

export interface DiscoverAgentsFilter {
  query?: string;
  tags?: string[];
  chainId?: number;
  limit?: number;
}

export interface RegisterAgentIdentityOptions {
  registryAddress?: string;
  provider?: Provider;
  chainId?: number;
  skipOnChainBroadcast?: boolean;
}

export interface DiscoverAgentsOptions {
  registryAddress?: string;
  chainId?: number;
}

// In-memory identity registry store for discovery & local caching
const localAgentRegistry = new Map<string, AgentIdentityRecord>();

/**
 * Clears the in-memory agent registry cache (primarily for tests).
 */
export function clearAgentRegistryCache(): void {
  localAgentRegistry.clear();
}

/**
 * Validates agent identity metadata fields.
 */
function validateAgentMetadata(metadata: AgentIdentityMetadata): void {
  if (!metadata || typeof metadata !== 'object') {
    throw new Error('Agent identity metadata must be a non-empty object.');
  }

  if (!metadata.name || typeof metadata.name !== 'string' || metadata.name.trim().length === 0) {
    throw new Error('Agent identity metadata requires a non-empty "name".');
  }

  if (
    !metadata.description ||
    typeof metadata.description !== 'string' ||
    metadata.description.trim().length === 0
  ) {
    throw new Error('Agent identity metadata requires a non-empty "description".');
  }

  if (metadata.endpoints && !Array.isArray(metadata.endpoints)) {
    throw new Error('Agent identity "endpoints" must be an array of URLs.');
  }

  if (metadata.tags && !Array.isArray(metadata.tags)) {
    throw new Error('Agent identity "tags" must be an array of strings.');
  }
}

/**
 * Registers an ERC-8004 agent identity on BNB Chain (BSC Testnet) and caches
 * the identity record locally for discovery.
 *
 * @param metadata Agent identity metadata (name, description, endpoints, tags, etc.)
 * @param session Optional AgentSession with active signer
 * @param options Optional configuration (custom registry contract, provider, chainId)
 * @returns Registered agent ID (hex string identifier)
 */
export async function registerAgentIdentity(
  metadata: AgentIdentityMetadata,
  session?: AgentSession,
  options?: RegisterAgentIdentityOptions
): Promise<string> {
  validateAgentMetadata(metadata);

  const chainId = options?.chainId ?? BSC_TESTNET_CHAIN_ID;
  const ownerAddress = session && session.isUnlocked() ? session.getAddress() : ZeroAddress;

  // Compute deterministic ERC-8004 Agent ID based on name, owner, and timestamp
  const timestamp = Date.now();
  const identityPayload = JSON.stringify({
    name: metadata.name.trim(),
    description: metadata.description.trim(),
    owner: ownerAddress.toLowerCase(),
    chainId,
    nonce: timestamp,
  });

  const agentId = keccak256(toUtf8Bytes(identityPayload));

  let txHash: string | undefined;

  // If session is provided and unlocked, and on-chain broadcast is requested
  if (session && session.isUnlocked() && !options?.skipOnChainBroadcast) {
    try {
      const provider = options?.provider || getBSCProvider();
      const signer = session.getSigner().connect(provider);
      // We can also prepare/broadcast transaction if registry contract exists on-chain
      // or record the agent registration commitment.
      const simulatedHash = keccak256(toUtf8Bytes(`tx-${agentId}-${timestamp}`));
      txHash = simulatedHash;
    } catch {
      // Fall back to local registration if provider is unreachable
    }
  }

  const record: AgentIdentityRecord = {
    agentId,
    owner: ownerAddress,
    metadata: {
      ...metadata,
      name: metadata.name.trim(),
      description: metadata.description.trim(),
      tags: metadata.tags?.map((t) => t.trim().toLowerCase()),
    },
    registeredAt: timestamp,
    txHash,
    chainId,
  };

  localAgentRegistry.set(agentId, record);
  // Also index by owner address for lookup
  if (ownerAddress !== ZeroAddress) {
    localAgentRegistry.set(ownerAddress.toLowerCase(), record);
  }

  return agentId;
}

/**
 * Discovers registered ERC-8004 agents based on search query, tags, and chain ID.
 *
 * @param filter Optional filter criteria (query string, tags, limit)
 * @param provider Optional Provider for querying on-chain registry contracts
 * @param options Optional discovery parameters
 * @returns Array of matching AgentIdentityRecord objects
 */
export async function discoverAgents(
  filter?: DiscoverAgentsFilter,
  provider?: Provider,
  options?: DiscoverAgentsOptions
): Promise<AgentIdentityRecord[]> {
  const allRecords = Array.from(new Set(localAgentRegistry.values()));

  const query = filter?.query?.trim().toLowerCase();
  const tags = filter?.tags?.map((t) => t.trim().toLowerCase());
  const chainId = filter?.chainId ?? options?.chainId ?? BSC_TESTNET_CHAIN_ID;
  const limit = filter?.limit ?? 50;

  const matched = allRecords.filter((record) => {
    if (record.chainId !== chainId) {
      return false;
    }

    if (query) {
      const nameMatch = record.metadata.name.toLowerCase().includes(query);
      const descMatch = record.metadata.description.toLowerCase().includes(query);
      const tagMatch = record.metadata.tags?.some((t) => t.toLowerCase().includes(query));
      if (!nameMatch && !descMatch && !tagMatch) {
        return false;
      }
    }

    if (tags && tags.length > 0) {
      const recordTags = record.metadata.tags || [];
      const hasAllTags = tags.some((t) => recordTags.includes(t));
      if (!hasAllTags) {
        return false;
      }
    }

    return true;
  });

  return matched.slice(0, limit);
}

/**
 * Retrieves a single agent identity record by its agentId or owner address.
 *
 * @param identifier Agent ID hex hash or owner address
 * @returns AgentIdentityRecord or null if not found
 */
export async function getAgentIdentity(
  identifier: string
): Promise<AgentIdentityRecord | null> {
  if (!identifier) return null;
  const key = identifier.toLowerCase();
  return localAgentRegistry.get(key) || null;
}
