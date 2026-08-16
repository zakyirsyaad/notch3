/**
 * x402 HTTP 402 Payment Required Client & Settlement Handler
 *
 * Implements challenge parsing, parameter extraction, agent-wallet signing,
 * balance pre-checks, and BSC Testnet settlement for autonomous x402 payments.
 */

import {
  isAddress,
  parseEther,
  formatEther,
  Contract,
  ZeroAddress,
  type Provider,
} from 'ethers';
import type {
  X402PaymentChallenge,
  X402PaymentReceipt,
} from '@notch/shared-types';
import type { AgentSession } from '../wallet/session.js';
import { getBSCProvider, BSC_TESTNET_CHAIN_ID } from './provider.js';
import { fetchTokenScaledBalance, fromUIAmount } from './erc8056.js';

export interface X402PaymentOptions {
  provider?: Provider;
  maxAmount?: string;
  allowedTokens?: string[];
  allowedChainIds?: number[];
}

const ERC20_TRANSFER_ABI = [
  'function transfer(address to, uint256 amount) returns (bool)',
];

/**
 * Normalizes HTTP headers object for case-insensitive lookup.
 */
function getHeaderValue(
  headers: Record<string, string | string[] | undefined>,
  name: string
): string | undefined {
  const target = name.toLowerCase();
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === target) {
      const val = headers[key];
      return Array.isArray(val) ? val[0] : val;
    }
  }
  return undefined;
}

/**
 * Parses key-value pairs from a challenge header string (e.g. `token="tBNB", amount="0.001"`).
 */
function parseHeaderAttributes(headerStr: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  // Remove "x402" scheme prefix if present
  const content = headerStr.replace(/^\s*x402\s+/i, '').trim();

  const regex = /([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^,\s;]+))/g;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(content)) !== null) {
    const key = match[1].toLowerCase();
    const val = match[2] ?? match[3] ?? match[4] ?? '';
    attrs[key] = val;
  }

  return attrs;
}

/**
 * Parses and validates an x402 HTTP challenge from response headers and/or body.
 *
 * @param headers HTTP response headers
 * @param body Optional HTTP response body (JSON object or string)
 * @returns Conforming X402PaymentChallenge
 */
export function parseX402Challenge(
  headers: Record<string, string | string[] | undefined>,
  body?: unknown
): X402PaymentChallenge {
  const authHeader = getHeaderValue(headers, 'www-authenticate');
  let extracted: Record<string, unknown> = {};

  if (authHeader && /x402/i.test(authHeader)) {
    extracted = parseHeaderAttributes(authHeader);
  }

  // Fall back to or merge with JSON body if available
  let bodyData: Record<string, unknown> = {};
  if (body) {
    if (typeof body === 'string') {
      try {
        bodyData = JSON.parse(body);
      } catch {
        // Ignored if body is not valid JSON
      }
    } else if (typeof body === 'object' && body !== null && !Array.isArray(body)) {
      bodyData = body as Record<string, unknown>;
    }
  }

  const candidateBody =
    (bodyData['x402'] as Record<string, unknown>) ||
    (bodyData['payment'] as Record<string, unknown>) ||
    (bodyData['challenge'] as Record<string, unknown>) ||
    bodyData;

  const rawToken = String(
    extracted['token'] || candidateBody['token'] || 'tBNB'
  ).trim();

  const rawAmount = String(
    extracted['amount'] || candidateBody['amount'] || ''
  ).trim();

  const rawRecipient = String(
    extracted['recipient'] || candidateBody['recipient'] || ''
  ).trim();

  const rawChainId =
    extracted['chainid'] ||
    extracted['chain_id'] ||
    candidateBody['chainId'] ||
    candidateBody['chain_id'] ||
    candidateBody['chainid'] ||
    BSC_TESTNET_CHAIN_ID;

  const resource = extracted['resource'] || candidateBody['resource'];
  const description = extracted['description'] || candidateBody['description'];
  const nonce = extracted['nonce'] || candidateBody['nonce'];

  // Validation
  if (!rawRecipient) {
    throw new Error('Invalid x402 challenge: Missing recipient address.');
  }

  if (!isAddress(rawRecipient)) {
    throw new Error(`Invalid x402 challenge: Invalid recipient address "${rawRecipient}".`);
  }

  if (!rawAmount) {
    throw new Error('Invalid x402 challenge: Missing payment amount.');
  }

  const amountNum = parseFloat(rawAmount);
  if (isNaN(amountNum) || amountNum <= 0) {
    throw new Error(`Invalid x402 challenge: Payment amount must be positive, received "${rawAmount}".`);
  }

  const chainId = typeof rawChainId === 'number' ? rawChainId : parseInt(String(rawChainId), 10);
  if (isNaN(chainId) || chainId <= 0) {
    throw new Error(`Invalid x402 challenge: Invalid chain ID "${rawChainId}".`);
  }

  return {
    token: rawToken,
    amount: rawAmount,
    recipient: rawRecipient,
    chainId,
    resource: typeof resource === 'string' ? resource : undefined,
    description: typeof description === 'string' ? description : undefined,
    nonce: typeof nonce === 'string' ? nonce : undefined,
  };
}

