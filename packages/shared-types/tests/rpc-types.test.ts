import { describe, it, expect } from 'vitest';
import {
  isJSONRPCRequest,
  isJSONRPCResponse,
  isJSONRPCNotification,
  isJSONRPCError,
  JSONRPC_ERROR_CODES,
} from '../src/rpc';
import {
  isTokenBalance,
  isERC8056Metadata,
  isX402PaymentChallenge,
  isX402PaymentReceipt,
} from '../src/wallet';
import {
  isAgentConfig,
  isAgentStatus,
} from '../src/agent';

describe('JSON-RPC Type Guards', () => {
  describe('isJSONRPCRequest', () => {
    it('correctly validates a valid JSON-RPC 2.0 request with object params', () => {
      const req = { jsonrpc: '2.0', id: '1', method: 'agent.getStatus', params: {} };
      expect(isJSONRPCRequest(req)).toBe(true);
    });

    it('correctly validates a valid JSON-RPC 2.0 request with numeric id and array params', () => {
      const req = { jsonrpc: '2.0', id: 42, method: 'wallet.getBalance', params: ['0x123'] };
      expect(isJSONRPCRequest(req)).toBe(true);
    });

    it('correctly validates a valid JSON-RPC 2.0 request without params', () => {
      const req = { jsonrpc: '2.0', id: 'req-abc', method: 'system.ping' };
      expect(isJSONRPCRequest(req)).toBe(true);
    });

    it('correctly validates a valid JSON-RPC 2.0 request with null id', () => {
      const req = { jsonrpc: '2.0', id: null, method: 'system.ping' };
      expect(isJSONRPCRequest(req)).toBe(true);
    });

    it('rejects invalid JSON-RPC payloads', () => {
      expect(isJSONRPCRequest(null)).toBe(false);
      expect(isJSONRPCRequest(undefined)).toBe(false);
      expect(isJSONRPCRequest('string')).toBe(false);
      expect(isJSONRPCRequest({ id: '1', method: 'test' })).toBe(false); // missing jsonrpc
      expect(isJSONRPCRequest({ jsonrpc: '1.0', id: '1', method: 'test' })).toBe(false); // invalid version
      expect(isJSONRPCRequest({ jsonrpc: '2.0', id: '1' })).toBe(false); // missing method
      expect(isJSONRPCRequest({ jsonrpc: '2.0', method: 'test' })).toBe(false); // missing id (notification, not request)
      expect(isJSONRPCRequest({ jsonrpc: '2.0', id: {}, method: 'test' })).toBe(false); // invalid id type
      expect(isJSONRPCRequest({ jsonrpc: '2.0', id: '1', method: 123 })).toBe(false); // non-string method
      expect(isJSONRPCRequest({ jsonrpc: '2.0', id: '1', method: 'test', params: 'invalid' })).toBe(false); // primitive params
    });
  });

  describe('isJSONRPCNotification', () => {
    it('correctly validates a valid JSON-RPC 2.0 notification', () => {
      const notif = { jsonrpc: '2.0', method: 'agent.stateChanged', params: { state: 'locked' } };
      expect(isJSONRPCNotification(notif)).toBe(true);
    });

    it('rejects notification with id', () => {
      const withId = { jsonrpc: '2.0', id: '1', method: 'agent.stateChanged' };
      expect(isJSONRPCNotification(withId)).toBe(false);
    });

    it('rejects notification without method or invalid jsonrpc', () => {
      expect(isJSONRPCNotification({ jsonrpc: '2.0' })).toBe(false);
      expect(isJSONRPCNotification({ method: 'ping' })).toBe(false);
      expect(isJSONRPCNotification(null)).toBe(false);
    });
  });

  describe('isJSONRPCResponse', () => {
    it('validates successful JSON-RPC 2.0 response', () => {
      const res = { jsonrpc: '2.0', id: '1', result: { status: 'ok' } };
      expect(isJSONRPCResponse(res)).toBe(true);
    });

    it('validates error JSON-RPC 2.0 response', () => {
      const res = {
        jsonrpc: '2.0',
        id: '1',
        error: { code: JSONRPC_ERROR_CODES.METHOD_NOT_FOUND, message: 'Method not found' },
      };
      expect(isJSONRPCResponse(res)).toBe(true);
    });

    it('rejects invalid response payloads', () => {
      expect(isJSONRPCResponse(null)).toBe(false);
      expect(isJSONRPCResponse({ jsonrpc: '2.0', id: '1' })).toBe(false); // neither result nor error
      expect(isJSONRPCResponse({ jsonrpc: '2.0', id: '1', result: {}, error: { code: -32600, message: 'err' } })).toBe(false); // both result and error
      expect(isJSONRPCResponse({ jsonrpc: '1.0', id: '1', result: 42 })).toBe(false); // wrong version
      expect(isJSONRPCResponse({ jsonrpc: '2.0', result: 42 })).toBe(false); // missing id
    });
  });

  describe('isJSONRPCError', () => {
    it('validates standard and custom JSON-RPC error objects', () => {
      expect(isJSONRPCError({ code: -32600, message: 'Invalid Request' })).toBe(true);
      expect(isJSONRPCError({ code: -32000, message: 'Custom server error', data: { detail: 'timeout' } })).toBe(true);
    });

    it('rejects invalid error objects', () => {
      expect(isJSONRPCError(null)).toBe(false);
      expect(isJSONRPCError({ code: '32600', message: 'err' })).toBe(false); // non-numeric code
      expect(isJSONRPCError({ code: -32600 })).toBe(false); // missing message
      expect(isJSONRPCError({ message: 'err' })).toBe(false); // missing code
    });
  });
});

