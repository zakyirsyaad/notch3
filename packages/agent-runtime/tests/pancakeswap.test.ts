import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ZeroAddress, Interface, getAddress } from 'ethers';
import {
  PANCAKESWAP_ROUTER_TESTNET,
  PANCAKESWAP_FACTORY_TESTNET,
  WBNB_TESTNET,
  DEFAULT_SLIPPAGE_TOLERANCE_PERCENT,
  isNativeBNB,
  normalizeTokenAddress,
  estimateSwapQuote,
  buildSwapTransaction,
  PANCAKESWAP_ROUTER_ABI,
} from '../src/bnb/pancakeswap.js';
import { BnbAgentSdk } from '../src/bnb/bnb-sdk.js';
import { AgentSession } from '../src/wallet/session.js';
import {
  isSwapQuoteResult,
  isUnsignedTransactionPayload,
  type SwapQuoteParams,
  type BuildSwapParams,
} from '@notch/shared-types';

const TEST_USDT_TESTNET = getAddress('0x337610d27c682E347C9cD60743770f1ceCA83547'.toLowerCase());
const TEST_CAKE_TESTNET = getAddress('0xFa60D973F7642B748046464e165A65B7323b0C03'.toLowerCase());
const TEST_RECIPIENT = getAddress('0x1111111111111111111111111111111111111111'.toLowerCase());

const ERC20_INTERFACE = new Interface([
  'function decimals() view returns (uint8)',
  'function multiplier() view returns (uint256)',
]);
const DECIMALS_SELECTOR = ERC20_INTERFACE.getFunction('decimals')!.selector;
const MULTIPLIER_SELECTOR = ERC20_INTERFACE.getFunction('multiplier')!.selector;

