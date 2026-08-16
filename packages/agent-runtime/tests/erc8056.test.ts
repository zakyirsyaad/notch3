import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { ZeroAddress, JsonRpcProvider, Interface } from 'ethers';
import {
  toUIAmount,
  fromUIAmount,
  fetchTokenScaledBalance,
} from '../src/bnb/erc8056.js';
import {
  getBSCProvider,
  BSC_TESTNET_CHAIN_ID,
  DEFAULT_BSC_TESTNET_RPC,
} from '../src/bnb/provider.js';
import { isTokenBalance } from '@notch/shared-types';

describe('ERC-8056 Scaled UI Amount Conversion', () => {
  describe('toUIAmount & fromUIAmount (Standard ERC-20 / no multiplier)', () => {
    it('correctly converts standard 18 decimal token without multiplier', () => {
      const raw = 1500000000000000000n; // 1.5 ether
      expect(toUIAmount(raw, 18)).toBe('1.5');
      expect(fromUIAmount('1.5', 18)).toBe(raw);
    });

    it('correctly handles zero amount', () => {
      expect(toUIAmount(0n, 18)).toBe('0');
      expect(fromUIAmount('0', 18)).toBe(0n);
      expect(fromUIAmount('0.000', 18)).toBe(0n);
      expect(fromUIAmount('-0', 18)).toBe(0n);
      expect(fromUIAmount('+0.0', 18)).toBe(0n);
    });

    it('correctly formats whole integers without trailing decimal point', () => {
      const raw = 10000000000000000000n; // 10 ether
      expect(toUIAmount(raw, 18)).toBe('10');
      expect(fromUIAmount('10', 18)).toBe(raw);
    });

    it('correctly handles fractional amounts with leading zeros in fraction', () => {
      const raw = 10000000000000n; // 0.00001 ether (18 decimals)
      expect(toUIAmount(raw, 18)).toBe('0.00001');
      expect(fromUIAmount('0.00001', 18)).toBe(raw);

      const oneWei = 1n;
      expect(toUIAmount(oneWei, 18)).toBe('0.000000000000000001');
      expect(fromUIAmount('0.000000000000000001', 18)).toBe(oneWei);
    });

    it('handles 6 decimal tokens (e.g. USDT, USDC)', () => {
      const raw = 1234567n; // 1.234567
      expect(toUIAmount(raw, 6)).toBe('1.234567');
      expect(fromUIAmount('1.234567', 6)).toBe(raw);

      const smallRaw = 50n; // 0.000050
      expect(toUIAmount(smallRaw, 6)).toBe('0.00005');
      expect(fromUIAmount('0.00005', 6)).toBe(smallRaw);
    });

    it('handles 8 decimal tokens (e.g. WBTC)', () => {
      const raw = 50000000n; // 0.5 WBTC
      expect(toUIAmount(raw, 8)).toBe('0.5');
      expect(fromUIAmount('0.5', 8)).toBe(raw);
    });

    it('handles 0 decimal tokens', () => {
      const raw = 42n;
      expect(toUIAmount(raw, 0)).toBe('42');
      expect(fromUIAmount('42', 0)).toBe(raw);
      expect(toUIAmount(0n, 0)).toBe('0');
      expect(fromUIAmount('0', 0)).toBe(0n);
    });

    it('handles large numbers without precision loss', () => {
      const largeRaw = 1000000000000000000000000000n; // 1 billion tokens with 18 decimals
      expect(toUIAmount(largeRaw, 18)).toBe('1000000000');
      expect(fromUIAmount('1000000000', 18)).toBe(largeRaw);
    });

    it('handles negative amounts correctly', () => {
      const raw = -1500000000000000000n;
      expect(toUIAmount(raw, 18)).toBe('-1.5');
      expect(fromUIAmount('-1.5', 18)).toBe(raw);
    });

    it('handles explicit positive sign in string', () => {
      const raw = 1500000000000000000n;
      expect(fromUIAmount('+1.5', 18)).toBe(raw);
    });
  });

  describe('ERC-8056 Scaled UI Amount conversion (with multiplier)', () => {
    it('correctly applies custom scaling multiplier for ERC-8056 token (6 decimals, 2x)', () => {
      // 6 decimals, multiplier = 2x (e.g. 2 * 10^6)
      const raw = 1000000n;
      const multiplier = 2000000n; // 2.0x scale
      expect(toUIAmount(raw, 6, multiplier)).toBe('2');
      expect(fromUIAmount('2', 6, multiplier)).toBe(raw);
    });

    it('correctly applies 1.5x multiplier for 18 decimal token', () => {
      const raw = 1000000000000000000n; // 1.0 token
      const multiplier = 1500000000000000000n; // 1.5x scale
      expect(toUIAmount(raw, 18, multiplier)).toBe('1.5');
      expect(fromUIAmount('1.5', 18, multiplier)).toBe(raw);
    });

    it('correctly applies 0.5x multiplier for 8 decimal token', () => {
      const raw = 200000000n; // 2.0 raw
      const multiplier = 50000000n; // 0.5x scale
      expect(toUIAmount(raw, 8, multiplier)).toBe('1');
      expect(fromUIAmount('1', 8, multiplier)).toBe(raw);
    });

    it('handles fractional scaled amounts accurately', () => {
      const raw = 750000n; // 0.75 raw
      const multiplier = 2000000n; // 2.0x scale
      expect(toUIAmount(raw, 6, multiplier)).toBe('1.5');
      expect(fromUIAmount('1.5', 6, multiplier)).toBe(raw);
    });

    it('handles zero with multiplier', () => {
      const multiplier = 2000000n;
      expect(toUIAmount(0n, 6, multiplier)).toBe('0');
      expect(fromUIAmount('0', 6, multiplier)).toBe(0n);
    });

    it('handles negative with multiplier', () => {
      const raw = -1000000n;
      const multiplier = 2000000n;
      expect(toUIAmount(raw, 6, multiplier)).toBe('-2');
      expect(fromUIAmount('-2', 6, multiplier)).toBe(raw);
    });

    it('handles 0 decimals with multiplier', () => {
      const raw = 10n;
      const multiplier = 2n; // 2x
      expect(toUIAmount(raw, 0, multiplier)).toBe('20');
      expect(fromUIAmount('20', 0, multiplier)).toBe(raw);
    });
  });

  describe('Validation & Error Handling', () => {
    it('throws on invalid UI amount string', () => {
      expect(() => fromUIAmount('abc', 18)).toThrow(/invalid ui amount/i);
      expect(() => fromUIAmount('', 18)).toThrow(/invalid ui amount/i);
      expect(() => fromUIAmount('1.2.3', 18)).toThrow(/invalid ui amount/i);
      expect(() => fromUIAmount('.', 18)).toThrow(/invalid ui amount/i);
      expect(() => fromUIAmount('-.', 18)).toThrow(/invalid ui amount/i);
      expect(() => fromUIAmount('12a.45', 18)).toThrow(/invalid ui amount/i);
    });

    it('throws on invalid decimals', () => {
      expect(() => toUIAmount(100n, -1)).toThrow(/invalid decimals/i);
      expect(() => toUIAmount(100n, 256)).toThrow(/invalid decimals/i);
      expect(() => toUIAmount(100n, 1.5)).toThrow(/invalid decimals/i);
      expect(() => fromUIAmount('1.0', -1)).toThrow(/invalid decimals/i);
      expect(() => fromUIAmount('1.0', 256)).toThrow(/invalid decimals/i);
    });

    it('throws on non-positive multiplier', () => {
      expect(() => toUIAmount(100n, 6, 0n)).toThrow(/invalid multiplier/i);
      expect(() => toUIAmount(100n, 6, -100n)).toThrow(/invalid multiplier/i);
      expect(() => fromUIAmount('1.0', 6, 0n)).toThrow(/invalid multiplier/i);
      expect(() => fromUIAmount('1.0', 6, -100n)).toThrow(/invalid multiplier/i);
    });
  });
});

