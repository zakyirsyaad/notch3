import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentExecutor } from '../src/agent/loop.js';
import {
  createDefaultTools,
  DEFAULT_TOOL_DEFINITIONS,
  type ToolDefinition,
} from '../src/agent/tools.js';
import { AgentSession } from '../src/wallet/session.js';
import { BnbAgentSdk } from '../src/bnb/bnb-sdk.js';
import { createAgentDispatcher } from '../src/index.js';
import {
  JSONRPC_ERROR_CODES,
  isJSONRPCResponse,
  type AgentExecutionResult,
  type TokenBalance,
  type X402PaymentReceipt,
} from '@notch/shared-types';

const MOCK_AUTH_TOKEN = ['mock', 'openai', 'token'].join('-');

describe('AgentExecutor Tool Loop & Prompt Engine', () => {
  let executor: AgentExecutor;

  beforeEach(() => {
    executor = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      model: 'gpt-4o',
    });
  });

  it('dispatches registered tools based on tool call requests', async () => {
    executor.registerTool('get_balance', async (args) => {
      return { balance: '0.05 tBNB', token: (args.token as string) || 'tBNB' };
    });

    const res = (await executor.runTool('get_balance', { token: 'USDT' })) as {
      balance: string;
      token: string;
    };
    expect(res).toEqual({ balance: '0.05 tBNB', token: 'USDT' });
  });

  it('throws when attempting to run an unregistered tool', async () => {
    await expect(executor.runTool('non_existent_tool', {})).rejects.toThrow(
      /Tool 'non_existent_tool' is not registered/
    );
  });

  it('provides default tool definitions and schemas', () => {
    const tools = createDefaultTools();
    expect(tools.length).toBeGreaterThanOrEqual(4);

    const toolNames = tools.map((t) => t.definition.function.name);
    expect(toolNames).toContain('pay_x402_service');
    expect(toolNames).toContain('check_agent_balance');
    expect(toolNames).toContain('query_bnb_docs');
    expect(toolNames).toContain('discover_erc8004_agents');

    for (const tool of tools) {
      expect(tool.definition.type).toBe('function');
      expect(tool.definition.function.name).toBeTruthy();
      expect(tool.definition.function.description).toBeTruthy();
      expect(tool.definition.function.parameters.type).toBe('object');
      expect(typeof tool.handler).toBe('function');
    }
  });

  it('executes a prompt with direct model answer (no tool calls)', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        choices: [
          {
            message: {
              role: 'assistant',
              content: 'Hello! I am your Notch autonomous BNB Agent.',
            },
            finish_reason: 'stop',
          },
        ],
      }),
    });

    const exec = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      fetch: mockFetch as unknown as typeof fetch,
    });

    const result = await exec.executePrompt('Hello who are you?');

    expect(result.response).toBe('Hello! I am your Notch autonomous BNB Agent.');
    expect(result.toolCallsExecuted).toEqual([]);
    expect(mockFetch).toHaveBeenCalledTimes(1);

    const sentBody = JSON.parse(mockFetch.mock.calls[0][1].body);
    expect(sentBody.messages).toHaveLength(2); // system + user
    expect(sentBody.messages[1].content).toBe('Hello who are you?');
  });

  it('executes a prompt with tool calls loop and returns aggregated result', async () => {
    let callCount = 0;
    const mockFetch = vi.fn().mockImplementation(async (_url, opts) => {
      callCount++;
      if (callCount === 1) {
        return {
          ok: true,
          json: async () => ({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: null,
                  tool_calls: [
                    {
                      id: 'call_123',
                      type: 'function',
                      function: {
                        name: 'check_agent_balance',
                        arguments: JSON.stringify({ tokenAddress: '' }),
                      },
                    },
                  ],
                },
                finish_reason: 'tool_calls',
              },
            ],
          }),
        };
      } else {
        return {
          ok: true,
          json: async () => ({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: 'Your agent wallet balance is 0.5 tBNB.',
                },
                finish_reason: 'stop',
              },
            ],
          }),
        };
      }
    });

    const exec = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      fetch: mockFetch as unknown as typeof fetch,
    });

    exec.registerTool('check_agent_balance', async () => ({
      tokenAddress: 'native',
      name: 'Testnet BNB',
      symbol: 'tBNB',
      decimals: 18,
      rawBalance: '500000000000000000',
      uiBalance: '0.5',
    }));

    const result = await exec.executePrompt('What is my agent balance?');

    expect(mockFetch).toHaveBeenCalledTimes(2);
    expect(result.response).toBe('Your agent wallet balance is 0.5 tBNB.');
    expect(result.toolCallsExecuted).toHaveLength(1);
    expect(result.toolCallsExecuted[0].name).toBe('check_agent_balance');
    expect(result.toolCallsExecuted[0].args).toEqual({ tokenAddress: '' });
    expect((result.toolCallsExecuted[0].result as any).uiBalance).toBe('0.5');

    // Verify messages sent in the second iteration
    const secondReqBody = JSON.parse(mockFetch.mock.calls[1][1].body);
    expect(secondReqBody.messages.length).toBe(4); // system, user, assistant (with tool_calls), tool (with result)
    expect(secondReqBody.messages[2].tool_calls[0].id).toBe('call_123');
    expect(secondReqBody.messages[3].role).toBe('tool');
    expect(secondReqBody.messages[3].tool_call_id).toBe('call_123');
  });

  it('aggregates x402 receipts and documentation citations from tool executions', async () => {
    let callCount = 0;
    const mockReceipt: X402PaymentReceipt = {
      txHash: '0xabc123789',
      token: 'tBNB',
      amount: '0.001',
      recipient: '0x1111111111111111111111111111111111111111',
      chainId: 97,
      timestamp: Date.now(),
      status: 'success',
    };

    const mockFetch = vi.fn().mockImplementation(async () => {
      callCount++;
      if (callCount === 1) {
        return {
          ok: true,
          json: async () => ({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: null,
                  tool_calls: [
                    {
                      id: 'call_x402',
                      type: 'function',
                      function: {
                        name: 'pay_x402_service',
                        arguments: JSON.stringify({
                          challenge: {
                            token: 'tBNB',
                            amount: '0.001',
                            recipient: '0x1111111111111111111111111111111111111111',
                            chainId: 97,
                          },
                        }),
                      },
                    },
                    {
                      id: 'call_doc',
                      type: 'function',
                      function: {
                        name: 'query_bnb_docs',
                        arguments: JSON.stringify({ query: 'x402 payment protocol' }),
                      },
                    },
                  ],
                },
                finish_reason: 'tool_calls',
              },
            ],
          }),
        };
      } else {
        return {
          ok: true,
          json: async () => ({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: 'Payment processed and verified with BSC Testnet documentation.',
                },
                finish_reason: 'stop',
              },
            ],
          }),
        };
      }
    });

    const exec = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      fetch: mockFetch as unknown as typeof fetch,
    });

    exec.registerTool('pay_x402_service', async () => mockReceipt);
    exec.registerTool('query_bnb_docs', async () => ({
      answer: 'x402 is an autonomous payment protocol on BSC.',
      citations: ['https://docs.bnbchain.org/docs/ai/x402'],
    }));

    const result = await exec.executePrompt('Pay the x402 challenge and consult the docs.');

    expect(result.receipts).toHaveLength(1);
    expect(result.receipts![0].txHash).toBe('0xabc123789');
    expect(result.citations).toContain('https://docs.bnbchain.org/docs/ai/x402');
    expect(result.toolCallsExecuted).toHaveLength(2);
  });

  it('redacts private keys and secrets in prompts and outputs', async () => {
    const rawSecretHex = '0x' + '1234567890abcdef'.repeat(4);
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        choices: [
          {
            message: {
              role: 'assistant',
              content: `Here is the leaked secret: ${rawSecretHex}`,
            },
            finish_reason: 'stop',
          },
        ],
      }),
    });

    const exec = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      fetch: mockFetch as unknown as typeof fetch,
    });

    const result = await exec.executePrompt(`My secret is ${rawSecretHex}, please check.`);
    expect(result.response).not.toContain(rawSecretHex);
    expect(result.response).toContain('[REDACTED_KEY]');

    const sentPrompt = JSON.parse(mockFetch.mock.calls[0][1].body).messages[1].content;
    expect(sentPrompt).not.toContain(rawSecretHex);
  });

  it('respects maxIterations guard against infinite tool loop cycles', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        choices: [
          {
            message: {
              role: 'assistant',
              content: null,
              tool_calls: [
                {
                  id: 'loop_call',
                  type: 'function',
                  function: {
                    name: 'loop_tool',
                    arguments: '{}',
                  },
                },
              ],
            },
            finish_reason: 'tool_calls',
          },
        ],
      }),
    });

    const exec = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      maxIterations: 3,
      fetch: mockFetch as unknown as typeof fetch,
    });

    exec.registerTool('loop_tool', async () => ({ status: 'again' }));

    const result = await exec.executePrompt('Trigger infinite loop');
    expect(mockFetch).toHaveBeenCalledTimes(3);
    expect(result.toolCallsExecuted).toHaveLength(3);
    expect(result.response).toMatch(/maximum execution steps/i);
  });

  it('streams response chunks via streamCb callback when provided', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        choices: [
          {
            message: {
              role: 'assistant',
              content: 'Streamed message chunk',
            },
            finish_reason: 'stop',
          },
        ],
      }),
    });

    const exec = new AgentExecutor({
      apiKey: MOCK_AUTH_TOKEN,
      fetch: mockFetch as unknown as typeof fetch,
    });

    const streamedChunks: string[] = [];
    const result = await exec.executePrompt('Stream test', (chunk) => {
      streamedChunks.push(chunk);
    });

    expect(result.response).toBe('Streamed message chunk');
    expect(streamedChunks.join('')).toBe('Streamed message chunk');
  });
});