/**
 * Formats standard HTTP headers containing x402 settlement proof for subsequent requests.
 *
 * @param receipt Completed payment receipt or object containing txHash
 * @returns Headers record with Authorization and X-402-TxHash
 */
export function createX402PaymentHeaders(
  receipt: X402PaymentReceipt | { txHash: string }
): Record<string, string> {
  return {
    Authorization: `x402 ${receipt.txHash}`,
    'X-402-TxHash': receipt.txHash,
  };
}

/**
 * Checks if a token representation is native BNB / tBNB.
 */
function isNativeBNB(token: string): boolean {
  const lower = token.trim().toLowerCase();
  return (
    lower === 'tbnb' ||
    lower === 'bnb' ||
    lower === ZeroAddress.toLowerCase() ||
    lower === '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  );
}

/**
 * Executes an x402 payment challenge using the unlocked AgentSession wallet on BSC Testnet.
 * Performs pre-flight balance validation, gas estimation, transaction signing, and settlement.
 *
 * @param challenge The parsed x402 payment challenge
 * @param session Active unlocked AgentSession
 * @param options Payment limits, custom provider, and security filters
 * @returns X402PaymentReceipt with transaction details
 */
export async function executeX402Payment(
  challenge: X402PaymentChallenge,
  session: AgentSession,
  options?: X402PaymentOptions
): Promise<X402PaymentReceipt> {
  if (!session || !session.isUnlocked()) {
    throw new Error('Agent session is locked. Please unlock agent wallet before executing payment.');
  }

  // Safety limits validation
  if (options?.maxAmount) {
    const max = parseFloat(options.maxAmount);
    const amount = parseFloat(challenge.amount);
    if (!isNaN(max) && !isNaN(amount) && amount > max) {
      throw new Error(
        `Payment amount ${challenge.amount} exceeds maximum allowed limit of ${options.maxAmount} ${challenge.token}`
      );
    }
  }

  if (options?.allowedTokens && options.allowedTokens.length > 0) {
    const isAllowed = options.allowedTokens.some(
      (t) => t.toLowerCase() === challenge.token.toLowerCase()
    );
    if (!isAllowed) {
      throw new Error(`Token "${challenge.token}" is not in the allowed tokens list for x402 payments.`);
    }
  }

  if (options?.allowedChainIds && options.allowedChainIds.length > 0) {
    if (!options.allowedChainIds.includes(challenge.chainId)) {
      throw new Error(`Chain ID ${challenge.chainId} is not allowed for x402 payments.`);
    }
  }

  const provider = options?.provider || getBSCProvider();
  const signer = session.getSigner().connect(provider);
  const agentAddress = session.getAddress();

  const isNative = isNativeBNB(challenge.token);

  if (isNative) {
    const balanceWei = await provider.getBalance(agentAddress);
    const requiredWei = parseEther(challenge.amount);

    if (balanceWei < requiredWei) {
      throw new Error(
        `Insufficient agent balance for x402 payment. Required: ${challenge.amount} ${challenge.token}, Available: ${formatEther(balanceWei)} tBNB`
      );
    }

    const tx = await signer.sendTransaction({
      to: challenge.recipient,
      value: requiredWei,
    });

    const receipt = await tx.wait(1);

    return {
      txHash: tx.hash,
      token: challenge.token,
      amount: challenge.amount,
      recipient: challenge.recipient,
      chainId: challenge.chainId,
      timestamp: Date.now(),
      blockNumber: receipt?.blockNumber ?? undefined,
      status: receipt?.status === 0 ? 'failed' : 'success',
    };
  } else {
    // ERC-20 / ERC-8056 token settlement
    const balance = await fetchTokenScaledBalance(challenge.token, agentAddress, provider);
    const rawAmount = fromUIAmount(
      challenge.amount,
      balance.decimals,
      balance.multiplier ? BigInt(balance.multiplier) : undefined
    );

    if (BigInt(balance.rawBalance) < rawAmount) {
      throw new Error(
        `Insufficient agent balance for x402 payment. Required: ${challenge.amount} ${challenge.token}, Available: ${balance.uiBalance}`
      );
    }

    const tokenContract = new Contract(challenge.token, ERC20_TRANSFER_ABI, signer);
    const tx = await tokenContract.transfer(challenge.recipient, rawAmount);
    const receipt = await tx.wait(1);

    return {
      txHash: tx.hash,
      token: challenge.token,
      amount: challenge.amount,
      recipient: challenge.recipient,
      chainId: challenge.chainId,
      timestamp: Date.now(),
      blockNumber: receipt?.blockNumber ?? undefined,
      status: receipt?.status === 0 ? 'failed' : 'success',
    };
  }
}