describe('PancakeSwap Router Adapter', () => {
  const routerInterface = new Interface(PANCAKESWAP_ROUTER_ABI);
  const GET_AMOUNTS_OUT_SELECTOR = routerInterface.getFunction('getAmountsOut')!.selector;

  describe('Constants & Native BNB Helper', () => {
    it('defines correct BSC Testnet addresses', () => {
      expect(PANCAKESWAP_ROUTER_TESTNET).toBe('0xD99D1c33F9fC3444f8101754aBC46c52416550D1');
      expect(PANCAKESWAP_FACTORY_TESTNET).toBe('0x6725F303b657a9451d8BA641348b6761A6CC7a17');
      expect(WBNB_TESTNET).toBe('0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd');
      expect(DEFAULT_SLIPPAGE_TOLERANCE_PERCENT).toBe(0.5);
    });

    it('correctly identifies native BNB representations', () => {
      expect(isNativeBNB('BNB')).toBe(true);
      expect(isNativeBNB('bnb')).toBe(true);
      expect(isNativeBNB('tBNB')).toBe(true);
      expect(isNativeBNB('tbnb')).toBe(true);
      expect(isNativeBNB(ZeroAddress)).toBe(true);
      expect(isNativeBNB('0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee')).toBe(true);
      expect(isNativeBNB('0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE')).toBe(true);
      expect(isNativeBNB('')).toBe(true);

      expect(isNativeBNB(TEST_USDT_TESTNET)).toBe(false);
      expect(isNativeBNB(WBNB_TESTNET)).toBe(false);
    });

    it('normalizes token addresses correctly', () => {
      expect(normalizeTokenAddress('BNB')).toBe(getAddress(WBNB_TESTNET.toLowerCase()));
      expect(normalizeTokenAddress(ZeroAddress)).toBe(getAddress(WBNB_TESTNET.toLowerCase()));
      expect(normalizeTokenAddress(TEST_USDT_TESTNET.toLowerCase())).toBe(TEST_USDT_TESTNET);
    });
  });

  describe('estimateSwapQuote', () => {
    let mockProvider: any;

    beforeEach(() => {
      mockProvider = {
        call: vi.fn(),
      };
    });

    it('estimates quote for BNB -> USDT with default 0.5% slippage', async () => {
      // Mock router getAmountsOut returning 600 USDT (6 decimals) for 1 BNB (18 decimals)
      const rawIn = 1000000000000000000n; // 1 BNB
      const rawOut = 600000000n; // 600 USDT (6 decimals)

      mockProvider.call = vi.fn().mockImplementation(async (tx: any) => {
        const data = tx.data;
        if (data.startsWith(DECIMALS_SELECTOR)) {
          return ERC20_INTERFACE.encodeFunctionResult('decimals', [6]);
        }
        if (data.startsWith(MULTIPLIER_SELECTOR)) {
          throw new Error('Not ERC-8056');
        }
        if (data.startsWith(GET_AMOUNTS_OUT_SELECTOR)) {
          return routerInterface.encodeFunctionResult('getAmountsOut', [
            [rawIn, rawOut],
          ]);
        }
        return '0x';
      });

      const params: SwapQuoteParams = {
        tokenIn: 'BNB',
        tokenOut: TEST_USDT_TESTNET,
        amountIn: '1.0',
      };

      const result = await estimateSwapQuote(params, mockProvider);

      expect(isSwapQuoteResult(result)).toBe(true);
      expect(result.tokenIn).toBe('BNB');
      expect(result.tokenOut).toBe(TEST_USDT_TESTNET);
      expect(result.amountIn).toBe('1');
      expect(result.amountOut).toBe('600');
      // 600 * (1 - 0.005) = 597.0
      expect(result.amountOutMin).toBe('597');
      expect(result.slippageTolerancePercent).toBe(0.5);
      expect(result.route).toEqual([getAddress(WBNB_TESTNET.toLowerCase()), TEST_USDT_TESTNET]);
      expect(parseFloat(result.executionPrice || '0')).toBeCloseTo(600, 2);
    });

    it('estimates quote for Token -> BNB with custom slippage 1.0%', async () => {
      // 600 USDT (6 decimals) -> 1 BNB (18 decimals)
      const rawIn = 600000000n;
      const rawOut = 1000000000000000000n; // 1 BNB

      mockProvider.call = vi.fn().mockImplementation(async (tx: any) => {
        const data = tx.data;
        if (data.startsWith(DECIMALS_SELECTOR)) {
          return ERC20_INTERFACE.encodeFunctionResult('decimals', [6]);
        }
        if (data.startsWith(MULTIPLIER_SELECTOR)) {
          throw new Error('Not ERC-8056');
        }
        if (data.startsWith(GET_AMOUNTS_OUT_SELECTOR)) {
          return routerInterface.encodeFunctionResult('getAmountsOut', [
            [rawIn, rawOut],
          ]);
        }
        return '0x';
      });

      const params: SwapQuoteParams = {
        tokenIn: TEST_USDT_TESTNET,
        tokenOut: 'tBNB',
        amountIn: '600',
        slippageTolerancePercent: 1.0,
      };

      const result = await estimateSwapQuote(params, mockProvider);

      expect(isSwapQuoteResult(result)).toBe(true);
      expect(result.amountIn).toBe('600');
      expect(result.amountOut).toBe('1');
      // 1.0 BNB with 1% slippage = 0.99 BNB = 990000000000000000n
      expect(result.amountOutMin).toBe('0.99');
      expect(result.slippageTolerancePercent).toBe(1.0);
      expect(result.route).toEqual([TEST_USDT_TESTNET, getAddress(WBNB_TESTNET.toLowerCase())]);
    });

    it('handles ERC-8056 dynamic scaled tokens in quote estimation', async () => {
      // TokenOut has multiplier of 2x (2 * 10^18)
      const rawIn = 1000000000000000000n;
      const rawOut = 1000000000000000000n; // raw is 1.0 token, with 2x multiplier UI is 2.0

      mockProvider.call = vi.fn().mockImplementation(async (tx: any) => {
        const data = tx.data;
        if (data.startsWith(DECIMALS_SELECTOR)) {
          return ERC20_INTERFACE.encodeFunctionResult('decimals', [18]);
        }
        if (data.startsWith(MULTIPLIER_SELECTOR)) {
          // multiplier = 2 * 10^18
          return ERC20_INTERFACE.encodeFunctionResult('multiplier', [2000000000000000000n]);
        }
        if (data.startsWith(GET_AMOUNTS_OUT_SELECTOR)) {
          return routerInterface.encodeFunctionResult('getAmountsOut', [
            [rawIn, rawOut],
          ]);
        }
        return '0x';
      });

      const params: SwapQuoteParams = {
        tokenIn: 'BNB',
        tokenOut: TEST_CAKE_TESTNET,
        amountIn: '1.0',
        slippageTolerancePercent: 0.5,
      };

      const result = await estimateSwapQuote(params, mockProvider);
      expect(isSwapQuoteResult(result)).toBe(true);
      expect(result.amountOut).toBe('2');
      // 2.0 scaled - 0.5% = 1.99
      expect(result.amountOutMin).toBe('1.99');
    });

    it('throws when amountIn is zero or negative', async () => {
      await expect(
        estimateSwapQuote({
          tokenIn: 'BNB',
          tokenOut: TEST_USDT_TESTNET,
          amountIn: '0',
        }, mockProvider)
      ).rejects.toThrow(/Amount in must be greater than 0/i);

      await expect(
        estimateSwapQuote({
          tokenIn: 'BNB',
          tokenOut: TEST_USDT_TESTNET,
          amountIn: '-1.5',
        }, mockProvider)
      ).rejects.toThrow();
    });

    it('throws when slippage is outside 0-100 range', async () => {
      await expect(
        estimateSwapQuote({
          tokenIn: 'BNB',
          tokenOut: TEST_USDT_TESTNET,
          amountIn: '1.0',
          slippageTolerancePercent: -0.1,
        }, mockProvider)
      ).rejects.toThrow(/Invalid slippage tolerance/i);

      await expect(
        estimateSwapQuote({
          tokenIn: 'BNB',
          tokenOut: TEST_USDT_TESTNET,
          amountIn: '1.0',
          slippageTolerancePercent: 101,
        }, mockProvider)
      ).rejects.toThrow(/Invalid slippage tolerance/i);
    });
  });

  describe('buildSwapTransaction', () => {
    let mockProvider: any;

    beforeEach(() => {
      mockProvider = {
        call: vi.fn().mockImplementation(async (tx: any) => {
          const data = tx.data;
          if (data.startsWith(DECIMALS_SELECTOR)) {
            // Return 6 for USDT, 18 for CAKE
            if (tx.to.toLowerCase() === TEST_USDT_TESTNET.toLowerCase()) {
              return ERC20_INTERFACE.encodeFunctionResult('decimals', [6]);
            }
            return ERC20_INTERFACE.encodeFunctionResult('decimals', [18]);
          }
          if (data.startsWith(MULTIPLIER_SELECTOR)) {
            throw new Error('Not ERC-8056');
          }
          return '0x';
        }),
      };
    });

    it('builds swapExactETHForTokens payload for BNB -> Token swap', async () => {
      const fixedDeadline = 1800000000;
      const params: BuildSwapParams = {
        tokenIn: 'BNB',
        tokenOut: TEST_USDT_TESTNET,
        amountIn: '1.5', // 1.5 BNB = 1500000000000000000 wei
        amountOutMin: '895.5', // 895.5 USDT (6 decimals) = 895500000
        recipient: TEST_RECIPIENT,
        deadline: fixedDeadline,
      };

      const payload = await buildSwapTransaction(params, mockProvider);

      expect(isUnsignedTransactionPayload(payload)).toBe(true);
      expect(payload.to.toLowerCase()).toBe(PANCAKESWAP_ROUTER_TESTNET.toLowerCase());
      expect(payload.value).toBe('1500000000000000000');
      expect(payload.chainId).toBe(97);

      // Verify calldata decodes to swapExactETHForTokens
      const decoded = routerInterface.decodeFunctionData('swapExactETHForTokens', payload.data);
      expect(decoded.amountOutMin).toBe(895500000n);
      expect(decoded.path).toEqual([getAddress(WBNB_TESTNET.toLowerCase()), TEST_USDT_TESTNET]);
      expect(decoded.to.toLowerCase()).toBe(TEST_RECIPIENT.toLowerCase());
      expect(Number(decoded.deadline)).toBe(fixedDeadline);
    });

    it('builds swapExactTokensForETH payload for Token -> BNB swap', async () => {
      const fixedDeadline = 1800000000;
      const params: BuildSwapParams = {
        tokenIn: TEST_USDT_TESTNET,
        tokenOut: 'tBNB',
        amountIn: '600', // 600 USDT (6 dec) = 600000000
        amountOutMin: '0.99', // 0.99 BNB (18 dec) = 990000000000000000
        recipient: TEST_RECIPIENT,
        deadline: fixedDeadline,
      };

      const payload = await buildSwapTransaction(params, mockProvider);

      expect(isUnsignedTransactionPayload(payload)).toBe(true);
      expect(payload.to.toLowerCase()).toBe(PANCAKESWAP_ROUTER_TESTNET.toLowerCase());
      expect(payload.value).toBe('0');
      expect(payload.chainId).toBe(97);

      const decoded = routerInterface.decodeFunctionData('swapExactTokensForETH', payload.data);
      expect(decoded.amountIn).toBe(600000000n);
      expect(decoded.amountOutMin).toBe(990000000000000000n);
      expect(decoded.path).toEqual([TEST_USDT_TESTNET, getAddress(WBNB_TESTNET.toLowerCase())]);
      expect(decoded.to.toLowerCase()).toBe(TEST_RECIPIENT.toLowerCase());
      expect(Number(decoded.deadline)).toBe(fixedDeadline);
    });

    it('builds swapExactTokensForTokens payload for Token -> Token swap', async () => {
      const fixedDeadline = 1800000000;
      const params: BuildSwapParams = {
        tokenIn: TEST_USDT_TESTNET,
        tokenOut: TEST_CAKE_TESTNET,
        amountIn: '100', // 100 USDT (6 dec) = 100000000
        amountOutMin: '25.5', // 25.5 CAKE (18 dec) = 25500000000000000000
        recipient: TEST_RECIPIENT,
        deadline: fixedDeadline,
        route: [TEST_USDT_TESTNET, WBNB_TESTNET, TEST_CAKE_TESTNET], // explicit multi-hop
      };

      const payload = await buildSwapTransaction(params, mockProvider);

      expect(isUnsignedTransactionPayload(payload)).toBe(true);
      expect(payload.to.toLowerCase()).toBe(PANCAKESWAP_ROUTER_TESTNET.toLowerCase());
      expect(payload.value).toBe('0');

      const decoded = routerInterface.decodeFunctionData('swapExactTokensForTokens', payload.data);
      expect(decoded.amountIn).toBe(100000000n);
      expect(decoded.amountOutMin).toBe(25500000000000000000n);
      expect(decoded.path).toEqual([
        TEST_USDT_TESTNET,
        getAddress(WBNB_TESTNET.toLowerCase()),
        TEST_CAKE_TESTNET,
      ]);
      expect(decoded.to.toLowerCase()).toBe(TEST_RECIPIENT.toLowerCase());
      expect(Number(decoded.deadline)).toBe(fixedDeadline);
    });

    it('applies default deadline of 20 minutes if not supplied', async () => {
      const before = Math.floor(Date.now() / 1000) + 1200;
      const params: BuildSwapParams = {
        tokenIn: 'BNB',
        tokenOut: TEST_USDT_TESTNET,
        amountIn: '1.0',
        amountOutMin: '500',
        recipient: TEST_RECIPIENT,
      };

      const payload = await buildSwapTransaction(params, mockProvider);
      const decoded = routerInterface.decodeFunctionData('swapExactETHForTokens', payload.data);
      const after = Math.floor(Date.now() / 1000) + 1200;

      expect(Number(decoded.deadline)).toBeGreaterThanOrEqual(before);
      expect(Number(decoded.deadline)).toBeLessThanOrEqual(after + 2);
    });

    it('throws if recipient address is invalid', async () => {
      await expect(
        buildSwapTransaction({
          tokenIn: 'BNB',
          tokenOut: TEST_USDT_TESTNET,
          amountIn: '1.0',
          amountOutMin: '500',
          recipient: 'not-an-address',
        }, mockProvider)
      ).rejects.toThrow(/Invalid recipient address/i);
    });
  });

  describe('BnbAgentSdk swap helper integration', () => {
    it('exposes estimateSwapQuote and buildSwapTransaction on BnbAgentSdk instance', async () => {
      const session = new AgentSession();
      const sdk = new BnbAgentSdk(session);

      expect(typeof sdk.estimateSwapQuote).toBe('function');
      expect(typeof sdk.buildSwapTransaction).toBe('function');
    });
  });
});
