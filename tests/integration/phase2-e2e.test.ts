/**
 * Phase 2 End-to-End Integration Suite
 * 
 * Tests:
 * 1. PancakeSwap Swap Routing & Calldata Construction on BSC Testnet 97.
 * 2. Agent Maker Mode: Complete HTTP 402 Challenge -> Autonomous Payment -> Settlement -> Double-Spend Replay Defense.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  estimateSwapQuote,
  buildSwapTransaction,
  PANCAKESWAP_ROUTER_TESTNET,
  WBNB_TESTNET,
  PANCAKESWAP_ROUTER_ABI,
} from '../../packages/agent-runtime/src/bnb/pancakeswap.js';
import { MPPServer } from '../../packages/agent-runtime/src/mpp/server.js';
import { MPPReplayStore } from '../../packages/agent-runtime/src/mpp/replay-store.js';
import { AgentSession } from '../../packages/agent-runtime/src/wallet/session.js';
import { generateAgentKeystore } from '../../packages/agent-runtime/src/wallet/keystore.js';
import { createAgentDispatcher } from '../../packages/agent-runtime/src/index.js';
import { JsonRpcProvider, Wallet, Interface, parseEther } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';

describe('Phase 2 E2E Integration Suite', () => {
  const TEST_REPLAY_FILE = path.join(process.cwd(), 'tests', 'fixtures', 'phase2-replay-test.json');

  beforeEach(() => {
    if (fs.existsSync(TEST_REPLAY_FILE)) {
      fs.unlinkSync(TEST_REPLAY_FILE);
    }
  });

  afterEach(() => {
    if (fs.existsSync(TEST_REPLAY_FILE)) {
      fs.unlinkSync(TEST_REPLAY_FILE);
    }
  });

  describe('1. PancakeSwap Router Adapter Integration', () => {
    const routerInterface = new Interface(PANCAKESWAP_ROUTER_ABI);
    const erc20Interface = new Interface([
      'function decimals() view returns (uint8)',
      'function multiplier() view returns (uint256)',
    ]);
    const GET_AMOUNTS_OUT_SELECTOR = routerInterface.getFunction('getAmountsOut')!.selector;
    const DECIMALS_SELECTOR = erc20Interface.getFunction('decimals')!.selector;
    const MULTIPLIER_SELECTOR = erc20Interface.getFunction('multiplier')!.selector;

    const mockProvider = {
      call: async (tx: any) => {
        const data = tx.data || '';
        if (data.startsWith(DECIMALS_SELECTOR)) {
          return erc20Interface.encodeFunctionResult('decimals', [18]);
        }
        if (data.startsWith(MULTIPLIER_SELECTOR)) {
          return erc20Interface.encodeFunctionResult('multiplier', [parseEther('1.0')]);
        }
        if (data.startsWith(GET_AMOUNTS_OUT_SELECTOR)) {
          return routerInterface.encodeFunctionResult('getAmountsOut', [
            [parseEther('1.0'), parseEther('595')],
          ]);
        }
        return '0x';
      },
    } as unknown as JsonRpcProvider;

    it('estimates live swap quote with slippage protection and route calculation', async () => {
      const USDT_TESTNET = '0x337610d27c682E347C9cD60743770f1ceCA83547';

      const quote = await estimateSwapQuote(
        {
          tokenIn: 'tBNB',
          tokenOut: USDT_TESTNET,
          amountIn: '1.0',
          slippageTolerancePercent: 0.5,
        },
        mockProvider
      );

      expect(quote.tokenIn).toBe('tBNB');
      expect(quote.tokenOut).toBe(USDT_TESTNET);
      expect(parseFloat(quote.amountIn)).toBe(1.0);
      expect(quote.amountOut).toBe('595');
      // 595 * 0.995 = 592.025
      expect(quote.amountOutMin).toBe('592.025');
      expect(quote.route).toHaveLength(2);
      expect(quote.route[0].toLowerCase()).toBe(WBNB_TESTNET.toLowerCase());
      expect(quote.route[1].toLowerCase()).toBe(USDT_TESTNET.toLowerCase());
      expect(quote.slippageTolerancePercent).toBe(0.5);
    });

    it('builds unsigned transaction calldata for native ETH/BNB to token swap', async () => {
      const USDT_TESTNET = '0x337610d27c682E347C9cD60743770f1ceCA83547';
      const userRecipient = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';

      const quote = await estimateSwapQuote(
        {
          tokenIn: 'tBNB',
          tokenOut: USDT_TESTNET,
          amountIn: '0.5',
          slippageTolerancePercent: 1.0,
        },
        mockProvider
      );

      const unsignedTx = await buildSwapTransaction(
        {
          tokenIn: quote.tokenIn,
          tokenOut: quote.tokenOut,
          amountIn: quote.amountIn,
          amountOutMin: quote.amountOutMin,
          recipient: userRecipient,
          route: quote.route,
          deadline: Math.floor(Date.now() / 1000) + 1200,
        },
        mockProvider
      );

      expect(unsignedTx.to.toLowerCase()).toBe(PANCAKESWAP_ROUTER_TESTNET.toLowerCase());
      expect(unsignedTx.data.startsWith('0x')).toBe(true);
      expect(unsignedTx.value).toBe(parseEther('0.5').toString());
      expect(unsignedTx.chainId).toBe(97);
      expect(unsignedTx.gasLimit).toBe('250000');
    });
  });

  describe('2. Agent Maker Mode (HTTP 402 & Double-Spend Replay Defense)', () => {
    let server: MPPServer;
    let replayStore: MPPReplayStore;
    let serverPort: number;
    let sellerAddress: string;

    const mockSellerKey = '0x0123456789012345678901234567890123456789012345678901234567890123';
    const mockSellerWallet = new Wallet(mockSellerKey);
    sellerAddress = mockSellerWallet.address;

    const validTxHash = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    const mockBscProvider = {
      getTransactionReceipt: async (hash: string) => {
        if (hash === validTxHash) {
          return {
            hash: validTxHash,
            status: 1, // Success
            blockNumber: 1234567,
            from: '0xBuyerAddress1111111111111111111111111111111',
            to: sellerAddress,
          };
        }
        return null;
      },
      getTransaction: async (hash: string) => {
        if (hash === validTxHash) {
          return {
            hash: validTxHash,
            from: '0xBuyerAddress1111111111111111111111111111111',
            to: sellerAddress,
            value: parseEther('0.001'),
          };
        }
        return null;
      },
    } as unknown as JsonRpcProvider;

    beforeEach(async () => {
      replayStore = new MPPReplayStore({ storePath: TEST_REPLAY_FILE });
      server = new MPPServer({
        port: 0, // ephemeral port
        recipient: sellerAddress,
        provider: mockBscProvider,
        replayStore,
        defaultPrice: '0.001',
      });

      // Register custom premium endpoint using (path, handler, price)
      server.registerEndpoint(
        '/api/v1/tools/weather-premium',
        async (_req, body) => ({
          city: body?.city || 'Singapore',
          temperature: '31°C',
          condition: 'Sunny with tropical clouds',
          deliveredAt: Date.now(),
        }),
        '0.001'
      );

      const started = await server.start(0);
      serverPort = started.port;
    });

    afterEach(async () => {
      await server.stop();
    });

    it('returns HTTP 402 challenge when request lacks payment authorization', async () => {
      const response = await fetch(`http://127.0.0.1:${serverPort}/api/v1/tools/weather-premium`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ city: 'Tokyo' }),
      });

      expect(response.status).toBe(402);
      const authHeader = response.headers.get('www-authenticate');
      expect(authHeader).toContain('x402');
      expect(authHeader).toContain('amount="0.001"');
      expect(authHeader).toContain(`recipient="${sellerAddress}"`);
      expect(authHeader).toContain('chainId="97"');

      const body = await response.json();
      expect(body.error).toBe('Payment Required');
      expect(body.x402.recipient.toLowerCase()).toBe(sellerAddress.toLowerCase());
    });

    it('successfully delivers tool payload upon presenting valid on-chain x402 payment header', async () => {
      const response = await fetch(`http://127.0.0.1:${serverPort}/api/v1/tools/weather-premium`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `x402 ${validTxHash}`,
        },
        body: JSON.stringify({ city: 'Kyoto' }),
      });

      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.city).toBe('Kyoto');
      expect(body.temperature).toBe('31°C');

      // Verify sale recorded in store
      expect(await replayStore.has(validTxHash)).toBe(true);
      const sales = server.getSalesHistory();
      expect(sales).toHaveLength(1);
      expect(sales[0].txHash).toBe(validTxHash);
    });

    it('DEFENDS against double-spend replay attack by rejecting re-submitted txHash with HTTP 403 Forbidden', async () => {
      // 1. First redemption succeeds
      const firstRes = await fetch(`http://127.0.0.1:${serverPort}/api/v1/tools/weather-premium`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `x402 ${validTxHash}`,
        },
        body: JSON.stringify({ city: 'Osaka' }),
      });
      expect(firstRes.status).toBe(200);

      // 2. Second request re-using the exact same txHash is BLOCKED
      const replayRes = await fetch(`http://127.0.0.1:${serverPort}/api/v1/tools/weather-premium`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `x402 ${validTxHash}`,
        },
        body: JSON.stringify({ city: 'Osaka' }),
      });

      expect(replayRes.status).toBe(403);
      const replayBody = await replayRes.json();
      expect(replayBody.error).toMatch(/Payment already redeemed|replay/i);
    });

    it('integrates seamlessly with JSON-RPC dispatcher for server management and metrics', async () => {
      const session = new AgentSession();
      const { address, keystoreJson } = await generateAgentKeystore('test-passphrase');
      await session.unlock(keystoreJson, 'test-passphrase');

      const dispatcher = createAgentDispatcher({ session });

      // Start MPP server via JSON-RPC
      const startRes = await dispatcher.handleMessage(
        JSON.stringify({
          jsonrpc: '2.0',
          id: 'mpp-1',
          method: 'mpp.startServer',
          params: { port: 0 },
        })
      );
      const startJson = JSON.parse(startRes!);
      expect(startJson.result.running).toBe(true);
      expect(startJson.result.port).toBeGreaterThan(0);

      // Query status via JSON-RPC
      const statusRes = await dispatcher.handleMessage(
        JSON.stringify({
          jsonrpc: '2.0',
          id: 'mpp-2',
          method: 'mpp.getStatus',
          params: {},
        })
      );
      const statusJson = JSON.parse(statusRes!);
      expect(statusJson.result.running).toBe(true);
      expect(statusJson.result.recipient.toLowerCase()).toBe(address.toLowerCase());

      // Stop server via JSON-RPC
      const stopRes = await dispatcher.handleMessage(
        JSON.stringify({
          jsonrpc: '2.0',
          id: 'mpp-3',
          method: 'mpp.stopServer',
          params: {},
        })
      );
      const stopJson = JSON.parse(stopRes!);
      expect(stopJson.result.stopped).toBe(true);
    });
  });
});
