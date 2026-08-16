/**
 * Read-Only BNB Documentation & Ask AI Knowledge Adapter
 *
 * Provides contextual, search-indexed BNB Chain ecosystem documentation,
 * markdown reference citations, and strict read-only tool filtering to
 * prevent any unauthorized write or state-modifying operations.
 */

import { redactSecrets } from '../utils/redact.js';

export interface BNBDocEntry {
  id: string;
  title: string;
  keywords: string[];
  content: string;
  citation: string;
}

export interface BNBDocResponse {
  answer: string;
  citations: string[];
}

export interface QueryBNBOptions {
  customKnowledge?: BNBDocEntry[];
  includeOfficialFallback?: boolean;
}

/**
 * Built-in curated BNB Chain documentation index.
 */
export const BNB_DOCUMENTATION_KNOWLEDGE: BNBDocEntry[] = [
  {
    id: 'bsc-testnet',
    title: 'BNB Smart Chain (BSC) Testnet Configuration',
    keywords: [
      'bsc',
      'testnet',
      'chainid',
      '97',
      'tbnb',
      'faucet',
      'rpc',
      'network',
      'connect',
      'deploy',
    ],
    content:
      'BNB Smart Chain (BSC) Testnet operates with Chain ID 97 and uses tBNB for gas fees. ' +
      'Official RPC Endpoint: https://data-seed-prebsc-1-s1.binance.org:8545. ' +
      'Block Explorer: https://testnet.bscscan.com. ' +
      'Faucet for testnet funds: https://testnet.bnbchain.org/faucet-smart. ' +
      'Consensus uses Proof of Staked Authority (PoSA) with 3-second block finality.',
    citation: 'https://docs.bnbchain.org/docs/testnet/',
  },
  {
    id: 'bsc-mainnet',
    title: 'BNB Smart Chain (BSC) Mainnet Architecture',
    keywords: [
      'bsc',
      'mainnet',
      'chainid',
      '56',
      'bnb',
      'posa',
      'consensus',
      'architecture',
      'evm',
    ],
    content:
      'BNB Smart Chain Mainnet (Chain ID 56) is an EVM-compatible blockchain secured by Proof of Staked Authority (PoSA). ' +
      'It provides high throughput, fast 3-second block times, low transaction fees, and cross-chain capabilities. ' +
      'Block Explorer: https://bscscan.com.',
    citation: 'https://docs.bnbchain.org/docs/overview',
  },
  {
    id: 'opbnb',
    title: 'opBNB Layer 2 Optimistic Rollup',
    keywords: [
      'opbnb',
      'layer2',
      'l2',
      'rollup',
      'optimistic',
      'bedrock',
      '204',
      '5611',
      'scaling',
      'gas',
    ],
    content:
      'opBNB is a high-performance Layer 2 scaling solution for BSC built on the OP Stack (Bedrock). ' +
      'Mainnet Chain ID is 204 and Testnet Chain ID is 5611. ' +
      'opBNB delivers sub-cent gas fees and capacity for over 4,000 transactions per second (TPS).',
    citation: 'https://docs.bnbchain.org/docs/opbnb/overview',
  },
  {
    id: 'greenfield',
    title: 'BNB Greenfield Decentralized Storage',
    keywords: [
      'greenfield',
      'storage',
      'data',
      'sp',
      'storage provider',
      'decentralized',
      'bucket',
      'object',
    ],
    content:
      'BNB Greenfield is a decentralized data storage and computation network integrated with the BNB ecosystem. ' +
      'Users and smart contracts can own and monetize their data via Storage Providers (SPs) and bucket/object access policies.',
    citation: 'https://docs.bnbchain.org/docs/greenfield/overview',
  },
  {
    id: 'erc-8004',
    title: 'ERC-8004 Agent Identity Registry on BNB Chain',
    keywords: [
      'erc8004',
      'erc-8004',
      'agent',
      'identity',
      'registry',
      'discovery',
      'autonomous',
      'ai',
      'standards',
    ],
    content:
      'ERC-8004 provides a decentralized Agent Identity Registry for autonomous AI agents on BNB Chain. ' +
      'Agents register cryptographic identities, service endpoints, capability schemas, and trust attestations ' +
      'for discoverable machine-to-machine interactions on BSC Testnet and Mainnet.',
    citation: 'https://eips.ethereum.org/EIPS/eip-8004',
  },
  {
    id: 'erc-8056',
    title: 'ERC-8056 Scaled UI Amount Standard',
    keywords: [
      'erc8056',
      'erc-8056',
      'scaled',
      'ui',
      'amount',
      'precision',
      'balance',
      'token',
      'display',
    ],
    content:
      'ERC-8056 defines a standardized format for representing Scaled UI Amounts for Web3 tokens. ' +
      'It bridges atomic integer on-chain units with human-readable UI numbers across 18-decimal (and arbitrary decimal) ' +
      'BEP-20 assets without precision degradation or floating-point rounding errors.',
    citation: 'https://eips.ethereum.org/EIPS/eip-8056',
  },
  {
    id: 'x402',
    title: 'x402 Autonomous HTTP 402 Payment Protocol on BSC',
    keywords: [
      'x402',
      '402',
      'payment',
      'challenge',
      'micropayment',
      'autonomous',
      'http',
      'settlement',
      'agent',
    ],
    content:
      'x402 is an autonomous machine-to-machine payment protocol that handles HTTP 402 Payment Required challenges. ' +
      'Autonomous agents sign micro-transactions on BSC Testnet to pay for web APIs and agent-to-agent services ' +
      'and attach payment proof tokens to subsequent HTTP request headers.',
    citation: 'https://docs.bnbchain.org/docs/ai/x402',
  },
  {
    id: 'bep20',
    title: 'BEP-20 Fungible Token Standard',
    keywords: ['bep20', 'bep-20', 'token', 'standard', 'erc20', 'transfer', 'decimals'],
    content:
      'BEP-20 is the official token standard on BNB Smart Chain extending Ethereum ERC-20. ' +
      'It supports standard methods like name(), symbol(), decimals(), totalSupply(), balanceOf(), transfer(), and approve().',
    citation: 'https://docs.bnbchain.org/docs/bep20',
  },
];

