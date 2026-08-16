/**
 * PancakeSwap V2 Router Adapter (BSC Testnet 97)
 *
 * Provides swap quote estimation with ERC-8056 Scaled UI Amount conversion,
 * slippage protection calculations, and unsigned transaction payload generation
 * for native BNB and BEP-20 token swaps on BSC Testnet.
 */

import {
  Contract,
  Interface,
  ZeroAddress,
  isAddress,
  getAddress,
  type Provider,
  type JsonRpcProvider,
} from 'ethers';
import type {
  SwapQuoteParams,
  SwapQuoteResult,
  BuildSwapParams,
  UnsignedTransactionPayload,
} from '@notch/shared-types';
import { getBSCProvider, BSC_TESTNET_CHAIN_ID } from './provider.js';
import { toUIAmount, fromUIAmount } from './erc8056.js';

export const PANCAKESWAP_ROUTER_TESTNET = '0xD99D1c33F9fC3444f8101754aBC46c52416550D1';
export const PANCAKESWAP_FACTORY_TESTNET = '0x6725F303b657a9451d8BA641348b6761A6CC7a17';
export const WBNB_TESTNET = '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd';

export const DEFAULT_SLIPPAGE_TOLERANCE_PERCENT = 0.5;
export const DEFAULT_DEADLINE_MINUTES = 20;
export const DEFAULT_SWAP_GAS_LIMIT = '250000';

export const PANCAKESWAP_ROUTER_ABI = [
  'function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts)',
  'function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory amounts)',
  'function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts)',
  'function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts)',
  'function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable',
  'function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external',
  'function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external',
];

const ERC20_DECIMALS_ABI = [
  'function decimals() view returns (uint8)',
];

const ERC8056_MULTIPLIER_ABI = [
  'function multiplier() view returns (uint256)',
];

/**
 * Checks whether an address or symbol string represents native BNB / tBNB.
 */
