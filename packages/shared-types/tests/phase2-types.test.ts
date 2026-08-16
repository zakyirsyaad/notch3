import { describe, it, expect } from 'vitest';
import {
  isSwapQuoteParams,
  isSwapQuoteResult,
  isBuildSwapParams,
  isUnsignedTransactionPayload,
  type SwapQuoteParams,
  type SwapQuoteResult,
  type BuildSwapParams,
  type UnsignedTransactionPayload,
} from '../src/wallet';
import {
  isMPPServerConfig,
  isMPPServerStatus,
  isMPPSaleReceipt,
  isMPPReplayRecord,
  type MPPServerConfig,
  type MPPServerStatus,
  type MPPSaleReceipt,
  type MPPReplayRecord,
} from '../src/mpp';

describe('Phase 2 PancakeSwap Router Schemas & Type Guards', () => {
  describe('isSwapQuoteParams', () => {
    it('validates a minimal valid SwapQuoteParams object', () => {
      const params: SwapQuoteParams = {
        tokenIn: '0x0000000000000000000000000000000000000000',
        tokenOut: '0xaB1a4d4f1D656d2450692D2377d6832903890260',
        amountIn: '0.1',
      };
      expect(isSwapQuoteParams(params)).toBe(true);
    });

    it('validates a complete valid SwapQuoteParams object with optional fields', () => {
      const params: SwapQuoteParams = {
        tokenIn: 'BNB',
        tokenOut: 'BUSD',
        amountIn: '1000000000000000000',
        slippageTolerancePercent: 0.5,
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
      };
      expect(isSwapQuoteParams(params)).toBe(true);
    });

    it('rejects invalid SwapQuoteParams objects', () => {
      expect(isSwapQuoteParams(null)).toBe(false);
      expect(isSwapQuoteParams(undefined)).toBe(false);
      expect(isSwapQuoteParams({})).toBe(false);
      expect(isSwapQuoteParams({ tokenIn: 'BNB', tokenOut: 'BUSD' })).toBe(false); // missing amountIn
      expect(isSwapQuoteParams({ tokenIn: 123, tokenOut: 'BUSD', amountIn: '1' })).toBe(false); // non-string tokenIn
      expect(isSwapQuoteParams({ tokenIn: 'BNB', tokenOut: 456, amountIn: '1' })).toBe(false); // non-string tokenOut
      expect(isSwapQuoteParams({ tokenIn: 'BNB', tokenOut: 'BUSD', amountIn: 1.5 })).toBe(false); // non-string amountIn
      expect(
        isSwapQuoteParams({
          tokenIn: 'BNB',
          tokenOut: 'BUSD',
          amountIn: '1',
          slippageTolerancePercent: '0.5',
        })
      ).toBe(false); // non-number slippageTolerancePercent
      expect(
        isSwapQuoteParams({
          tokenIn: 'BNB',
          tokenOut: 'BUSD',
          amountIn: '1',
          chainId: '97',
        })
      ).toBe(false); // non-number chainId
      expect(
        isSwapQuoteParams({
          tokenIn: 'BNB',
          tokenOut: 'BUSD',
          amountIn: '1',
          recipient: 123,
        })
      ).toBe(false); // non-string recipient
    });
  });

  describe('isSwapQuoteResult', () => {
    it('validates a minimal valid SwapQuoteResult object', () => {
      const result: SwapQuoteResult = {
        tokenIn: '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd',
        tokenOut: '0xaB1a4d4f1D656d2450692D2377d6832903890260',
        amountIn: '1.0',
        amountOut: '580.45',
        amountOutMin: '577.54775',
        slippageTolerancePercent: 0.5,
        route: [
          '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd',
          '0xaB1a4d4f1D656d2450692D2377d6832903890260',
        ],
      };
      expect(isSwapQuoteResult(result)).toBe(true);
    });

    it('validates a complete SwapQuoteResult object with price impact, execution price, and estimated gas', () => {
      const result: SwapQuoteResult = {
        tokenIn: 'WBNB',
        tokenOut: 'CAKE',
        amountIn: '0.5',
        amountOut: '120.5',
        amountOutMin: '119.295',
        slippageTolerancePercent: 1.0,
        route: ['0xWBNB', '0xCAKE'],
        priceImpactPercent: 0.12,
        executionPrice: '241.0',
        estimatedGas: '150000',
      };
      expect(isSwapQuoteResult(result)).toBe(true);
    });

    it('rejects invalid SwapQuoteResult objects', () => {
      expect(isSwapQuoteResult(null)).toBe(false);
      expect(isSwapQuoteResult({})).toBe(false);
      expect(
        isSwapQuoteResult({
          tokenIn: 'WBNB',
          tokenOut: 'CAKE',
          amountIn: '0.5',
          amountOut: '120.5',
        })
      ).toBe(false); // missing amountOutMin and route
      expect(
        isSwapQuoteResult({
          tokenIn: 'WBNB',
          tokenOut: 'CAKE',
          amountIn: '0.5',
          amountOut: '120.5',
          amountOutMin: '119.0',
          slippageTolerancePercent: 0.5,
          route: 'not-an-array',
        })
      ).toBe(false); // route not array
      expect(
        isSwapQuoteResult({
          tokenIn: 'WBNB',
          tokenOut: 'CAKE',
          amountIn: '0.5',
          amountOut: '120.5',
          amountOutMin: '119.0',
          slippageTolerancePercent: 0.5,
          route: [123],
        })
      ).toBe(false); // route elements not string
      expect(
        isSwapQuoteResult({
          tokenIn: 'WBNB',
          tokenOut: 'CAKE',
          amountIn: '0.5',
          amountOut: '120.5',
          amountOutMin: '119.0',
          slippageTolerancePercent: 0.5,
          route: ['0xWBNB'],
          priceImpactPercent: 'high',
        })
      ).toBe(false); // non-number priceImpactPercent
    });
  });

  describe('isBuildSwapParams', () => {
    it('validates minimal valid BuildSwapParams', () => {
      const params: BuildSwapParams = {
        tokenIn: '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd',
        tokenOut: '0xaB1a4d4f1D656d2450692D2377d6832903890260',
        amountIn: '1000000000000000000',
        amountOutMin: '577547750000000000000',
        recipient: '0x1111111111111111111111111111111111111111',
      };
      expect(isBuildSwapParams(params)).toBe(true);
    });

    it('validates full BuildSwapParams with optional deadline, slippage, route, and chainId', () => {
      const params: BuildSwapParams = {
        tokenIn: 'BNB',
        tokenOut: 'BUSD',
        amountIn: '1.0',
        amountOutMin: '577.5',
        recipient: '0x1111111111111111111111111111111111111111',
        deadline: 1723800000,
        slippageTolerancePercent: 0.5,
        route: ['0xWBNB', '0xBUSD'],
        chainId: 97,
      };
      expect(isBuildSwapParams(params)).toBe(true);
    });

    it('rejects invalid BuildSwapParams', () => {
      expect(isBuildSwapParams(null)).toBe(false);
      expect(
        isBuildSwapParams({
          tokenIn: 'BNB',
          tokenOut: 'BUSD',
          amountIn: '1.0',
        })
      ).toBe(false); // missing amountOutMin & recipient
      expect(
        isBuildSwapParams({
          tokenIn: 'BNB',
          tokenOut: 'BUSD',
          amountIn: '1.0',
          amountOutMin: '577.5',
          recipient: 12345,
        })
      ).toBe(false); // non-string recipient
      expect(
        isBuildSwapParams({
          tokenIn: 'BNB',
          tokenOut: 'BUSD',
          amountIn: '1.0',
          amountOutMin: '577.5',
          recipient: '0x123',
          deadline: 'tomorrow',
        })
      ).toBe(false); // non-number deadline
    });
  });

  describe('isUnsignedTransactionPayload', () => {
    it('validates minimal UnsignedTransactionPayload', () => {
      const payload: UnsignedTransactionPayload = {
        to: '0xD99D1c33F9fC3444f8101754aBC46c52416550D1',
        value: '1000000000000000000',
        data: '0x7ff36ab5000000000000000000000000000000000000000000000000',
      };
      expect(isUnsignedTransactionPayload(payload)).toBe(true);
    });

    it('validates full UnsignedTransactionPayload with optional metadata', () => {
      const payload: UnsignedTransactionPayload = {
        to: '0xD99D1c33F9fC3444f8101754aBC46c52416550D1',
        value: '0',
        data: '0x38ed1739',
        chainId: 97,
        gasLimit: '250000',
        gasPrice: '5000000000',
        nonce: 4,
        description: 'Swap 1 WBNB for BUSD on PancakeSwap',
      };
      expect(isUnsignedTransactionPayload(payload)).toBe(true);
    });

    it('rejects invalid UnsignedTransactionPayload', () => {
      expect(isUnsignedTransactionPayload(null)).toBe(false);
      expect(isUnsignedTransactionPayload({ to: '0x123', value: '0' })).toBe(false); // missing data
      expect(isUnsignedTransactionPayload({ to: '0x123', data: '0x' })).toBe(false); // missing value
      expect(isUnsignedTransactionPayload({ to: 123, value: '0', data: '0x' })).toBe(false); // non-string to
      expect(
        isUnsignedTransactionPayload({
          to: '0x123',
          value: '0',
          data: '0x',
          nonce: '4',
        })
      ).toBe(false); // non-number nonce
    });
  });
});

