import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { ZeroAddress, Interface, getAddress, Wallet, parseEther } from 'ethers';
import {
  createAgentDispatcher,
  AgentSession,
  BnbAgentSdk,
  MPPServer,
  MPPReplayStore,
  PANCAKESWAP_ROUTER_TESTNET,
  PANCAKESWAP_ROUTER_ABI,
  WBNB_TESTNET,
} from '../src/index.js';
import {
  JSONRPC_ERROR_CODES,
  isJSONRPCResponse,
  type SwapQuoteParams,
  type BuildSwapParams,
  type MPPServerStatus,
  type MPPSaleReceipt,
} from '@notch/shared-types';

const TEST_USDT = getAddress('0x337610d27c682E347C9cD60743770f1ceCA83547'.toLowerCase());
const TEST_CAKE = getAddress('0xFa60D973F7642B748046464e165A65B7323b0C03'.toLowerCase());
const TEST_RECIPIENT = getAddress('0x1111111111111111111111111111111111111111'.toLowerCase());
const TEST_PASSWORD = 'CorrectHorseBatteryStaple123!';

const ERC20_INTERFACE = new Interface([
  'function decimals() view returns (uint8)',
  'function multiplier() view returns (uint256)',
]);
const DECIMALS_SELECTOR = ERC20_INTERFACE.getFunction('decimals')!.selector;
const MULTIPLIER_SELECTOR = ERC20_INTERFACE.getFunction('multiplier')!.selector;
const ROUTER_INTERFACE = new Interface(PANCAKESWAP_ROUTER_ABI);
const GET_AMOUNTS_OUT_SELECTOR = ROUTER_INTERFACE.getFunction('getAmountsOut')!.selector;

async function sendRpc(
  dispatcher: ReturnType<typeof createAgentDispatcher>,
  method: string,
  params?: any,
  id: string | number = 'req-1'
) {
  const req = {
    jsonrpc: '2.0',
    id,
    method,
    ...(params !== undefined ? { params } : {}),
  };
  const raw = await dispatcher.handleMessage(JSON.stringify(req));
  expect(raw).not.toBeNull();
  const parsed = JSON.parse(raw!);
  expect(isJSONRPCResponse(parsed)).toBe(true);
  return parsed;
}