export function isNativeBNB(addressOrSymbol: string): boolean {
  if (!addressOrSymbol) return true;
  const trimmed = addressOrSymbol.trim().toLowerCase();
  return (
    trimmed === 'bnb' ||
    trimmed === 'tbnb' ||
    trimmed === ZeroAddress.toLowerCase() ||
    trimmed === '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  );
}

/**
 * Safely normalizes an EVM address or native BNB token identifier to checksummed address.
 */
export function normalizeTokenAddress(addressOrSymbol: string): string {
  if (isNativeBNB(addressOrSymbol)) {
    return getAddress(WBNB_TESTNET.toLowerCase());
  }
  return getAddress(addressOrSymbol.toLowerCase());
}

/**
 * Queries token decimals and optional ERC-8056 scaling multiplier from on-chain provider.
 */
async function resolveTokenMetadata(
  tokenAddress: string,
  provider: Provider
): Promise<{ decimals: number; multiplier?: bigint }> {
  if (isNativeBNB(tokenAddress)) {
    return { decimals: 18, multiplier: undefined };
  }

  const checksummedAddress = normalizeTokenAddress(tokenAddress);

  let decimals = 18;
  try {
    const tokenContract = new Contract(checksummedAddress, ERC20_DECIMALS_ABI, provider);
    const d = await tokenContract.decimals();
    decimals = Number(d);
  } catch {
    decimals = 18;
  }

  let multiplier: bigint | undefined;
  try {
    const multContract = new Contract(checksummedAddress, ERC8056_MULTIPLIER_ABI, provider);
    const m = await multContract.multiplier();
    if (typeof m === 'bigint' && m > 0n) {
      multiplier = m;
    }
  } catch {
    multiplier = undefined;
  }

  return { decimals, multiplier };
}

/**
 * Estimates output amounts, computes minimum received amount after slippage,
 * and formats all token figures according to ERC-8056 standards.
 *
 * @param params Swap quoting parameters
 * @param provider Optional ethers JsonRpcProvider (defaults to BSC Testnet)
 * @returns Conforming SwapQuoteResult
 */
export async function estimateSwapQuote(
  params: SwapQuoteParams,
  provider?: JsonRpcProvider
): Promise<SwapQuoteResult> {
  if (!params || !params.tokenIn || !params.tokenOut || !params.amountIn) {
    throw new Error('Invalid swap quote parameters: tokenIn, tokenOut, and amountIn are required.');
  }

  const slippagePercent = params.slippageTolerancePercent ?? DEFAULT_SLIPPAGE_TOLERANCE_PERCENT;
  if (typeof slippagePercent !== 'number' || slippagePercent < 0 || slippagePercent > 100) {
    throw new Error(`Invalid slippage tolerance: ${slippagePercent}. Must be a percentage between 0 and 100.`);
  }

  const rpcProvider = provider || getBSCProvider();

  // Resolve metadata (decimals & ERC-8056 multiplier)
  const tokenInMeta = await resolveTokenMetadata(params.tokenIn, rpcProvider);
  const tokenOutMeta = await resolveTokenMetadata(params.tokenOut, rpcProvider);

  const rawAmountIn = fromUIAmount(params.amountIn, tokenInMeta.decimals, tokenInMeta.multiplier);
  if (rawAmountIn <= 0n) {
    throw new Error('Amount in must be greater than 0');
  }

  const inAddress = normalizeTokenAddress(params.tokenIn);
  const outAddress = normalizeTokenAddress(params.tokenOut);

  const path =
    params.route && params.route.length >= 2
      ? params.route.map((a) => normalizeTokenAddress(a))
      : [inAddress, outAddress];

  const routerAddress = getAddress(PANCAKESWAP_ROUTER_TESTNET.toLowerCase());
  const routerContract = new Contract(routerAddress, PANCAKESWAP_ROUTER_ABI, rpcProvider);
  const amounts: bigint[] = await routerContract.getAmountsOut(rawAmountIn, path);
  const rawAmountOut = amounts[amounts.length - 1];

  // Calculate amountOutMin with slippage tolerance
  // slippagePercent = 0.5 -> 50 basis points (out of 10000)
  const slippageBps = BigInt(Math.floor(slippagePercent * 100));
  const rawAmountOutMin = (rawAmountOut * (10000n - slippageBps)) / 10000n;

  const amountInUI = toUIAmount(rawAmountIn, tokenInMeta.decimals, tokenInMeta.multiplier);
  const amountOutUI = toUIAmount(rawAmountOut, tokenOutMeta.decimals, tokenOutMeta.multiplier);
  const amountOutMinUI = toUIAmount(rawAmountOutMin, tokenOutMeta.decimals, tokenOutMeta.multiplier);

  const inFloat = parseFloat(amountInUI);
  const outFloat = parseFloat(amountOutUI);
  const executionPrice = inFloat > 0 ? (outFloat / inFloat).toString() : '0';

  return {
    tokenIn: params.tokenIn,
    tokenOut: params.tokenOut,
    amountIn: amountInUI,
    amountOut: amountOutUI,
    amountOutMin: amountOutMinUI,
    slippageTolerancePercent: slippagePercent,
    route: path,
    priceImpactPercent: 0,
    executionPrice,
    estimatedGas: DEFAULT_SWAP_GAS_LIMIT,
  };
}

/**
 * Builds an unsigned transaction payload for PancakeSwap Router V2 on BSC Testnet.
 * Generates appropriate function calldata (swapExactETHForTokens, swapExactTokensForETH,
 * or swapExactTokensForTokens) and attaches required native value for ETH/BNB inputs.
 *
 * @param params Transaction parameters including amountIn, amountOutMin, and recipient
 * @param provider Optional ethers JsonRpcProvider
 * @returns UnsignedTransactionPayload ready for client-side Touch ID / keystore signing
 */
export async function buildSwapTransaction(
  params: BuildSwapParams,
  provider?: JsonRpcProvider
): Promise<UnsignedTransactionPayload> {
  if (!params || !params.recipient || !isAddress(params.recipient)) {
    throw new Error('Invalid recipient address. A valid EVM address is required.');
  }

  if (!params.tokenIn || !params.tokenOut || !params.amountIn || !params.amountOutMin) {
    throw new Error('Invalid build swap params: tokenIn, tokenOut, amountIn, and amountOutMin are required.');
  }

  const rpcProvider = provider || getBSCProvider();

  const tokenInMeta = await resolveTokenMetadata(params.tokenIn, rpcProvider);
  const tokenOutMeta = await resolveTokenMetadata(params.tokenOut, rpcProvider);

  const rawAmountIn = fromUIAmount(params.amountIn, tokenInMeta.decimals, tokenInMeta.multiplier);
  const rawAmountOutMin = fromUIAmount(params.amountOutMin, tokenOutMeta.decimals, tokenOutMeta.multiplier);

  const isNativeIn = isNativeBNB(params.tokenIn);
  const isNativeOut = isNativeBNB(params.tokenOut);

  const inAddress = normalizeTokenAddress(params.tokenIn);
  const outAddress = normalizeTokenAddress(params.tokenOut);

  const path =
    params.route && params.route.length >= 2
      ? params.route.map((a) => normalizeTokenAddress(a))
      : [inAddress, outAddress];

  const recipient = getAddress(params.recipient.toLowerCase());
  const deadline =
    params.deadline ??
    Math.floor(Date.now() / 1000) + DEFAULT_DEADLINE_MINUTES * 60;

  const routerInterface = new Interface(PANCAKESWAP_ROUTER_ABI);

  let data: string;
  let value: string;
  let description: string;

  if (isNativeIn) {
    // swapExactETHForTokens(amountOutMin, path, to, deadline)
    data = routerInterface.encodeFunctionData('swapExactETHForTokens', [
      rawAmountOutMin,
      path,
      recipient,
      deadline,
    ]);
    value = rawAmountIn.toString();
    description = `Swap ${params.amountIn} BNB on PancakeSwap`;
  } else if (isNativeOut) {
    // swapExactTokensForETH(amountIn, amountOutMin, path, to, deadline)
    data = routerInterface.encodeFunctionData('swapExactTokensForETH', [
      rawAmountIn,
      rawAmountOutMin,
      path,
      recipient,
      deadline,
    ]);
    value = '0';
    description = `Swap ${params.amountIn} tokens for BNB on PancakeSwap`;
  } else {
    // swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline)
    data = routerInterface.encodeFunctionData('swapExactTokensForTokens', [
      rawAmountIn,
      rawAmountOutMin,
      path,
      recipient,
      deadline,
    ]);
    value = '0';
    description = `Swap ${params.amountIn} tokens on PancakeSwap`;
  }

  return {
    to: PANCAKESWAP_ROUTER_TESTNET,
    value,
    data,
    chainId: params.chainId ?? BSC_TESTNET_CHAIN_ID,
    gasLimit: DEFAULT_SWAP_GAS_LIMIT,
    description,
  };
}