const PRIVATE_KEY_PATTERN = /\b0x[0-9a-fA-F]{64}\b/g;
const RAW_HEX_KEY_PATTERN = /\b[0-9a-fA-F]{64}\b/g;
const URL_PATTERN = /^https?:\/\/[^\s$.?#].[^\s]*$/i;

/**
 * Known write verbs and patterns that must be filtered out or blocked
 * in read-only documentation execution contexts.
 */
const WRITE_TOOL_PATTERNS = [
  /^pay/i,
  /^transfer/i,
  /^send/i,
  /^register/i,
  /^sign/i,
  /^write/i,
  /^modify/i,
  /^update/i,
  /^delete/i,
  /^create/i,
  /^execute/i,
  /^withdraw/i,
  /^mint/i,
  /^approve/i,
  /^swap/i,
  /^deposit/i,
  /^burn/i,
  /^set/i,
  /^lock/i,
  /^unlock/i,
];

/**
 * Explicit known read-only tool names and prefixes.
 */
const READ_ONLY_TOOL_PATTERNS = [
  /^query/i,
  /^get/i,
  /^check/i,
  /^discover/i,
  /^estimate/i,
  /^search/i,
  /^verify/i,
  /^fetch/i,
  /^view/i,
  /^list/i,
  /^inspect/i,
  /^read/i,
  /^ask/i,
  /^find/i,
  /^lookup/i,
];

/**
 * Extracts a tool name from a generic tool definition or string.
 */
function extractToolName(
  tool: string | { name?: string; function?: { name?: string }; [key: string]: unknown }
): string {
  if (typeof tool === 'string') {
    return tool;
  }
  if (typeof tool?.name === 'string') {
    return tool.name;
  }
  if (typeof tool?.function?.name === 'string') {
    return tool.function.name;
  }
  return '';
}

/**
 * Checks if a tool or tool name is strictly read-only.
 */
export function isReadOnlyTool(
  tool: string | { name?: string; function?: { name?: string }; readonly?: boolean; [key: string]: unknown }
): boolean {
  if (typeof tool === 'object' && tool !== null) {
    if (typeof tool.readonly === 'boolean') {
      return tool.readonly;
    }
  }

  const name = extractToolName(tool);
  if (!name) return false;

  // Check write patterns first - fail closed
  for (const pattern of WRITE_TOOL_PATTERNS) {
    if (pattern.test(name)) {
      return false;
    }
  }

  // Check read patterns
  for (const pattern of READ_ONLY_TOOL_PATTERNS) {
    if (pattern.test(name)) {
      return true;
    }
  }

  return false;
}

/**
 * Asserts that a tool is read-only. Throws if the tool is modifying or write-capable.
 */
export function assertReadOnlyTool(
  tool: string | { name?: string; function?: { name?: string }; readonly?: boolean; [key: string]: unknown }
): void {
  if (!isReadOnlyTool(tool)) {
    const name = extractToolName(tool) || 'unknown';
    throw new Error(
      `Write operations are strictly disallowed in read-only adapter context for tool: ${name}`
    );
  }
}

/**
 * Filters out all write/modifying tool operations from a list of tools.
 */
export function filterReadOnlyTools<
  T extends { name?: string; function?: { name?: string }; readonly?: boolean; [key: string]: unknown }
>(tools: T[]): T[] {
  return tools.filter((tool) => isReadOnlyTool(tool));
}

/**
 * Sanitizes Ask AI / BNB documentation response, redacts accidental private secrets,
 * and formats verified markdown citations.
 */
export function sanitizeBNBResponse(rawAnswer: string, sources?: string[]): BNBDocResponse {
  if (!rawAnswer) {
    return { answer: '', citations: [] };
  }

  // Redact private keys and secrets
  let sanitized = rawAnswer
    .replace(PRIVATE_KEY_PATTERN, '[REDACTED_PRIVATE_KEY]')
    .replace(RAW_HEX_KEY_PATTERN, '[REDACTED_PRIVATE_KEY]');

  sanitized = redactSecrets(sanitized);

  // Filter and deduplicate valid URL sources
  const validCitations: string[] = [];
  if (Array.isArray(sources)) {
    for (const src of sources) {
      if (typeof src === 'string' && URL_PATTERN.test(src.trim())) {
        const cleanUrl = src.trim();
        if (!validCitations.includes(cleanUrl)) {
          validCitations.push(cleanUrl);
        }
      }
    }
  }

  // If citations exist and are not already formatted as a references section, format them in markdown
  if (validCitations.length > 0) {
    const hasReferencesSection =
      /###\s*References/i.test(sanitized) || /References\s*:/i.test(sanitized);

    if (!hasReferencesSection) {
      const referencesMarkdown = [
        '\n\n### References',
        ...validCitations.map((url) => `- [${url}](${url})`),
      ].join('\n');
      sanitized += referencesMarkdown;
    }
  }

  return {
    answer: sanitized,
    citations: validCitations,
  };
}

/**
 * Queries BNB Chain documentation and knowledge base in read-only mode.
 */
export async function queryBNBDocumentation(
  query: string,
  options?: QueryBNBOptions
): Promise<BNBDocResponse> {
  const normalizedQuery = query.toLowerCase().replace(/[^a-z0-9\s-]/g, ' ');
  const queryTerms = normalizedQuery.split(/\s+/).filter((term) => term.length > 1);

  const knowledgeBase = [
    ...(options?.customKnowledge || []),
    ...BNB_DOCUMENTATION_KNOWLEDGE,
  ];

  type ScoredEntry = { entry: BNBDocEntry; score: number };
  const scoredEntries: ScoredEntry[] = [];

  for (const entry of knowledgeBase) {
    let score = 0;

    // Check keyword hits
    for (const kw of entry.keywords) {
      const lowerKw = kw.toLowerCase();
      if (queryTerms.includes(lowerKw) || normalizedQuery.includes(lowerKw)) {
        score += 3;
      }
    }

    // Check title hits
    const titleTerms = entry.title.toLowerCase().split(/\s+/);
    for (const term of queryTerms) {
      if (titleTerms.includes(term)) {
        score += 2;
      } else if (entry.content.toLowerCase().includes(term)) {
        score += 1;
      }
    }

    if (score > 0) {
      scoredEntries.push({ entry, score });
    }
  }

  scoredEntries.sort((a, b) => b.score - a.score);

  if (scoredEntries.length > 0) {
    const topMatches = scoredEntries.slice(0, 3);
    const answers = topMatches.map((m) => `### ${m.entry.title}\n${m.entry.content}`);
    const citations = topMatches.map((m) => m.entry.citation);

    return sanitizeBNBResponse(answers.join('\n\n'), citations);
  }

  // Fallback response for unindexed queries
  const fallbackAnswer =
    `I could not find a specific documentation article matching "${query}". ` +
    `You can explore the official BNB Chain Documentation for guides on BSC, opBNB, Greenfield, and developer toolkits.`;
  const fallbackCitations = ['https://docs.bnbchain.org'];

  return sanitizeBNBResponse(fallbackAnswer, fallbackCitations);
}
