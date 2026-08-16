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
  MaxUint256,
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

export const PANCAKESWAP_ROUTER_MAINNET = '0x10ED43C718714eb63d5aA57B78B54704E256024E';
export const PANCAKESWAP_FACTORY_MAINNET = '0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73';
export const WBNB_MAINNET = '0xBB4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';

/**
 * Per-chain PancakeSwap V2 deployment addresses.
 * A swap built for a chain without an entry here must FAIL LOUDLY —
 * routing a mainnet transaction to a testnet router loses funds.
 */
export interface PancakeSwapDeployment {
  chainId: number;
  router: string;
  factory: string;
  wbnb: string;
}

export const PANCAKESWAP_DEPLOYMENTS: Record<number, PancakeSwapDeployment> = {
  97: {
    chainId: 97,
    router: PANCAKESWAP_ROUTER_TESTNET,
    factory: PANCAKESWAP_FACTORY_TESTNET,
    wbnb: WBNB_TESTNET,
  },
  56: {
    chainId: 56,
    router: PANCAKESWAP_ROUTER_MAINNET,
    factory: PANCAKESWAP_FACTORY_MAINNET,
    wbnb: WBNB_MAINNET,
  },
};

export function getPancakeSwapDeployment(chainId: number): PancakeSwapDeployment {
  const deployment = PANCAKESWAP_DEPLOYMENTS[chainId];
  if (!deployment) {
    throw new Error(
      `No PancakeSwap V2 deployment configured for chainId ${chainId}. ` +
        `Refusing to build a swap against a router from another chain — this would send funds to a wrong-network contract.`
    );
  }
  return deployment;
}

export const DEFAULT_SLIPPAGE_TOLERANCE_PERCENT = 0.5;
export const DEFAULT_DEADLINE_MINUTES = 20;
export const DEFAULT_SWAP_GAS_LIMIT = '250000';
export const DEFAULT_APPROVE_GAS_LIMIT = '60000';

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

const ERC20_ALLOWANCE_ABI = [
  'function allowance(address owner, address spender) view returns (uint256)',
];

const ERC20_APPROVE_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
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
 * Safely normalizes an EVM address or native BNB token identifier to a checksummed address,
 * using the WBNB contract of the given chain.
 */
export function normalizeTokenAddress(addressOrSymbol: string, chainId: number = BSC_TESTNET_CHAIN_ID): string {
  if (isNativeBNB(addressOrSymbol)) {
    return getAddress(getPancakeSwapDeployment(chainId).wbnb.toLowerCase());
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
  const chainId = params.chainId ?? BSC_TESTNET_CHAIN_ID;
  const deployment = getPancakeSwapDeployment(chainId);

  // Resolve metadata (decimals & ERC-8056 multiplier)
  const tokenInMeta = await resolveTokenMetadata(params.tokenIn, rpcProvider);
  const tokenOutMeta = await resolveTokenMetadata(params.tokenOut, rpcProvider);

  const rawAmountIn = fromUIAmount(params.amountIn, tokenInMeta.decimals, tokenInMeta.multiplier);
  if (rawAmountIn <= 0n) {
    throw new Error('Amount in must be greater than 0');
  }

  const inAddress = normalizeTokenAddress(params.tokenIn, chainId);
  const outAddress = normalizeTokenAddress(params.tokenOut, chainId);

  const path =
    params.route && params.route.length >= 2
      ? params.route.map((a) => normalizeTokenAddress(a, chainId))
      : [inAddress, outAddress];

  const routerAddress = getAddress(deployment.router.toLowerCase());
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
  const chainId = params.chainId ?? BSC_TESTNET_CHAIN_ID;
  const deployment = getPancakeSwapDeployment(chainId);

  const tokenInMeta = await resolveTokenMetadata(params.tokenIn, rpcProvider);
  const tokenOutMeta = await resolveTokenMetadata(params.tokenOut, rpcProvider);

  const rawAmountIn = fromUIAmount(params.amountIn, tokenInMeta.decimals, tokenInMeta.multiplier);
  const rawAmountOutMin = fromUIAmount(params.amountOutMin, tokenOutMeta.decimals, tokenOutMeta.multiplier);

  const isNativeIn = isNativeBNB(params.tokenIn);
  const isNativeOut = isNativeBNB(params.tokenOut);

  const inAddress = normalizeTokenAddress(params.tokenIn, chainId);
  const outAddress = normalizeTokenAddress(params.tokenOut, chainId);

  const path =
    params.route && params.route.length >= 2
      ? params.route.map((a) => normalizeTokenAddress(a, chainId))
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
    to: deployment.router,
    value,
    data,
    chainId,
    gasLimit: DEFAULT_SWAP_GAS_LIMIT,
    description,
  };
}

/**
 * Fetches the raw ERC-20 allowance granted by `owner` to `spender`.
 */
export async function getTokenAllowance(
  tokenAddress: string,
  owner: string,
  spender: string,
  provider?: Provider
): Promise<string> {
  if (!isAddress(tokenAddress)) {
    throw new Error('Invalid token address for allowance lookup.');
  }
  if (!isAddress(owner) || !isAddress(spender)) {
    throw new Error('Owner and spender must be valid addresses for allowance lookup.');
  }

  const rpcProvider = provider || getBSCProvider();
  const token = new Contract(getAddress(tokenAddress.toLowerCase()), ERC20_ALLOWANCE_ABI, rpcProvider);
  const allowance: bigint = await token.allowance(owner, spender);
  return allowance.toString();
}

export interface BuildApproveParams {
  tokenAddress: string;
  spender?: string;
  /** Raw integer amount in wei. Defaults to an unlimited approval. */
  amountWei?: string;
  chainId?: number;
}

/**
 * Builds an unsigned ERC-20 `approve` transaction (selector 0x095ea7b3) so the
 * PancakeSwap router (or another spender) may pull tokens during a swap.
 * Defaults to an unlimited approval, matching common wallet UX.
 */
export async function buildApproveTransaction(
  params: BuildApproveParams,
  provider?: Provider
): Promise<UnsignedTransactionPayload> {
  if (!params || !isAddress(params.tokenAddress)) {
    throw new Error('Invalid approve parameters: a valid tokenAddress is required.');
  }

  const chainId = params.chainId ?? BSC_TESTNET_CHAIN_ID;
  const deployment = getPancakeSwapDeployment(chainId);
  const spender = params.spender
    ? getAddress(params.spender.toLowerCase())
    : getAddress(deployment.router.toLowerCase());

  let amount: bigint;
  if (params.amountWei !== undefined && params.amountWei.trim() !== '') {
    try {
      amount = BigInt(params.amountWei.trim());
    } catch {
      throw new Error(`Invalid approve amount "${params.amountWei}": must be a decimal integer in wei.`);
    }
    if (amount < 0n) {
      throw new Error('Approve amount cannot be negative.');
    }
  } else {
    amount = MaxUint256;
  }

  const rpcProvider = provider || getBSCProvider();
  const token = getAddress(params.tokenAddress.toLowerCase());
  const tokenContract = new Contract(token, ERC20_APPROVE_ABI, rpcProvider);
  const data = (await tokenContract.approve.populateTransaction(spender, amount)).data;

  return {
    to: token,
    value: '0',
    data,
    chainId,
    gasLimit: DEFAULT_APPROVE_GAS_LIMIT,
    description: `Approve ${params.amountWei ? params.amountWei : 'unlimited'} token units for spender ${spender}`,
  };
}