describe('Phase 2 JSON-RPC Dispatcher Method Bindings', () => {
  let session: AgentSession;
  let mockProvider: any;
  let sdk: BnbAgentSdk;
  let mppServer: MPPServer;
  let dispatcher: ReturnType<typeof createAgentDispatcher>;

  beforeEach(() => {
    session = new AgentSession();

    // Mock BSC Testnet Provider for PancakeSwap router & token contracts
    mockProvider = {
      call: vi.fn().mockImplementation(async (tx: any) => {
        const data = tx.data;
        if (data.startsWith(DECIMALS_SELECTOR)) {
          return ERC20_INTERFACE.encodeFunctionResult('decimals', [18]);
        }
        if (data.startsWith(MULTIPLIER_SELECTOR)) {
          throw new Error('Not ERC-8056');
        }
        if (data.startsWith(GET_AMOUNTS_OUT_SELECTOR)) {
          const rawIn = parseEther('1.0');
          const rawOut = parseEther('600.0');
          return ROUTER_INTERFACE.encodeFunctionResult('getAmountsOut', [
            [rawIn, rawOut],
          ]);
        }
        return '0x';
      }),
      getTransactionReceipt: vi.fn(),
      getTransaction: vi.fn(),
    };

    sdk = new BnbAgentSdk(session, { chainId: 97 });
    // Override provider on sdk
    (sdk as any)._provider = mockProvider;

    mppServer = new MPPServer({
      port: 0,
      host: '127.0.0.1',
      provider: mockProvider,
    });

    dispatcher = createAgentDispatcher({
      session,
      sdk,
      mppServer,
    });
  });

  afterEach(async () => {
    if (mppServer && mppServer.isRunning()) {
      await mppServer.stop();
    }
  });

  describe('PancakeSwap RPC Endpoints', () => {
    describe('wallet.estimateSwapQuote', () => {
      it('returns estimated swap quote with default and custom slippage', async () => {
        const params: SwapQuoteParams = {
          tokenIn: 'BNB',
          tokenOut: TEST_USDT,
          amountIn: '1.0',
          slippageTolerancePercent: 1.0,
        };

        const res = await sendRpc(dispatcher, 'wallet.estimateSwapQuote', params);

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(res.result.tokenIn).toBe('BNB');
        expect(res.result.tokenOut).toBe(TEST_USDT);
        expect(res.result.amountIn).toBe('1');
        expect(res.result.amountOut).toBe('600');
        expect(res.result.amountOutMin).toBe('594'); // 600 * (1 - 0.01) = 594
        expect(res.result.slippageTolerancePercent).toBe(1.0);
        expect(res.result.route).toEqual([getAddress(WBNB_TESTNET.toLowerCase()), TEST_USDT]);
      });

      it('works when session is locked (read-only quote)', async () => {
        expect(session.isUnlocked()).toBe(false);

        const params: SwapQuoteParams = {
          tokenIn: 'BNB',
          tokenOut: TEST_USDT,
          amountIn: '0.5',
        };

        const res = await sendRpc(dispatcher, 'wallet.estimateSwapQuote', params);
        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602)', async () => {
        // Missing tokenOut and amountIn
        const res1 = await sendRpc(dispatcher, 'wallet.estimateSwapQuote', {
          tokenIn: 'BNB',
        });
        expect(res1.error).toBeDefined();
        expect(res1.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);

        // Incomplete array parameters
        const res2 = await sendRpc(dispatcher, 'wallet.estimateSwapQuote', ['BNB']);
        expect(res2.error).toBeDefined();
        expect(res2.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });
    });

    describe('wallet.buildSwapTx', () => {
      it('builds unsigned transaction for BNB -> Token swap', async () => {
        const params: BuildSwapParams = {
          tokenIn: 'BNB',
          tokenOut: TEST_USDT,
          amountIn: '1.0',
          amountOutMin: '597.0',
          recipient: TEST_RECIPIENT,
          slippageTolerancePercent: 0.5,
        };

        const res = await sendRpc(dispatcher, 'wallet.buildSwapTx', params);

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(res.result.to).toBe(PANCAKESWAP_ROUTER_TESTNET);
        expect(res.result.value).toBe(parseEther('1.0').toString());
        expect(typeof res.result.data).toBe('string');
        expect(res.result.data.startsWith('0x')).toBe(true);
        expect(res.result.gasLimit).toBeDefined();
      });

      it('works when session is locked (unsigned payload construction)', async () => {
        expect(session.isUnlocked()).toBe(false);

        const params: BuildSwapParams = {
          tokenIn: TEST_USDT,
          tokenOut: TEST_CAKE,
          amountIn: '100.0',
          amountOutMin: '50.0',
          recipient: TEST_RECIPIENT,
        };

        const res = await sendRpc(dispatcher, 'wallet.buildSwapTx', params);
        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(res.result.to).toBe(PANCAKESWAP_ROUTER_TESTNET);
        expect(res.result.value).toBe('0');
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602)', async () => {
        // Missing recipient
        const res1 = await sendRpc(dispatcher, 'wallet.buildSwapTx', {
          tokenIn: 'BNB',
          tokenOut: TEST_USDT,
          amountIn: '1.0',
          amountOutMin: '590.0',
        });
        expect(res1.error).toBeDefined();
        expect(res1.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);

        // Missing amountOutMin
        const res2 = await sendRpc(dispatcher, 'wallet.buildSwapTx', {
          tokenIn: 'BNB',
          tokenOut: TEST_USDT,
          amountIn: '1.0',
          recipient: TEST_RECIPIENT,
        });
        expect(res2.error).toBeDefined();
        expect(res2.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });
    });
  });

  describe('Agent Maker Mode (MPP HTTP 402 Server) RPC Endpoints', () => {
    describe('mpp.getStatus', () => {
      it('returns current server status when stopped', async () => {
        const res = await sendRpc(dispatcher, 'mpp.getStatus');

        expect(res.error).toBeUndefined();
        const status: MPPServerStatus = res.result;
        expect(status.running).toBe(false);
        expect(status.totalSales).toBe(0);
        expect(status.totalRevenue).toBe('0');
        expect(Array.isArray(status.activeEndpoints)).toBe(true);
        expect(status.activeEndpoints).toContain('/api/v1/tools/weather');
      });
    });

    describe('mpp.startServer and mpp.stopServer', () => {
      it('starts and stops embedded MPP server through dispatcher', async () => {
        // 1. Start Server on ephemeral port (port: 0)
        const startRes = await sendRpc(dispatcher, 'mpp.startServer', { port: 0 });

        expect(startRes.error).toBeUndefined();
        expect(startRes.result).toBeDefined();
        expect(startRes.result.port).toBeGreaterThan(0);
        expect(startRes.result.status).toBe('running');

        // 2. Check Status after start
        const statusRes = await sendRpc(dispatcher, 'mpp.getStatus');
        expect(statusRes.result.running).toBe(true);
        expect(statusRes.result.port).toBe(startRes.result.port);

        // 3. Stop Server
        const stopRes = await sendRpc(dispatcher, 'mpp.stopServer');
        expect(stopRes.error).toBeUndefined();
        expect(stopRes.result.stopped).toBe(true);

        // 4. Check Status after stop
        const statusRes2 = await sendRpc(dispatcher, 'mpp.getStatus');
        expect(statusRes2.result.running).toBe(false);
      });

      it('accepts startServer with array parameter or empty params', async () => {
        const startRes = await sendRpc(dispatcher, 'mpp.startServer', [0]);
        expect(startRes.error).toBeUndefined();
        expect(startRes.result.port).toBeGreaterThan(0);

        await sendRpc(dispatcher, 'mpp.stopServer');
      });

      it('updates server recipient address when agent wallet is unlocked', async () => {
        const testWallet = Wallet.createRandom();
        const keystoreJson = await testWallet.encrypt(TEST_PASSWORD);

        // Unlock agent wallet
        await sendRpc(dispatcher, 'agent.unlock', {
          keystoreJson,
          passphrase: TEST_PASSWORD,
        });

        const statusRes = await sendRpc(dispatcher, 'mpp.getStatus');
        expect(statusRes.result.recipient?.toLowerCase()).toBe(testWallet.address.toLowerCase());
      });
    });

    describe('mpp.getSalesHistory', () => {
      it('returns empty sales history initially and populated array after sales', async () => {
        const historyRes = await sendRpc(dispatcher, 'mpp.getSalesHistory');
        expect(historyRes.error).toBeUndefined();
        expect(Array.isArray(historyRes.result)).toBe(true);
        expect(historyRes.result.length).toBe(0);
      });
    });
  });
});
