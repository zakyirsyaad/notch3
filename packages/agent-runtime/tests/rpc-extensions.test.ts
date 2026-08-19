import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Wallet, MaxUint256, encryptKeystoreJson } from 'ethers';
import * as keystoreModule from '../src/wallet/keystore.js';
import {
  createAgentDispatcher,
  AgentSession,
  BnbAgentSdk,
} from '../src/index.js';
import * as daemonModule from '../src/daemon.js';
import {
  JSONRPC_ERROR_CODES,
  isJSONRPCResponse,
} from '@notch/shared-types';

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

describe('RPC Extensions: agent.createWallet & wallet.sendRawTransaction', () => {
  let session: AgentSession;
  let mockProvider: any;
  let sdk: BnbAgentSdk;
  let dispatcher: ReturnType<typeof createAgentDispatcher>;
  const broadcastSpy = vi.fn();

  beforeEach(() => {
    session = new AgentSession();
    broadcastSpy.mockReset();
    broadcastSpy.mockResolvedValue(
      '0x1111111111111111111111111111111111111111111111111111111111111111'
    );
    mockProvider = {
      broadcastTransaction: broadcastSpy,
    } as any;
    sdk = new BnbAgentSdk(session, { provider: mockProvider } as any);
    dispatcher = createAgentDispatcher({ session, sdk });

    vi.spyOn(keystoreModule, 'generateAgentKeystore').mockImplementation(async (passphrase) => {
      const wallet = Wallet.createRandom();
      const keystoreJson = await encryptKeystoreJson(wallet as any, passphrase, { scrypt: { N: 1024 } });
      return { address: wallet.address, keystoreJson };
    });
  });

  describe('agent.createWallet', () => {
    it('creates a new encrypted agent keystore from a passphrase', async () => {
      const res = await sendRpc(dispatcher, 'agent.createWallet', {
        passphrase: 'agent-wallet-pass-1',
      });
      expect(res.error).toBeUndefined();
      expect(res.result.address).toMatch(/^0x[0-9a-fA-F]{40}$/);
      expect(typeof res.result.keystoreJson).toBe('string');

      const parsed = JSON.parse(res.result.keystoreJson);
      expect(parsed.version).toBe(3);
    });

    it('returns a keystore that decrypts with the same passphrase', async () => {
      const res = await sendRpc(dispatcher, 'agent.createWallet', [
        'agent-wallet-pass-2',
      ]);
      const wallet = await Wallet.fromEncryptedJson(
        res.result.keystoreJson,
        'agent-wallet-pass-2'
      );
      expect(wallet.address.toLowerCase()).toBe(
        res.result.address.toLowerCase()
      );
    });

    it('rejects empty or missing passphrase with INVALID_PARAMS', async () => {
      const empty = await sendRpc(dispatcher, 'agent.createWallet', {
        passphrase: '   ',
      });
      expect(empty.error).toBeDefined();
      expect(empty.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);

      const missing = await sendRpc(dispatcher, 'agent.createWallet', {});
      expect(missing.error).toBeDefined();
      expect(missing.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
    });

    it('never returns the private key as a response field', async () => {
      const res = await sendRpc(dispatcher, 'agent.createWallet', { passphrase: 'pw-3' });
      expect(res.result.privateKey).toBeUndefined();
      expect(res.result.mnemonic).toBeUndefined();
      expect(Object.keys(res.result).sort()).toEqual(['address', 'keystoreJson']);
    });
  });

  describe('wallet.sendRawTransaction', () => {
    it('broadcasts a signed 0x transaction via the active provider', async () => {
      const signed =
        '0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997ff761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83';
      const res = await sendRpc(dispatcher, 'wallet.sendRawTransaction', {
        signedTx: signed,
      });
      expect(res.error).toBeUndefined();
      expect(res.result.txHash).toBe(
        '0x1111111111111111111111111111111111111111111111111111111111111111'
      );
      expect(broadcastSpy).toHaveBeenCalledWith(signed);
    });

    it('accepts a positional array parameter', async () => {
      const res = await sendRpc(dispatcher, 'wallet.sendRawTransaction', ['0xf85b']);
      expect(res.error).toBeUndefined();
      expect(broadcastSpy).toHaveBeenCalledWith('0xf85b');
    });

    it('rejects non-hex or non-prefixed payloads with INVALID_PARAMS', async () => {
      for (const bad of ['deadbeef', '0xZZZZ', 42, null, undefined]) {
        const res = await sendRpc(dispatcher, 'wallet.sendRawTransaction', {
          signedTx: bad,
        });
        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      }
    });

    it('maps provider failures to INTERNAL_ERROR', async () => {
      broadcastSpy.mockRejectedValue(new Error('nonce too low'));
      const res = await sendRpc(dispatcher, 'wallet.sendRawTransaction', {
        signedTx: '0xf85b',
      });
      expect(res.error).toBeDefined();
      expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INTERNAL_ERROR);
      expect(res.error.message).toContain('nonce too low');
    });
  });


  describe('wallet.getTxContext', () => {
    it('returns nonce, gas price, and chain id for an address', async () => {
      mockProvider.getTransactionCount = vi.fn().mockResolvedValue(7);
      mockProvider.getFeeData = vi.fn().mockResolvedValue({ gasPrice: 3_000_000_000n });
      const res = await sendRpc(dispatcher, 'wallet.getTxContext', {
        address: '0x1111111111111111111111111111111111111111',
      });
      expect(res.error).toBeUndefined();
      expect(res.result.nonce).toBe(7);
      expect(res.result.gasPriceWei).toBe('3000000000');
      expect(res.result.chainId).toBe(97);
    });

    it('rejects a missing address with INVALID_PARAMS', async () => {
      const res = await sendRpc(dispatcher, 'wallet.getTxContext', {});
      expect(res.error).toBeDefined();
      expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
    });

    it('maps provider failures to INTERNAL_ERROR', async () => {
      mockProvider.getTransactionCount = vi.fn().mockRejectedValue(new Error('RPC down'));
      mockProvider.getFeeData = vi.fn().mockRejectedValue(new Error('RPC down'));
      const res = await sendRpc(dispatcher, 'wallet.getTxContext', { address: '0x1111111111111111111111111111111111111111' });
      expect(res.error).toBeDefined();
      expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INTERNAL_ERROR);
      expect(res.error.message).toContain('RPC down');
    });
  });


  describe('wallet.getAllowance & wallet.buildApproveTx', () => {
    it('returns the raw allowance for a token/owner/spender triple', async () => {
      mockProvider.call = vi.fn().mockResolvedValue('0x0000000000000000000000000000000000000000000000000000000000000000');
      const res = await sendRpc(dispatcher, 'wallet.getAllowance', {
        tokenAddress: '0x337610d27c682E347C9cD60BD4b3b107C9d34dDd',
        owner: '0x1111111111111111111111111111111111111111',
      });
      expect(res.error).toBeUndefined();
      expect(res.result.allowanceWei).toBe('0');
      expect(res.result.spender).toBe('0xD99D1c33F9fC3444f8101754aBC46c52416550D1');
    });

    it('rejects missing token or owner with INVALID_PARAMS', async () => {
      const res = await sendRpc(dispatcher, 'wallet.getAllowance', { tokenAddress: '0x337610d27c682E347C9cD60BD4b3b107C9d34dDd' });
      expect(res.error).toBeDefined();
      expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
    });

    it('builds an unlimited approve calldata for the active-chain router', async () => {
      const res = await sendRpc(dispatcher, 'wallet.buildApproveTx', {
        tokenAddress: '0x337610d27c682E347C9cD60BD4b3b107C9d34dDd',
        chainId: 97,
      });
      expect(res.error).toBeUndefined();
      expect(res.result.to.toLowerCase()).toBe('0x337610d27c682e347c9cd60bd4b3b107c9d34ddd');
      expect(res.result.value).toBe('0');
      expect(res.result.data.startsWith('0x095ea7b3')).toBe(true);
      expect(res.result.data.endsWith(MaxUint256.toString(16).padStart(64, '0'))).toBe(true);
      expect(res.result.chainId).toBe(97);
    });

    it('builds a mainnet approve against the mainnet router', async () => {
      const res = await sendRpc(dispatcher, 'wallet.buildApproveTx', {
        tokenAddress: '0x337610d27c682E347C9cD60BD4b3b107C9d34dDd',
        chainId: 56,
      });
      expect(res.error).toBeUndefined();
      expect(res.result.chainId).toBe(56);
    });

    it('rejects missing token with INVALID_PARAMS', async () => {
      const res = await sendRpc(dispatcher, 'wallet.buildApproveTx', {});
      expect(res.error).toBeDefined();
      expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
    });
  });

  describe('per-chain PancakeSwap deployment guard', () => {
    it('builds a mainnet swap against the mainnet router', async () => {
      const res = await sendRpc(dispatcher, 'wallet.buildSwapTx', {
        tokenIn: '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        tokenOut: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8',
        amountIn: '0.01',
        amountOutMin: '30',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 56,
      });
      expect(res.error).toBeUndefined();
      expect(res.result.to.toLowerCase()).toBe('0x10ed43c718714eb63d5aa57b78b54704e256024e');
      expect(res.result.chainId).toBe(56);
    });

    it('refuses to build a swap for a chain without a deployment', async () => {
      const res = await sendRpc(dispatcher, 'wallet.buildSwapTx', {
        tokenIn: '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        tokenOut: '0x2170Ed0880ac9A755fd29B2688956F933F8',
        amountIn: '0.01',
        amountOutMin: '30',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 5611,
      });
      expect(res.error).toBeDefined();
      expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INTERNAL_ERROR);
      expect(res.error.message).toContain('5611');
    });
  });

  describe('pay_x402 tool spending cap', () => {
    it('passes a default maxAmount to sdk.payX402', async () => {
      const { createDefaultTools, DEFAULT_MAX_X402_AMOUNT } = await import('../src/agent/tools.js');
      const paySpy = vi.fn().mockResolvedValue({ txHash: '0x1' });
      const stubSdk = { payX402: paySpy, chainId: 97 } as any;
      const tools = createDefaultTools({ sdk: stubSdk });
      const payTool = tools.find((t) => t.definition.function.name === 'pay_x402_service')!;

      await payTool.handler({ token: 'tBNB', amount: '0.001', recipient: '0x1111111111111111111111111111111111111111' });

      expect(paySpy).toHaveBeenCalledTimes(1);
      expect(paySpy.mock.calls[0][1]).toEqual({ maxAmount: DEFAULT_MAX_X402_AMOUNT });
    });

    it('propagates cap rejections from the sdk', async () => {
      const { createDefaultTools } = await import('../src/agent/tools.js');
      const paySpy = vi.fn().mockRejectedValue(
        new Error('Payment amount 5 exceeds maximum allowed limit of 1')
      );
      const stubSdk = { payX402: paySpy, chainId: 97 } as any;
      const tools = createDefaultTools({ sdk: stubSdk });
      const payTool = tools.find((t) => t.definition.function.name === 'pay_x402_service')!;

      await expect(
        payTool.handler({ token: 'tBNB', amount: '5', recipient: '0x1111111111111111111111111111111111111111' })
      ).rejects.toThrow('exceeds maximum');
    });
  });

  describe('daemon module', () => {
    it('exports a startDaemon function without side effects under vitest', () => {
      expect(typeof daemonModule.startDaemon).toBe('function');
    });
  });
});
