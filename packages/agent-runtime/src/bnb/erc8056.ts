/**
 * ERC-8056 Scaled UI Amount Adapter & Token Balance Fetcher
 *
 * Provides exact BigInt precision arithmetic for ERC-8056 dynamic token scaling
 * and standard ERC-20 / native BNB balance queries.
 */

import { Contract, ZeroAddress, type Provider } from 'ethers';
import type { TokenBalance } from '@notch/shared-types';
import { getBSCProvider } from './provider.js';

const ERC20_METADATA_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address owner) view returns (uint256)',
];

const ERC8056_MULTIPLIER_ABI = [
  'function multiplier() view returns (uint256)',
];

/**
 * Converts a raw BigInt token balance into a human-readable UI amount string,
 * applying ERC-8056 multiplier scaling when present.
 *
 * @param rawAmount Token raw integer amount (in lowest denomination / wei)
 * @param decimals Token decimals (0 to 255)
 * @param multiplier Optional ERC-8056 scaling multiplier (in base 10^decimals)
 * @returns Formatted UI decimal string without trailing zeros
 */
export function toUIAmount(
  rawAmount: bigint,
  decimals: number,
  multiplier?: bigint
): string {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 255) {
    throw new Error(`Invalid decimals: ${decimals}. Must be an integer between 0 and 255.`);
  }

  if (multiplier !== undefined && multiplier <= 0n) {
    throw new Error(`Invalid multiplier: ${multiplier}. Must be a positive integer.`);
  }

  const isNegative = rawAmount < 0n;
  const absRaw = isNegative ? -rawAmount : rawAmount;

  if (absRaw === 0n) {
    return '0';
  }

  let formatted: string;

  if (multiplier !== undefined) {
    const scaleFactor = 10n ** BigInt(2 * decimals);
    const scaled = absRaw * multiplier;
    const integerPart = scaleFactor === 0n || 2 * decimals === 0 ? scaled : scaled / scaleFactor;
    const remainder = 2 * decimals === 0 ? 0n : scaled % scaleFactor;

    if (remainder === 0n) {
      formatted = integerPart.toString();
    } else {
      const fracStr = remainder.toString().padStart(2 * decimals, '0').replace(/0+$/, '');
      formatted = `${integerPart.toString()}.${fracStr}`;
    }
  } else {
    if (decimals === 0) {
      formatted = absRaw.toString();
    } else {
      const scaleFactor = 10n ** BigInt(decimals);
      const integerPart = absRaw / scaleFactor;
      const remainder = absRaw % scaleFactor;

      if (remainder === 0n) {
        formatted = integerPart.toString();
      } else {
        const fracStr = remainder.toString().padStart(decimals, '0').replace(/0+$/, '');
        formatted = `${integerPart.toString()}.${fracStr}`;
      }
    }
  }

  return isNegative ? `-${formatted}` : formatted;
}

/**
 * Converts a UI amount string back into raw token BigInt,
 * reversing ERC-8056 multiplier scaling when present.
 *
 * @param uiAmount Human-readable UI amount string (e.g. "1.5", "2")
 * @param decimals Token decimals (0 to 255)
 * @param multiplier Optional ERC-8056 scaling multiplier (in base 10^decimals)
 * @returns Raw integer amount (in lowest denomination / wei)
 */