describe('Phase 2 Agent Maker Mode (MPP) Schemas & Type Guards', () => {
  describe('isMPPServerConfig', () => {
    it('validates empty/default MPPServerConfig', () => {
      expect(isMPPServerConfig({})).toBe(true);
    });

    it('validates full MPPServerConfig', () => {
      const config: MPPServerConfig = {
        port: 3402,
        host: '127.0.0.1',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
        defaultPrice: '0.001',
        token: 'tBNB',
        replayStorePath: '/tmp/mpp-replays.json',
        allowedEndpoints: ['/api/v1/tools/weather', '/api/v1/tools/analyze'],
      };
      expect(isMPPServerConfig(config)).toBe(true);
    });

    it('rejects invalid MPPServerConfig', () => {
      expect(isMPPServerConfig(null)).toBe(false);
      expect(isMPPServerConfig({ port: '3402' })).toBe(false); // non-number port
      expect(isMPPServerConfig({ host: 127 })).toBe(false); // non-string host
      expect(isMPPServerConfig({ chainId: '97' })).toBe(false); // non-number chainId
      expect(isMPPServerConfig({ allowedEndpoints: 'all' })).toBe(false); // non-array allowedEndpoints
      expect(isMPPServerConfig({ allowedEndpoints: [123] })).toBe(false); // non-string array elements
    });
  });

  describe('isMPPServerStatus', () => {
    it('validates inactive MPPServerStatus', () => {
      const status: MPPServerStatus = {
        running: false,
      };
      expect(isMPPServerStatus(status)).toBe(true);
    });

    it('validates active MPPServerStatus with metrics', () => {
      const status: MPPServerStatus = {
        running: true,
        port: 3402,
        host: '127.0.0.1',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
        totalSales: 15,
        totalRevenue: '0.015',
        uptime: 3600,
        activeEndpoints: ['/api/v1/tools/weather'],
      };
      expect(isMPPServerStatus(status)).toBe(true);
    });

    it('rejects invalid MPPServerStatus', () => {
      expect(isMPPServerStatus(null)).toBe(false);
      expect(isMPPServerStatus({})).toBe(false); // missing running
      expect(isMPPServerStatus({ running: 'yes' })).toBe(false); // non-boolean running
      expect(isMPPServerStatus({ running: true, totalSales: '15' })).toBe(false); // non-number totalSales
      expect(isMPPServerStatus({ running: true, uptime: '1hr' })).toBe(false); // non-number uptime
    });
  });

  describe('isMPPSaleReceipt', () => {
    it('validates a settled MPPSaleReceipt', () => {
      const receipt: MPPSaleReceipt = {
        txHash: '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        payer: '0x2222222222222222222222222222222222222222',
        recipient: '0x1111111111111111111111111111111111111111',
        amount: '0.001',
        token: 'tBNB',
        chainId: 97,
        endpoint: '/api/v1/tools/weather',
        timestamp: 1723800000000,
        blockNumber: 42000000,
        status: 'settled',
      };
      expect(isMPPSaleReceipt(receipt)).toBe(true);
    });

    it('validates refunded and failed MPPSaleReceipt status', () => {
      const base = {
        txHash: '0xabcdef',
        payer: '0x222',
        recipient: '0x111',
        amount: '0.001',
        token: 'tBNB',
        chainId: 97,
        endpoint: '/api/v1/tools/weather',
        timestamp: 1723800000000,
      };
      expect(isMPPSaleReceipt({ ...base, status: 'refunded' })).toBe(true);
      expect(isMPPSaleReceipt({ ...base, status: 'failed' })).toBe(true);
    });

    it('rejects invalid MPPSaleReceipt', () => {
      expect(isMPPSaleReceipt(null)).toBe(false);
      expect(
        isMPPSaleReceipt({
          txHash: '0x123',
          payer: '0x222',
          recipient: '0x111',
          amount: '0.001',
          token: 'tBNB',
          chainId: 97,
          endpoint: '/api/v1/tools/weather',
          timestamp: 1723800000000,
          status: 'unknown',
        })
      ).toBe(false); // invalid status
      expect(
        isMPPSaleReceipt({
          txHash: '0x123',
          payer: '0x222',
          recipient: '0x111',
          amount: '0.001',
          token: 'tBNB',
          chainId: 97,
          timestamp: 1723800000000,
          status: 'settled',
        })
      ).toBe(false); // missing endpoint
    });
  });

  describe('isMPPReplayRecord', () => {
    it('validates complete MPPReplayRecord', () => {
      const record: MPPReplayRecord = {
        txHash: '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        payer: '0x2222222222222222222222222222222222222222',
        recipient: '0x1111111111111111111111111111111111111111',
        amount: '0.001',
        token: 'tBNB',
        chainId: 97,
        endpoint: '/api/v1/tools/weather',
        timestamp: 1723800000000,
        blockNumber: 42000000,
      };
      expect(isMPPReplayRecord(record)).toBe(true);
    });

    it('rejects invalid MPPReplayRecord', () => {
      expect(isMPPReplayRecord(null)).toBe(false);
      expect(
        isMPPReplayRecord({
          txHash: '0x123',
          payer: '0x222',
          recipient: '0x111',
          amount: '0.001',
          token: 'tBNB',
          chainId: 97,
          // missing endpoint & timestamp
        })
      ).toBe(false);
      expect(
        isMPPReplayRecord({
          txHash: 123,
          payer: '0x222',
          recipient: '0x111',
          amount: '0.001',
          token: 'tBNB',
          chainId: 97,
          endpoint: '/test',
          timestamp: 123,
        })
      ).toBe(false); // non-string txHash
    });
  });
});