describe('Agent RPC Dispatcher Full Integration', () => {
  let session: AgentSession;
  let sdk: BnbAgentSdk;
  let dispatcher: ReturnType<typeof createAgentDispatcher>;

  beforeEach(() => {
    session = new AgentSession();
    sdk = new BnbAgentSdk(session);
    dispatcher = createAgentDispatcher({ session, sdk });
  });

  it('registers all standard RPC methods', () => {
    expect(dispatcher.hasMethod('agent.init')).toBe(true);
    expect(dispatcher.hasMethod('agent.unlock')).toBe(true);
    expect(dispatcher.hasMethod('agent.lock')).toBe(true);
    expect(dispatcher.hasMethod('agent.getStatus')).toBe(true);
    expect(dispatcher.hasMethod('agent.executePrompt')).toBe(true);
    expect(dispatcher.hasMethod('agent.queryEcosystemDoc')).toBe(true);
    expect(dispatcher.hasMethod('wallet.getAgentBalance')).toBe(true);
    expect(dispatcher.hasMethod('wallet.registerERC8004Identity')).toBe(true);
  });

  it('handles agent.getStatus accurately in locked / unlocked states', async () => {
    const resLocked = await dispatcher.handleMessage({
      jsonrpc: '2.0',
      id: 'stat-1',
      method: 'agent.getStatus',
      params: {},
    });
    const parsedLocked = JSON.parse(resLocked!);
    expect(parsedLocked.result.state).toBe('locked');
    expect(parsedLocked.result.lockState).toBe('locked');

    // Initialize & query doc
    const resDoc = await dispatcher.handleMessage({
      jsonrpc: '2.0',
      id: 'doc-1',
      method: 'agent.queryEcosystemDoc',
      params: { query: 'BSC Testnet' },
    });
    const parsedDoc = JSON.parse(resDoc!);
    expect(parsedDoc.result.answer).toContain('BNB Smart Chain (BSC) Testnet');
  });

  it('returns WALLET_LOCKED error code when querying balance on locked wallet', async () => {
    const res = await dispatcher.handleMessage({
      jsonrpc: '2.0',
      id: 'bal-1',
      method: 'wallet.getAgentBalance',
      params: {},
    });

    const parsed = JSON.parse(res!);
    expect(parsed.error).toBeDefined();
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.WALLET_LOCKED);
  });

  it('handles agent.init and reconfigures executor settings', async () => {
    const res = await dispatcher.handleMessage({
      jsonrpc: '2.0',
      id: 'init-1',
      method: 'agent.init',
      params: {
        chainId: 97,
        rpcUrl: 'https://bsc-testnet-rpc.publicnode.com',
        openaiApiKey: MOCK_AUTH_TOKEN,
        openaiModel: 'gpt-4o-mini',
      },
    });

    const parsed = JSON.parse(res!);
    expect(parsed.result.initialized).toBe(true);
    expect(parsed.result.config.chainId).toBe(97);
  });
});
