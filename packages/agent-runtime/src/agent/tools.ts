/**
 * Autonomous AI Agent Tool Definitions & Registry
 *
 * Implements OpenAI-compatible tool definitions and execution handlers
 * for x402 payment challenges, balance queries, ecosystem documentation,
 * and ERC-8004 agent identity discovery.
 */

import type {
  TokenBalance,
  X402PaymentChallenge,
  X402PaymentReceipt,
} from '@notch/shared-types';
import type { AgentSession } from '../wallet/session.js';
import { BnbAgentSdk } from '../bnb/bnb-sdk.js';
import { queryBNBDocumentation, type BNBDocResponse } from '../bnb/ask-ai.js';
import type { AgentIdentityRecord, DiscoverAgentsFilter } from '../bnb/erc8004.js';

export interface ToolParameterProperty {
  type: string;
  description?: string;
  enum?: string[];
  items?: Record<string, unknown>;
}

export interface ToolParametersSchema {
  type: 'object';
  properties: Record<string, ToolParameterProperty>;
  required?: string[];
}

export interface ToolDefinition {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters: ToolParametersSchema;
  };
}

export type ToolHandler = (
  args: Record<string, unknown>
) => Promise<unknown> | unknown;

export interface RegisteredTool {
  definition: ToolDefinition;
  handler: ToolHandler;
}

export const PAY_X402_TOOL_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: 'pay_x402_service',
    description:
      'Executes an autonomous x402 payment challenge settlement on BSC Testnet (tBNB or BEP-20) using the unlocked agent wallet session.',
    parameters: {
      type: 'object',
      properties: {
        challenge: {
          type: 'object',
          description:
            'The parsed x402 payment challenge containing token, amount, recipient, and chainId.',
        },
        token: {
          type: 'string',
          description: 'Token address or symbol (e.g. tBNB, USDT, 0x...).',
        },
        amount: {
          type: 'string',
          description: 'Payment amount in scaled UI units (e.g. "0.001").',
        },
        recipient: {
          type: 'string',
          description: 'Recipient EVM address (0x...).',
        },
        chainId: {
          type: 'number',
          description: 'Chain ID (defaults to 97 for BSC Testnet).',
        },
        resource: {
          type: 'string',
          description: 'Optional resource identifier or URI being paid for.',
        },
      },
    },
  },
};

export const CHECK_BALANCE_TOOL_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: 'check_agent_balance',
    description:
      'Queries the current agent wallet balance on BSC Testnet (native tBNB or ERC-20 / ERC-8056 token).',
    parameters: {
      type: 'object',
      properties: {
        tokenAddress: {
          type: 'string',
          description:
            'Optional BEP-20 / ERC-8056 token contract address. Omit or leave empty for native tBNB.',
        },
      },
    },
  },
};

export const QUERY_BNB_DOCS_TOOL_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: 'query_bnb_docs',
    description:
      'Queries read-only documentation and knowledge base for the BNB Chain ecosystem (BSC, opBNB, Greenfield, ERC-8004, ERC-8056, x402).',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description:
            'Search query or question about BNB Chain, smart contracts, tooling, or protocols.',
        },
      },
      required: ['query'],
    },
  },
};

export const DISCOVER_AGENTS_TOOL_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: 'discover_erc8004_agents',
    description:
      'Discovers registered autonomous AI agents and services in the ERC-8004 registry on BSC Testnet.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Optional name, skill, or capability keyword filter.',
        },
        tags: {
          type: 'array',
          description: 'Optional list of tag strings to filter agents by.',
        },
        limit: {
          type: 'number',
          description: 'Maximum number of agent records to return.',
        },
        offset: {
          type: 'number',
          description: 'Offset for pagination.',
        },
      },
    },
  },
};

export const DEFAULT_TOOL_DEFINITIONS: ToolDefinition[] = [
  PAY_X402_TOOL_DEFINITION,
  CHECK_BALANCE_TOOL_DEFINITION,
  QUERY_BNB_DOCS_TOOL_DEFINITION,
  DISCOVER_AGENTS_TOOL_DEFINITION,
];

export interface CreateDefaultToolsOptions {
  session?: AgentSession;
  sdk?: BnbAgentSdk;
}

/**
 * Creates the standard default tool suite wired to active SDK and Session instances.
 */
export function createDefaultTools(
  options?: CreateDefaultToolsOptions
): RegisteredTool[] {
  const session = options?.session;
  const sdk = options?.sdk || (session ? new BnbAgentSdk(session) : undefined);

  return [
    {
      definition: PAY_X402_TOOL_DEFINITION,
      handler: async (args: Record<string, unknown>): Promise<X402PaymentReceipt> => {
        if (!sdk) {
          throw new Error(
            'Agent SDK or session is not available. Please unlock the agent wallet before executing payments.'
          );
        }

        let challenge: X402PaymentChallenge;
        if (args.challenge && typeof args.challenge === 'object') {
          challenge = args.challenge as X402PaymentChallenge;
        } else if (typeof args.challenge === 'string') {
          challenge = JSON.parse(args.challenge);
        } else {
          challenge = {
            token: (args.token as string) || 'tBNB',
            amount: (args.amount as string) || '0',
            recipient: (args.recipient as string) || '',
            chainId: (args.chainId as number) || sdk.chainId,
            resource: args.resource as string | undefined,
          };
        }

        return sdk.payX402(challenge);
      },
    },
    {
      definition: CHECK_BALANCE_TOOL_DEFINITION,
      handler: async (args: Record<string, unknown>): Promise<TokenBalance> => {
        if (!sdk) {
          throw new Error(
            'Agent SDK or session is not available. Please unlock the agent wallet before checking balances.'
          );
        }
        const tokenAddress = (args.tokenAddress as string) || undefined;
        return sdk.getBalance(tokenAddress);
      },
    },
    {
      definition: QUERY_BNB_DOCS_TOOL_DEFINITION,
      handler: async (args: Record<string, unknown>): Promise<BNBDocResponse> => {
        const query = (args.query as string) || '';
        return queryBNBDocumentation(query);
      },
    },
    {
      definition: DISCOVER_AGENTS_TOOL_DEFINITION,
      handler: async (
        args: Record<string, unknown>
      ): Promise<AgentIdentityRecord[]> => {
        if (!sdk) {
          return [];
        }
        const filter: DiscoverAgentsFilter = {
          query: args.query as string | undefined,
          tags: Array.isArray(args.tags) ? (args.tags as string[]) : undefined,
          limit: typeof args.limit === 'number' ? args.limit : undefined,
          chainId: typeof args.chainId === 'number' ? args.chainId : undefined,
        };
        return sdk.discover(filter);
      },
    },
  ];
}