export function fromUIAmount(
  uiAmount: string,
  decimals: number,
  multiplier?: bigint
): bigint {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 255) {
    throw new Error(`Invalid decimals: ${decimals}. Must be an integer between 0 and 255.`);
  }

  if (multiplier !== undefined && multiplier <= 0n) {
    throw new Error(`Invalid multiplier: ${multiplier}. Must be a positive integer.`);
  }

  const trimmed = uiAmount.trim();
  const validRegex = /^([+-])?(?:\d+(?:\.\d*)?|\.\d+)$/;
  if (!trimmed || !validRegex.test(trimmed) || trimmed === '.' || trimmed === '+.' || trimmed === '-.') {
    throw new Error(`Invalid UI amount string: "${uiAmount}"`);
  }

  const isNegative = trimmed.startsWith('-');
  const cleaned = trimmed.replace(/^[+-]/, '');

  const parts = cleaned.split('.');
  const intStr = parts[0] || '0';
  const fracStr = parts[1] || '';

  const fracDigits = fracStr.length;
  const fullNumStr = intStr + fracStr;
  const numBigInt = BigInt(fullNumStr);

  if (numBigInt === 0n) {
    return 0n;
  }

  let rawAbs: bigint;

  if (multiplier !== undefined) {
    // UI = (raw * multiplier) / (10^(2 * decimals))
    // UI = numBigInt / (10^fracDigits)
    // raw = (numBigInt * 10^(2 * decimals)) / (multiplier * 10^fracDigits)
    const numerator = numBigInt * (10n ** BigInt(2 * decimals));
    const denominator = multiplier * (10n ** BigInt(fracDigits));
    rawAbs = numerator / denominator;
  } else {
    // UI = raw / (10^decimals)
    // raw = (numBigInt * 10^decimals) / (10^fracDigits)
    if (decimals >= fracDigits) {
      rawAbs = numBigInt * (10n ** BigInt(decimals - fracDigits));
    } else {
      rawAbs = numBigInt / (10n ** BigInt(fracDigits - decimals));
    }
  }

  return isNegative ? -rawAbs : rawAbs;
}

/**
 * Fetches token balance (Native BNB, standard ERC-20, or ERC-8056 Scaled UI Token)
 * for a specific wallet address.
 *
 * @param tokenAddress Token contract address or ZeroAddress for native BNB
 * @param walletAddress Wallet address to query
 * @param provider Optional ethers Provider. Defaults to getBSCProvider()
 * @returns TokenBalance conforming to @notch/shared-types
 */
export async function fetchTokenScaledBalance(
  tokenAddress: string,
  walletAddress: string,
  provider?: Provider
): Promise<TokenBalance> {
  const rpcProvider = provider || getBSCProvider();

  const isNative =
    !tokenAddress ||
    tokenAddress.toLowerCase() === ZeroAddress.toLowerCase() ||
    tokenAddress.toLowerCase() === '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ||
    tokenAddress.toUpperCase() === 'BNB' ||
    tokenAddress.toUpperCase() === 'TBNB';

  if (isNative) {
    const rawBalance = await rpcProvider.getBalance(walletAddress);
    const decimals = 18;
    const uiBalance = toUIAmount(rawBalance, decimals);

    return {
      tokenAddress: ZeroAddress,
      name: 'BNB',
      symbol: 'tBNB',
      decimals,
      rawBalance: rawBalance.toString(),
      uiBalance,
      isERC8056: false,
    };
  }

  const tokenContract = new Contract(tokenAddress, ERC20_METADATA_ABI, rpcProvider);

  const [name, symbol, decimalsRaw, rawBalance] = await Promise.all([
    tokenContract.name().catch(() => 'Unknown Token'),
    tokenContract.symbol().catch(() => 'UNKNOWN'),
    tokenContract.decimals().catch(() => 18),
    tokenContract.balanceOf(walletAddress),
  ]);

  const decimals = Number(decimalsRaw);
  const rawBalanceBigInt = BigInt(rawBalance.toString());

  // Attempt to check if token implements ERC-8056 multiplier()
  let multiplier: bigint | undefined;
  let isERC8056 = false;

  try {
    const erc8056Contract = new Contract(tokenAddress, ERC8056_MULTIPLIER_ABI, rpcProvider);
    const multVal = await erc8056Contract.multiplier();
    if (typeof multVal === 'bigint' && multVal > 0n) {
      multiplier = multVal;
      isERC8056 = true;
    }
  } catch {
    isERC8056 = false;
  }

  const uiBalance = toUIAmount(rawBalanceBigInt, decimals, multiplier);

  return {
    tokenAddress,
    name,
    symbol,
    decimals,
    rawBalance: rawBalanceBigInt.toString(),
    uiBalance,
    multiplier: multiplier !== undefined ? multiplier.toString() : undefined,
    isERC8056,
  };
}
