import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { PassThrough } from 'node:stream';
import { Wallet, ZeroAddress, parseEther, Interface } from 'ethers';
import {
  createAgentDispatcher,
  RPCTransport,
  AgentSession,
  BnbAgentSdk,
  AgentExecutor,
  createDefaultTools,
  parseX402Challenge,
  executeX402Payment,
  createX402PaymentHeaders,
  redactSecrets,
} from '@notch/agent-runtime';
import {
  JSONRPC_ERROR_CODES,
  type AgentStatus,
  type AgentExecutionResult,
  type TokenBalance,
  type X402PaymentChallenge,
  type X402PaymentReceipt,
  type JSONRPCRequest,
  type JSONRPCResponse,
} from '@notch/shared-types';
import {
  startMockX402Server,
  createMockX402Server,
  DEFAULT_MOCK_X402_CONFIG,
  type MockX402ServerInstance,
} from '../mocks/mock-x402-server.js';

const TEST_PASSWORD = ['super', 'secret', 'master', 'password', '123'].join('-');
const TEST_RECIPIENT = '0x1111111111111111111111111111111111111111';
const TEST_CUSTOM_TOKEN = '0x2222222222222222222222222222222222222222';

async function sendRpcRequest<TResult = any, TParams = any>(
  dispatcher: ReturnType<typeof createAgentDispatcher>,
  method: string,
  params?: TParams,
  id: string | number = 1
): Promise<JSONRPCResponse<TResult>> {
  const raw = await dispatcher.handleMessage({
    jsonrpc: '2.0',
    id,
    method,
    params,
  });
  return JSON.parse(raw as string) as JSONRPCResponse<TResult>;
}