describe('Wallet Data Schemas & Type Guards', () => {
  describe('isTokenBalance', () => {
    it('validates standard ERC-20 token balance', () => {
      const balance = {
        tokenAddress: '0x0000000000000000000000000000000000000000',
        name: 'BNB',
        symbol: 'tBNB',
        decimals: 18,
        rawBalance: '1500000000000000000',
        uiBalance: '1.5',
        isERC8056: false,
      };
      expect(isTokenBalance(balance)).toBe(true);
    });

    it('validates ERC-8056 token balance with multiplier', () => {
      const balance = {
        tokenAddress: '0x1111111111111111111111111111111111111111',
        name: 'Scaled Token',
        symbol: 'SCL',
        decimals: 6,
        rawBalance: '1000000',
        uiBalance: '2',
        multiplier: '2000000',
        isERC8056: true,
      };
      expect(isTokenBalance(balance)).toBe(true);
    });

    it('rejects invalid token balance structures', () => {
      expect(isTokenBalance(null)).toBe(false);
      expect(isTokenBalance({ symbol: 'tBNB', rawBalance: '100' })).toBe(false);
      expect(isTokenBalance({ tokenAddress: 123, symbol: 'tBNB', decimals: '18' })).toBe(false);
    });
  });

  describe('isERC8056Metadata', () => {
    it('validates valid ERC-8056 metadata', () => {
      const meta = {
        decimals: 6,
        multiplier: '2000000',
        symbol: 'SCL',
        name: 'Scaled Token',
      };
      expect(isERC8056Metadata(meta)).toBe(true);
    });

    it('rejects invalid ERC-8056 metadata', () => {
      expect(isERC8056Metadata(null)).toBe(false);
      expect(isERC8056Metadata({ decimals: 6 })).toBe(false); // missing multiplier
      expect(isERC8056Metadata({ decimals: '6', multiplier: 2000 })).toBe(false);
    });
  });

  describe('isX402PaymentChallenge', () => {
    it('validates standard x402 payment challenge', () => {
      const challenge = {
        token: 'tBNB',
        amount: '0.001',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
        resource: 'https://api.example.com/data',
        description: 'Premium AI Analysis',
        nonce: 'challenge-nonce-123',
      };
      expect(isX402PaymentChallenge(challenge)).toBe(true);
    });

    it('rejects invalid x402 challenge', () => {
      expect(isX402PaymentChallenge(null)).toBe(false);
      expect(isX402PaymentChallenge({ token: 'tBNB', amount: '0.001' })).toBe(false); // missing recipient/chainId
      expect(isX402PaymentChallenge({ token: 'tBNB', amount: 0.001, recipient: '0x123', chainId: '97' })).toBe(false);
    });
  });

  describe('isX402PaymentReceipt', () => {
    it('validates complete x402 payment receipt', () => {
      const receipt = {
        txHash: '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        token: 'tBNB',
        amount: '0.001',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
        timestamp: Date.now(),
        blockNumber: 1234567,
        status: 'success' as const,
      };
      expect(isX402PaymentReceipt(receipt)).toBe(true);
    });

    it('rejects invalid x402 payment receipt', () => {
      expect(isX402PaymentReceipt(null)).toBe(false);
      expect(isX402PaymentReceipt({ txHash: '0x123', status: 'invalid-status' })).toBe(false);
    });
  });
});

describe('Agent Data Schemas & Type Guards', () => {
  describe('isAgentConfig', () => {
    it('validates minimal and full agent configs', () => {
      expect(isAgentConfig({ chainId: 97, rpcUrl: 'https://data-seed-prebsc-1-s1.binance.org:8545/' })).toBe(true);
      expect(
        isAgentConfig({
          chainId: 97,
          rpcUrl: 'https://data-seed-prebsc-1-s1.binance.org:8545/',
          openaiApiKey: 'sk-test',
          openaiBaseUrl: 'https://api.openai.com/v1',
          openaiModel: 'gpt-4o',
          agentName: 'Notch Agent',
        })
      ).toBe(true);
    });

    it('rejects invalid agent configs', () => {
      expect(isAgentConfig(null)).toBe(false);
      expect(isAgentConfig({ chainId: '97' })).toBe(false);
      expect(isAgentConfig({ chainId: 97 })).toBe(false); // missing rpcUrl
    });
  });

  describe('isAgentStatus', () => {
    it('validates active agent status', () => {
      const status = {
        state: 'active' as const,
        address: '0x1111111111111111111111111111111111111111',
        balance: '0.05 tBNB',
        activeTasks: 0,
        lastActivity: Date.now(),
        lockState: 'unlocked' as const,
      };
      expect(isAgentStatus(status)).toBe(true);
    });

    it('validates locked agent status', () => {
      const status = {
        state: 'locked' as const,
        lockState: 'locked' as const,
      };
      expect(isAgentStatus(status)).toBe(true);
    });

    it('rejects invalid agent status', () => {
      expect(isAgentStatus(null)).toBe(false);
      expect(isAgentStatus({ state: 'unknown' })).toBe(false);
      expect(isAgentStatus({ state: 'active' })).toBe(false); // missing lockState
    });
  });
});