describe('BSC Provider', () => {
  const originalRpc = process.env.BSC_RPC_URL;

  beforeEach(() => {
    delete process.env.BSC_RPC_URL;
  });

  afterEach(() => {
    if (originalRpc) {
      process.env.BSC_RPC_URL = originalRpc;
    } else {
      delete process.env.BSC_RPC_URL;
    }
  });

  it('returns default JsonRpcProvider for BSC Testnet', () => {
    const provider = getBSCProvider();
    expect(provider).toBeInstanceOf(JsonRpcProvider);
    expect(BSC_TESTNET_CHAIN_ID).toBe(97);
    expect(DEFAULT_BSC_TESTNET_RPC).toContain('binance.org');
  });

  it('accepts custom RPC URL', () => {
    const customUrl = 'https://bsc-testnet.publicnode.com';
    const provider = getBSCProvider(customUrl);
    expect(provider).toBeInstanceOf(JsonRpcProvider);
  });

  it('uses process.env.BSC_RPC_URL when available', () => {
    process.env.BSC_RPC_URL = 'https://custom-testnet-rpc.com';
    const provider = getBSCProvider();
    expect(provider).toBeInstanceOf(JsonRpcProvider);
  });
});

describe('fetchTokenScaledBalance', () => {
  const tokenInterface = new Interface([
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function balanceOf(address owner) view returns (uint256)',
    'function multiplier() view returns (uint256)',
  ]);

  it('fetches native BNB balance when tokenAddress is ZeroAddress or tBNB', async () => {
    const mockProvider = {
      getBalance: vi.fn().mockResolvedValue(1500000000000000000n),
    } as unknown as JsonRpcProvider;

    const balance = await fetchTokenScaledBalance(
      ZeroAddress,
      '0x2222222222222222222222222222222222222222',
      mockProvider
    );

    expect(isTokenBalance(balance)).toBe(true);
    expect(balance.symbol).toBe('tBNB');
    expect(balance.name).toBe('BNB');
    expect(balance.decimals).toBe(18);
    expect(balance.rawBalance).toBe('1500000000000000000');
    expect(balance.uiBalance).toBe('1.5');
    expect(balance.isERC8056).toBe(false);
    expect(balance.multiplier).toBeUndefined();
  });

  it('fetches native BNB balance when tokenAddress is "tBNB" case-insensitively', async () => {
    const mockProvider = {
      getBalance: vi.fn().mockResolvedValue(500000000000000000n),
    } as unknown as JsonRpcProvider;

    const balance = await fetchTokenScaledBalance(
      'tbnb',
      '0x2222222222222222222222222222222222222222',
      mockProvider
    );

    expect(balance.symbol).toBe('tBNB');
    expect(balance.decimals).toBe(18);
    expect(balance.uiBalance).toBe('0.5');
  });

  it('fetches standard ERC-20 token balance without multiplier', async () => {
    const mockProvider = {
      call: vi.fn().mockImplementation(async (tx: { to: string; data: string }) => {
        const selector = tx.data.slice(0, 10);
        if (selector === tokenInterface.getFunction('name')!.selector) {
          return tokenInterface.encodeFunctionResult('name', ['Tether USD']);
        }
        if (selector === tokenInterface.getFunction('symbol')!.selector) {
          return tokenInterface.encodeFunctionResult('symbol', ['USDT']);
        }
        if (selector === tokenInterface.getFunction('decimals')!.selector) {
          return tokenInterface.encodeFunctionResult('decimals', [6]);
        }
        if (selector === tokenInterface.getFunction('balanceOf')!.selector) {
          return tokenInterface.encodeFunctionResult('balanceOf', [5000000n]);
        }
        if (selector === tokenInterface.getFunction('multiplier')!.selector) {
          throw new Error('execution reverted: multiplier not defined');
        }
        throw new Error(`unknown selector ${selector}`);
      }),
    } as unknown as JsonRpcProvider;

    const tokenAddr = '0x3333333333333333333333333333333333333333';
    const walletAddr = '0x2222222222222222222222222222222222222222';

    const balance = await fetchTokenScaledBalance(tokenAddr, walletAddr, mockProvider);
    expect(isTokenBalance(balance)).toBe(true);
    expect(balance.tokenAddress).toBe(tokenAddr);
    expect(balance.name).toBe('Tether USD');
    expect(balance.symbol).toBe('USDT');
    expect(balance.decimals).toBe(6);
    expect(balance.rawBalance).toBe('5000000');
    expect(balance.uiBalance).toBe('5');
    expect(balance.isERC8056).toBe(false);
    expect(balance.multiplier).toBeUndefined();
  });

  it('fetches ERC-8056 token balance with dynamic multiplier', async () => {
    const mockProvider = {
      call: vi.fn().mockImplementation(async (tx: { to: string; data: string }) => {
        const selector = tx.data.slice(0, 10);
        if (selector === tokenInterface.getFunction('name')!.selector) {
          return tokenInterface.encodeFunctionResult('name', ['Scaled Wrapped BNB']);
        }
        if (selector === tokenInterface.getFunction('symbol')!.selector) {
          return tokenInterface.encodeFunctionResult('symbol', ['sWBNB']);
        }
        if (selector === tokenInterface.getFunction('decimals')!.selector) {
          return tokenInterface.encodeFunctionResult('decimals', [18]);
        }
        if (selector === tokenInterface.getFunction('balanceOf')!.selector) {
          return tokenInterface.encodeFunctionResult('balanceOf', [1000000000000000000n]); // 1.0 raw
        }
        if (selector === tokenInterface.getFunction('multiplier')!.selector) {
          return tokenInterface.encodeFunctionResult('multiplier', [2000000000000000000n]); // 2.0x scale
        }
        throw new Error(`unknown selector ${selector}`);
      }),
    } as unknown as JsonRpcProvider;

    const tokenAddr = '0x4444444444444444444444444444444444444444';
    const walletAddr = '0x2222222222222222222222222222222222222222';

    const balance = await fetchTokenScaledBalance(tokenAddr, walletAddr, mockProvider);
    expect(isTokenBalance(balance)).toBe(true);
    expect(balance.tokenAddress).toBe(tokenAddr);
    expect(balance.name).toBe('Scaled Wrapped BNB');
    expect(balance.symbol).toBe('sWBNB');
    expect(balance.decimals).toBe(18);
    expect(balance.rawBalance).toBe('1000000000000000000');
    expect(balance.uiBalance).toBe('2'); // 1.0 * 2.0x = 2
    expect(balance.isERC8056).toBe(true);
    expect(balance.multiplier).toBe('2000000000000000000');
  });
});