describe('End-to-End Integration Suite: Notch BNB Autonomous Agent', () => {
  let mockServer: MockX402ServerInstance | null = null;

  afterEach(async () => {
    if (mockServer) {
      await mockServer.close();
      mockServer = null;
    }
    vi.restoreAllMocks();
  });

  describe('1. Subprocess IPC & JSON-RPC 2.0 Transport', () => {
    it('dispatches JSON-RPC requests, notifications, and responses across duplex stream pipes', async () => {
      const stdinStream = new PassThrough();
      const stdoutStream = new PassThrough();

      const session = new AgentSession();
      const dispatcher = createAgentDispatcher({ session });

      const transport = new RPCTransport({
        input: stdinStream,
        output: stdoutStream,
        dispatcher,
      });

      transport.start();

      const responses: string[] = [];
      stdoutStream.on('data', (chunk: Buffer) => {
        const lines = chunk.toString().split('\n').filter((l) => l.trim().length > 0);
        responses.push(...lines);
      });

      // 1. Initial status query via RPC stream
      const req1: JSONRPCRequest = {
        jsonrpc: '2.0',
        id: 1,
        method: 'agent.getStatus',
      };
      stdinStream.write(JSON.stringify(req1) + '\n');

      // Allow event loop to process
      await new Promise((resolve) => setTimeout(resolve, 50));

      expect(responses.length).toBeGreaterThanOrEqual(1);
      const res1 = JSON.parse(responses[0]);
      expect(res1.id).toBe(1);
      expect(res1.result.lockState).toBe('locked');
      expect(res1.result.state).toBe('locked');

      // 2. Notification sending across transport
      transport.sendNotification('agent/statusChanged', { status: 'testing' });
      await new Promise((resolve) => setTimeout(resolve, 50));

      const notifMsg = responses.find((r) => r.includes('agent/statusChanged'));
      expect(notifMsg).toBeDefined();
      const notifParsed = JSON.parse(notifMsg!);
      expect(notifParsed.method).toBe('agent/statusChanged');
      expect(notifParsed.id).toBeUndefined();

      // 3. Error on malformed JSON
      stdinStream.write('invalid-json-payload-line\n');
      await new Promise((resolve) => setTimeout(resolve, 50));

      const parseErrorMsg = responses.find((r) => r.includes(String(JSONRPC_ERROR_CODES.PARSE_ERROR)));
      expect(parseErrorMsg).toBeDefined();

      // 4. Error on unknown method
      const reqUnknown: JSONRPCRequest = {
        jsonrpc: '2.0',
        id: 99,
        method: 'nonExistentMethod',
      };
      stdinStream.write(JSON.stringify(reqUnknown) + '\n');
      await new Promise((resolve) => setTimeout(resolve, 50));

      const notFoundMsg = responses.find((r) => r.includes(String(JSONRPC_ERROR_CODES.METHOD_NOT_FOUND)));
      expect(notFoundMsg).toBeDefined();

      transport.stop();
    });
  });

  describe('2. Agent Lifecycle, Wallet Management & Kill Switch Verification', () => {
    let session: AgentSession;
    let dispatcher: ReturnType<typeof createAgentDispatcher>;
    let testWallet: Wallet;
    let keystoreJson: string;

    beforeEach(async () => {
      session = new AgentSession();
      dispatcher = createAgentDispatcher({ session });
      testWallet = Wallet.createRandom();
      keystoreJson = await testWallet.encrypt(TEST_PASSWORD);
    });

    it('manages full lifecycle: locked -> init -> unlock -> active -> locked (kill switch)', async () => {
      // 1. Initial State: Locked
      const initialStatusRes = await sendRpcRequest<AgentStatus>(dispatcher, 'agent.getStatus');
      expect(initialStatusRes.result?.lockState).toBe('locked');
      expect(initialStatusRes.result?.state).toBe('locked');

      // Attempting wallet balance query while locked throws WALLET_LOCKED
      const lockedBalRes = await sendRpcRequest(dispatcher, 'wallet.getAgentBalance');
      expect(lockedBalRes.error?.code).toBe(JSONRPC_ERROR_CODES.WALLET_LOCKED);

      // Attempting ERC-8004 identity registration while locked throws WALLET_LOCKED
      const lockedIdRes = await sendRpcRequest(dispatcher, 'wallet.registerERC8004Identity', {
        name: 'AgentX',
      });
      expect(lockedIdRes.error?.code).toBe(JSONRPC_ERROR_CODES.WALLET_LOCKED);

      // 2. Initialize Agent with Config
      const initRes = await sendRpcRequest<{ initialized: boolean; config: any }>(dispatcher, 'agent.init', {
        chainId: 97,
        rpcUrl: 'https://data-seed-prebsc-1-s1.binance.org:8545',
        agentName: 'NotchIntegrationAgent',
        customPrompt: 'Autonomous BNB chain integration agent.',
      });

      expect(initRes.result?.initialized).toBe(true);
      expect(initRes.result?.config?.agentName).toBe('NotchIntegrationAgent');

      // 3. Unlock with Invalid Password fails
      const failedUnlockRes = await sendRpcRequest(dispatcher, 'agent.unlock', {
        keystoreJson,
        passphrase: 'wrong-password',
      });
      expect(failedUnlockRes.error?.code).toBe(JSONRPC_ERROR_CODES.UNAUTHORIZED);

      // 4. Unlock with Valid Password succeeds
      const unlockRes = await sendRpcRequest<{ address: string; unlocked: boolean }>(dispatcher, 'agent.unlock', {
        keystoreJson,
        passphrase: TEST_PASSWORD,
      });

      expect(unlockRes.result?.unlocked).toBe(true);
      expect(unlockRes.result?.address.toLowerCase()).toBe(testWallet.address.toLowerCase());

      // 5. Query status when active/unlocked
      const activeStatusRes = await sendRpcRequest<AgentStatus>(dispatcher, 'agent.getStatus');
      expect(activeStatusRes.result?.lockState).toBe('unlocked');
      expect(activeStatusRes.result?.state).toBe('active');
      expect(activeStatusRes.result?.address?.toLowerCase()).toBe(testWallet.address.toLowerCase());

      // 6. Kill Switch: Issue agent.lock
      const lockRes = await sendRpcRequest<{ locked: boolean }>(dispatcher, 'agent.lock');
      expect(lockRes.result?.locked).toBe(true);

      // 7. Verify status transitioned back to locked
      const postLockStatusRes = await sendRpcRequest<AgentStatus>(dispatcher, 'agent.getStatus');
      expect(postLockStatusRes.result?.lockState).toBe('locked');
      expect(postLockStatusRes.result?.state).toBe('locked');

      // 8. Verify wallet operations are blocked again
      const relockedBalRes = await sendRpcRequest(dispatcher, 'wallet.getAgentBalance');
      expect(relockedBalRes.error?.code).toBe(JSONRPC_ERROR_CODES.WALLET_LOCKED);
    });

    it('redacts private keys and passwords from error messages and logs', () => {
      const privateKey = '0x' + Array(64).fill('a').join('');
      const sampleText = `Error occurred with key: ${privateKey} and password: ${TEST_PASSWORD}`;
      const redacted = redactSecrets(sampleText);

      expect(redacted).not.toContain(privateKey);
      expect(redacted).toContain('[REDACTED_KEY]');
    });
  });

  describe('3. End-to-End x402 Payment Flow & Challenge Settlement', () => {
    it('executes full challenge -> settlement -> re-request workflow against live mock x402 HTTP server', async () => {
      // 1. Start mock x402 server
      mockServer = await startMockX402Server({
        token: 'tBNB',
        amount: '0.001',
        recipient: TEST_RECIPIENT,
        chainId: 97,
        resource: '/api/v1/forecast',
        description: 'BNB Ecosystem Forecast',
        responseData: { success: true, forecast: 'Bullish on BNB ecosystem AI agents' },
      });

      // 2. Prepare unlocked agent wallet session
      const session = new AgentSession();
      const testWallet = Wallet.createRandom();
      const keystoreJson = await testWallet.encrypt(TEST_PASSWORD);
      await session.unlock(keystoreJson, TEST_PASSWORD);

      // 3. Make initial unauthenticated request -> Expect HTTP 402
      const initialResponse = await fetch(mockServer.url);
      expect(initialResponse.status).toBe(402);

      const challengeHeaders: Record<string, string> = {};
      initialResponse.headers.forEach((value, key) => {
        challengeHeaders[key.toLowerCase()] = value;
      });

      const bodyText = await initialResponse.text();

      // 4. Client parses the HTTP 402 challenge
      const challenge = parseX402Challenge(challengeHeaders, bodyText);
      expect(challenge.token).toBe('tBNB');
      expect(challenge.amount).toBe('0.001');
      expect(challenge.recipient).toBe(TEST_RECIPIENT);
      expect(challenge.chainId).toBe(97);

      // 5. Mock BSC blockchain provider to simulate instant transaction broadcast and block inclusion
      const mockTxHash = '0xabcdef9876543210abcdef9876543210abcdef9876543210abcdef9876543210';
      const mockProvider = {
        getBalance: vi.fn().mockResolvedValue(parseEther('1.0')),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
        estimateGas: vi.fn().mockResolvedValue(21000n),
        getFeeData: vi.fn().mockResolvedValue({
          gasPrice: 1000000000n,
          maxFeePerGas: 2000000000n,
          maxPriorityFeePerGas: 1000000000n,
        }),
      } as any;

      // Mock signer's sendTransaction to return mock transaction receipt
      const originalGetSigner = session.getSigner.bind(session);
      vi.spyOn(session, 'getSigner').mockImplementation(() => {
        const originalSigner = originalGetSigner();
        return {
          ...originalSigner,
          connect: (_p: any) => ({
            ...originalSigner,
            sendTransaction: vi.fn().mockResolvedValue({
              hash: mockTxHash,
              wait: vi.fn().mockResolvedValue({
                hash: mockTxHash,
                blockNumber: 1234567,
                status: 1,
              }),
            }),
          }),
        } as any;
      });

      // 6. Settle x402 payment
      const receipt = await executeX402Payment(challenge, session, {
        provider: mockProvider,
        maxAmount: '0.1',
        allowedTokens: ['tBNB'],
        allowedChainIds: [97],
      });

      expect(receipt.status).toBe('success');
      expect(receipt.txHash).toBe(mockTxHash);
      expect(receipt.amount).toBe('0.001');
      expect(receipt.token).toBe('tBNB');
      expect(receipt.recipient).toBe(TEST_RECIPIENT);
      expect(receipt.blockNumber).toBe(1234567);
      expect(receipt.timestamp).toBeGreaterThan(0);

      // 7. Create authorization headers with settlement proof
      const paymentHeaders = createX402PaymentHeaders(receipt);
      expect(paymentHeaders['Authorization']).toBe(`x402 ${mockTxHash}`);

      // 8. Re-request endpoint with payment headers -> Expect HTTP 200 OK
      const paidResponse = await fetch(mockServer.url, {
        headers: paymentHeaders,
      });

      expect(paidResponse.status).toBe(200);
      const paidData = await paidResponse.json();
      expect(paidData).toEqual({
        success: true,
        forecast: 'Bullish on BNB ecosystem AI agents',
      });

      // Verify server telemetry
      expect(mockServer.getRequestCount()).toBe(2);
      expect(mockServer.getPaidRequestCount()).toBe(1);
      expect(mockServer.getLastAuthHeader()).toBe(`x402 ${mockTxHash}`);
    });

    it('settles custom ERC-8056 token payments with scaled amounts', async () => {
      const session = new AgentSession();
      const testWallet = Wallet.createRandom();
      const keystoreJson = await testWallet.encrypt(TEST_PASSWORD);
      await session.unlock(keystoreJson, TEST_PASSWORD);

      const mockTxHash = '0x8888888888888888888888888888888888888888888888888888888888888888';
      const mockTx = {
        hash: mockTxHash,
        wait: vi.fn().mockResolvedValue({
          status: 1,
          blockNumber: 987654,
          hash: mockTxHash,
        }),
      };

      const mockProvider = {
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
        estimateGas: vi.fn().mockResolvedValue(50000n),
        getFeeData: vi.fn().mockResolvedValue({
          gasPrice: 1000000000n,
          maxFeePerGas: 2000000000n,
          maxPriorityFeePerGas: 1000000000n,
        }),
        getTransactionReceipt: vi.fn().mockResolvedValue({
          status: 1,
          blockNumber: 987654,
          hash: mockTxHash,
          logs: [],
        }),
      } as any;

      const originalGetSigner = session.getSigner.bind(session);
      vi.spyOn(session, 'getSigner').mockImplementation(() => {
        const originalSigner = originalGetSigner();
        return {
          ...originalSigner,
          connect: (_p: any) => ({
            ...originalSigner,
            getAddress: vi.fn().mockResolvedValue(testWallet.address),
            sendTransaction: vi.fn().mockResolvedValue(mockTx),
            provider: mockProvider,
          }),
        } as any;
      });

      // Mock contract calls for balance
      const iface = new Interface([
        'function name() view returns (string)',
        'function symbol() view returns (string)',
        'function decimals() view returns (uint8)',
        'function multiplier() view returns (uint256)',
        'function balanceOf(address) view returns (uint256)',
      ]);

      mockProvider.call = vi.fn().mockImplementation(async (tx: { data: string }) => {
        const sig = tx.data.slice(0, 10);
        if (sig === iface.getFunction('name')!.selector) {
          return iface.encodeFunctionResult('name', ['Mock Scaled Token']);
        }
        if (sig === iface.getFunction('symbol')!.selector) {
          return iface.encodeFunctionResult('symbol', ['MST']);
        }
        if (sig === iface.getFunction('decimals')!.selector) {
          return iface.encodeFunctionResult('decimals', [18]);
        }
        if (sig === iface.getFunction('multiplier')!.selector) {
          return iface.encodeFunctionResult('multiplier', [1000n]);
        }
        if (sig === iface.getFunction('balanceOf')!.selector) {
          // 100 scaled tokens: 100 * 10^36 / 1000 = 10^35 raw units
          return iface.encodeFunctionResult('balanceOf', [100000000000000000000000000000000000n]);
        }
        return '0x';
      });

      const challenge: X402PaymentChallenge = {
        token: TEST_CUSTOM_TOKEN,
        amount: '5.0',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      const receipt = await executeX402Payment(challenge, session, {
        provider: mockProvider,
        allowedTokens: [TEST_CUSTOM_TOKEN],
      });

      expect(receipt.status).toBe('success');
      expect(receipt.token).toBe(TEST_CUSTOM_TOKEN);
      expect(receipt.amount).toBe('5.0');
      expect(receipt.recipient).toBe(TEST_RECIPIENT);
      expect(receipt.txHash).toBe(mockTxHash);
    });

    it('rejects payments when amount exceeds configured safety limits', async () => {
      mockServer = await startMockX402Server({
        amount: '5.0', // Large amount exceeding safety threshold
      });

      const session = new AgentSession();
      const testWallet = Wallet.createRandom();
      const keystoreJson = await testWallet.encrypt(TEST_PASSWORD);
      await session.unlock(keystoreJson, TEST_PASSWORD);

      const res = await fetch(mockServer.url);
      const headers: Record<string, string> = {};
      res.headers.forEach((v, k) => (headers[k.toLowerCase()] = v));
      const challenge = parseX402Challenge(headers);

      await expect(
        executeX402Payment(challenge, session, {
          maxAmount: '0.5', // Lower safety limit
        })
      ).rejects.toThrow(/exceeds maximum allowed limit/i);
    });
  });

  describe('4. Autonomous AI Tool Execution Loop & Multi-Step Reasoning', () => {
    it('executes AI tool calls for balance checking and x402 payment in response to user prompt', async () => {
      mockServer = await startMockX402Server({
        token: 'tBNB',
        amount: '0.002',
        recipient: TEST_RECIPIENT,
        chainId: 97,
        responseData: { success: true, data: 'Exclusive Analytics Report' },
      });

      const session = new AgentSession();
      const testWallet = Wallet.createRandom();
      const keystoreJson = await testWallet.encrypt(TEST_PASSWORD);
      await session.unlock(keystoreJson, TEST_PASSWORD);

      const mockTxHash = '0x7777777777777777777777777777777777777777777777777777777777777777';

      const sdk = new BnbAgentSdk(session, { chainId: 97 });
      vi.spyOn(sdk, 'getBalance').mockResolvedValue({
        tokenAddress: ZeroAddress,
        name: 'BNB',
        symbol: 'tBNB',
        decimals: 18,
        rawBalance: parseEther('2.5').toString(),
        uiBalance: '2.5',
      });

      vi.spyOn(sdk, 'payX402').mockResolvedValue({
        txHash: mockTxHash,
        token: 'tBNB',
        amount: '0.002',
        recipient: TEST_RECIPIENT,
        chainId: 97,
        timestamp: Date.now(),
        status: 'success',
      });

      // Simulate OpenAI Chat Completions API with 2 iterations:
      // Iteration 1: Calls check_agent_balance and pay_x402_service
      // Iteration 2: Returns final natural language answer
      let callCount = 0;
      const mockCustomFetch = vi.fn().mockImplementation(async (_url: string, _init?: RequestInit) => {
        callCount++;
        if (callCount === 1) {
          return {
            ok: true,
            status: 200,
            json: async () => ({
              id: 'chatcmpl-step-1',
              choices: [
                {
                  finish_reason: 'tool_calls',
                  message: {
                    role: 'assistant',
                    content: null,
                    tool_calls: [
                      {
                        id: 'call_1',
                        type: 'function',
                        function: {
                          name: 'check_agent_balance',
                          arguments: '{}',
                        },
                      },
                      {
                        id: 'call_2',
                        type: 'function',
                        function: {
                          name: 'pay_x402_service',
                          arguments: JSON.stringify({
                            token: 'tBNB',
                            amount: '0.002',
                            recipient: TEST_RECIPIENT,
                            chainId: 97,
                            resource: '/api/v1/forecast',
                          }),
                        },
                      },
                    ],
                  },
                },
              ],
            }),
          };
        } else {
          return {
            ok: true,
            status: 200,
            json: async () => ({
              id: 'chatcmpl-step-2',
              choices: [
                {
                  finish_reason: 'stop',
                  message: {
                    role: 'assistant',
                    content: `I checked your wallet balance (2.5 tBNB) and settled the 0.002 tBNB payment for the Exclusive Analytics Report.`,
                  },
                },
              ],
            }),
          };
        }
      });

      const executor = new AgentExecutor({
        apiKey: process.env.TEST_API_KEY ?? 'mock-key',
        session,
        sdk,
        fetch: mockCustomFetch as any,
      });

      const dispatcher = createAgentDispatcher({
        session,
        sdk,
        executor,
      });

      // Execute prompt through JSON-RPC agent.executePrompt
      const response = await sendRpcRequest<AgentExecutionResult>(dispatcher, 'agent.executePrompt', {
        prompt: 'Check my balance and purchase the Exclusive Analytics Report.',
      });

      expect(response.error).toBeUndefined();
      expect(response.result).toBeDefined();

      const result = response.result!;
      expect(result.response).toContain('Exclusive Analytics Report');

      // Verify tool calls recorded
      expect(result.toolCallsExecuted.length).toBe(2);
      expect(result.toolCallsExecuted[0].name).toBe('check_agent_balance');
      expect(result.toolCallsExecuted[1].name).toBe('pay_x402_service');

      // Verify payment receipt collected in execution result
      expect(result.receipts).toBeDefined();
      expect(result.receipts!.length).toBe(1);
      expect(result.receipts![0].txHash).toBe(mockTxHash);
      expect(result.receipts![0].amount).toBe('0.002');
      expect(result.receipts![0].status).toBe('success');
    });
  });

  describe('5. Ecosystem Knowledge & Identity Discovery', () => {
    it('queries read-only ecosystem documentation and returns structured markdown citations', async () => {
      const session = new AgentSession();
      const dispatcher = createAgentDispatcher({ session });

      const res = await sendRpcRequest<{ answer: string; citations: string[] }>(dispatcher, 'agent.queryEcosystemDoc', {
        query: 'What is x402 HTTP payment on BSC?',
      });

      expect(res.error).toBeUndefined();
      expect(res.result).toBeDefined();
      expect(res.result!.answer).toContain('x402');
      expect(res.result!.citations).toBeDefined();
      expect(res.result!.citations.length).toBeGreaterThan(0);
    });

    it('registers and discovers ERC-8004 agent identities across the runtime', async () => {
      const session = new AgentSession();
      const testWallet = Wallet.createRandom();
      const keystoreJson = await testWallet.encrypt(TEST_PASSWORD);
      await session.unlock(keystoreJson, TEST_PASSWORD);

      const sdk = new BnbAgentSdk(session, { chainId: 97 });
      vi.spyOn(sdk, 'registerIdentity').mockResolvedValue('0xagent123456');
      vi.spyOn(sdk, 'discover').mockResolvedValue([
        {
          agentId: '0xagent123456',
          owner: testWallet.address,
          name: 'ForecastOracleAgent',
          description: 'Autonomous DeFi Forecast Oracle',
          chainId: 97,
          skills: ['forecast', 'x402'],
          registeredAt: Date.now(),
        },
      ]);

      const dispatcher = createAgentDispatcher({ session, sdk });

      // Register identity
      const regRes = await sendRpcRequest<{ agentId: string }>(dispatcher, 'wallet.registerERC8004Identity', {
        metadata: {
          name: 'ForecastOracleAgent',
          description: 'Autonomous DeFi Forecast Oracle',
          skills: ['forecast', 'x402'],
        },
      });

      expect(regRes.error).toBeUndefined();
      expect(regRes.result?.agentId).toBe('0xagent123456');

      // Discover agents via default tool
      const tools = createDefaultTools({ session, sdk });
      const discoverTool = tools.find((t) => t.definition.function.name === 'discover_erc8004_agents');
      expect(discoverTool).toBeDefined();

      const discovered = (await discoverTool!.handler({ query: 'Forecast' })) as any[];
      expect(discovered.length).toBe(1);
      expect(discovered[0].name).toBe('ForecastOracleAgent');
      expect(discovered[0].agentId).toBe('0xagent123456');
    });
  });
});
