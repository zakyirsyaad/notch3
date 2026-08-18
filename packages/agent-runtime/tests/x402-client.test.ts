import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ZeroAddress, Wallet, parseEther } from 'ethers';
import {
  parseX402Challenge,
  executeX402Payment,
  createX402PaymentHeaders,
} from '../src/bnb/x402-client.js';
import {
  registerAgentIdentity,
  discoverAgents,
  getAgentIdentity,
  clearAgentRegistryCache,
} from '../src/bnb/erc8004.js';
import { BnbAgentSdk } from '../src/bnb/bnb-sdk.js';
import { AgentSession } from '../src/wallet/session.js';
import * as erc8056Module from '../src/bnb/erc8056.js';
import type { X402PaymentChallenge } from '@notch/shared-types';

const TEST_RECIPIENT = '0x1111111111111111111111111111111111111111';
const TEST_TOKEN_ADDRESS = '0x3333333333333333333333333333333333333333';

describe('x402 Payment Client', () => {
  describe('parseX402Challenge', () => {
    it('parses standard 402 Payment Required response challenge', () => {
      const headers = {
        'www-authenticate':
          'x402 token="tBNB", amount="0.001", recipient="0x1111111111111111111111111111111111111111", chainId="97"',
      };
      const challenge = parseX402Challenge(headers);
      expect(challenge.amount).toBe('0.001');
      expect(challenge.token).toBe('tBNB');
      expect(challenge.chainId).toBe(97);
      expect(challenge.recipient).toBe(TEST_RECIPIENT);
    });

    it('parses challenge with optional resource, description, and nonce attributes', () => {
      const headers = {
        'WWW-Authenticate':
          'x402 token="tBNB", amount="0.05", recipient="0x1111111111111111111111111111111111111111", chainId="97", resource="/api/v1/search", description="Search Query Access", nonce="req-abc-987"',
      };
      const challenge = parseX402Challenge(headers);
      expect(challenge.amount).toBe('0.05');
      expect(challenge.token).toBe('tBNB');
      expect(challenge.chainId).toBe(97);
      expect(challenge.recipient).toBe(TEST_RECIPIENT);
      expect(challenge.resource).toBe('/api/v1/search');
      expect(challenge.description).toBe('Search Query Access');
      expect(challenge.nonce).toBe('req-abc-987');
    });

    it('parses challenge from JSON body when headers do not have WWW-Authenticate', () => {
      const headers = { 'content-type': 'application/json' };
      const body = {
        x402: {
          token: 'tBNB',
          amount: '0.0025',
          recipient: TEST_RECIPIENT,
          chainId: 97,
          resource: '/premium-content',
        },
      };
      const challenge = parseX402Challenge(headers, body);
      expect(challenge.amount).toBe('0.0025');
      expect(challenge.token).toBe('tBNB');
      expect(challenge.recipient).toBe(TEST_RECIPIENT);
      expect(challenge.chainId).toBe(97);
      expect(challenge.resource).toBe('/premium-content');
    });

    it('parses challenge from flat JSON body', () => {
      const headers = {};
      const body = {
        token: TEST_TOKEN_ADDRESS,
        amount: '10.5',
        recipient: TEST_RECIPIENT,
        chainId: 97,
        description: 'Dataset download fee',
      };
      const challenge = parseX402Challenge(headers, body);
      expect(challenge.token).toBe(TEST_TOKEN_ADDRESS);
      expect(challenge.amount).toBe('10.5');
      expect(challenge.recipient).toBe(TEST_RECIPIENT);
      expect(challenge.chainId).toBe(97);
      expect(challenge.description).toBe('Dataset download fee');
    });

    it('applies default token (tBNB) and chainId (97) when not explicitly set', () => {
      const headers = {
        'www-authenticate': `x402 amount="0.001", recipient="${TEST_RECIPIENT}"`,
      };
      const challenge = parseX402Challenge(headers);
      expect(challenge.token).toBe('tBNB');
      expect(challenge.chainId).toBe(97);
      expect(challenge.amount).toBe('0.001');
      expect(challenge.recipient).toBe(TEST_RECIPIENT);
    });

    it('throws error when challenge is missing recipient', () => {
      const headers = {
        'www-authenticate': 'x402 amount="0.001", chainId="97"',
      };
      expect(() => parseX402Challenge(headers)).toThrow(/recipient/i);
    });

    it('throws error when challenge is missing amount or amount is non-positive', () => {
      const headers1 = {
        'www-authenticate': `x402 recipient="${TEST_RECIPIENT}"`,
      };
      expect(() => parseX402Challenge(headers1)).toThrow(/amount/i);

      const headers2 = {
        'www-authenticate': `x402 amount="0", recipient="${TEST_RECIPIENT}"`,
      };
      expect(() => parseX402Challenge(headers2)).toThrow(/amount/i);

      const headers3 = {
        'www-authenticate': `x402 amount="-0.5", recipient="${TEST_RECIPIENT}"`,
      };
      expect(() => parseX402Challenge(headers3)).toThrow(/amount/i);
    });

    it('throws error when recipient address is invalid', () => {
      const headers = {
        'www-authenticate': 'x402 amount="0.001", recipient="not-an-address"',
      };
      expect(() => parseX402Challenge(headers)).toThrow(/invalid.*recipient/i);
    });
  });

  describe('createX402PaymentHeaders', () => {
    it('creates standard x402 payment proof headers with txHash', () => {
      const receipt = {
        txHash: '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        token: 'tBNB',
        amount: '0.001',
        recipient: TEST_RECIPIENT,
        chainId: 97,
        timestamp: 1718000000,
        status: 'success' as const,
      };
      const headers = createX402PaymentHeaders(receipt);
      expect(headers['Authorization']).toBe(`x402 ${receipt.txHash}`);
      expect(headers['X-402-TxHash']).toBe(receipt.txHash);
    });
  });

  describe('executeX402Payment', () => {
    let session: AgentSession;
    let mockSignerWallet: Wallet;

    beforeEach(async () => {
      session = new AgentSession();
      mockSignerWallet = Wallet.createRandom();
    });

    it('throws error if agent session is locked', async () => {
      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.001',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      await expect(executeX402Payment(challenge, session)).rejects.toThrow(
        /locked/i
      );
    });

    it('throws error if safety maxAmount limit is exceeded', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge1: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '1.0',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      await expect(
        executeX402Payment(challenge1, session, {
          maxAmount: '0.1',
        })
      ).rejects.toThrow(/exceeds maximum allowed limit/i);

      // Pengecekan adversarial desimal eksak (lebihi batas sebesar 1 Wei)
      const challenge2: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.100000000000000001',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      await expect(
        executeX402Payment(challenge2, session, {
          maxAmount: '0.1',
        })
      ).rejects.toThrow(/exceeds maximum allowed limit/i);
    });

    it('throws error when token is not in allowedTokens list', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: TEST_TOKEN_ADDRESS,
        amount: '1.0',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      await expect(
        executeX402Payment(challenge, session, {
          allowedTokens: ['tBNB'],
        })
      ).rejects.toThrow(/not in the allowed tokens list/i);
    });

    it('throws error when chainId is not in allowedChainIds list', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 1, // Mainnet requested when allowed is only 97
      };

      await expect(
        executeX402Payment(challenge, session, {
          allowedChainIds: [97],
        })
      ).rejects.toThrow(/chain id 1 is not allowed/i);
    });

    it('throws error when wallet has insufficient balance for native tBNB payment', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const mockProvider = {
        getBalance: vi.fn().mockResolvedValue(0n),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
      } as any;

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.05',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      await expect(
        executeX402Payment(challenge, session, { provider: mockProvider })
      ).rejects.toThrow(/insufficient agent balance/i);
    });

    it('successfully executes native tBNB payment when unlocked and funded', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const mockTx = {
        hash: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        wait: vi.fn().mockResolvedValue({
          status: 1,
          blockNumber: 123456,
          hash: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        }),
      };

      const mockProvider = {
        getBalance: vi.fn().mockResolvedValue(parseEther('1.0')),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
      } as any;

      const signer = session.getSigner();
      vi.spyOn(signer, 'connect').mockReturnValue(signer);
      vi.spyOn(signer, 'sendTransaction').mockResolvedValue(mockTx as any);

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      const receipt = await executeX402Payment(challenge, session, {
        provider: mockProvider,
      });

      expect(receipt.status).toBe('success');
      expect(receipt.txHash).toBe(mockTx.hash);
      expect(receipt.amount).toBe('0.01');
      expect(receipt.token).toBe('tBNB');
      expect(receipt.recipient).toBe(TEST_RECIPIENT);
      expect(receipt.chainId).toBe(97);
      expect(receipt.blockNumber).toBe(123456);
      expect(typeof receipt.timestamp).toBe('number');
    });

    it('successfully executes ERC-20 token payment when funded', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const mockTx = {
        hash: '0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd',
        wait: vi.fn().mockResolvedValue({
          status: 1,
          blockNumber: 123457,
          hash: '0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd',
        }),
      };

      // Mock fetchTokenScaledBalance
      vi.spyOn(erc8056Module, 'fetchTokenScaledBalance').mockResolvedValue({
        tokenAddress: TEST_TOKEN_ADDRESS,
        name: 'Mock USD',
        symbol: 'MUSD',
        decimals: 18,
        rawBalance: parseEther('100.0').toString(),
        uiBalance: '100',
        isERC8056: false,
      });

      const mockProvider = {
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
        estimateGas: vi.fn().mockResolvedValue(50000n),
        getTransactionReceipt: vi.fn().mockResolvedValue({
          status: 1,
          blockNumber: 123457,
          hash: mockTx.hash,
          logs: [],
        }),
      } as any;

      const signer = session.getSigner();
      const mockConnectedSigner = {
        getAddress: vi.fn().mockResolvedValue(session.getAddress()),
        sendTransaction: vi.fn().mockResolvedValue(mockTx),
        provider: mockProvider,
      };
      vi.spyOn(signer, 'connect').mockReturnValue(mockConnectedSigner as any);

      const challenge: X402PaymentChallenge = {
        token: TEST_TOKEN_ADDRESS,
        amount: '5.0',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      const receipt = await executeX402Payment(challenge, session, {
        provider: mockProvider,
      });

      expect(receipt.status).toBe('success');
      expect(receipt.txHash).toBe(mockTx.hash);
      expect(receipt.token).toBe(TEST_TOKEN_ADDRESS);
      expect(receipt.amount).toBe('5.0');
      expect(receipt.recipient).toBe(TEST_RECIPIENT);
      expect(receipt.blockNumber).toBe(123457);
    });

    it('throws error if signal is aborted before execution', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      const controller = new AbortController();
      controller.abort();

      await expect(
        executeX402Payment(challenge, session, {
          signal: controller.signal,
        })
      ).rejects.toThrow(/cancelled/i);
    });

    it('throws error if session is locked during network await', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      const mockProvider = {
        getBalance: vi.fn().mockImplementation(async () => {
          // Simulasi delay asinkron, dan lock session saat await berjalan
          session.lock();
          return parseEther('1.0');
        }),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
      } as any;

      await expect(
        executeX402Payment(challenge, session, {
          provider: mockProvider,
        })
      ).rejects.toThrow(/cancelled/i);
    });

    it('proves no broadcast occurs when locked mid-broadcast', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      let estimateGasCalled = false;
      let sendRawTransactionCalled = false;
      
      const mockProvider = {
        getBalance: vi.fn().mockResolvedValue(parseEther('1.0')),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
        send: vi.fn().mockImplementation(async (method: string, params: any[]) => {
          if (method === 'eth_estimateGas') {
            estimateGasCalled = true;
            session.lock(); // Lock di tengah jalan (mid-broadcast)!
          }
          if (method === 'eth_sendRawTransaction') {
            sendRawTransactionCalled = true;
          }
          return '0x123';
        }),
      } as any;

      const signer = session.getSigner();
      let activeProvider: any = null;
      vi.spyOn(signer, 'connect').mockImplementation((prov) => {
        activeProvider = prov;
        return signer;
      });
      vi.spyOn(signer, 'sendTransaction').mockImplementation(async () => {
        // Ethers asinkron memanggil provider.send
        await activeProvider.send('eth_estimateGas', []);
        await activeProvider.send('eth_sendRawTransaction', []);
        return { hash: '0xabc', wait: vi.fn().mockResolvedValue({ status: 1 }) } as any;
      });

      await expect(
        executeX402Payment(challenge, session, {
          provider: mockProvider,
        })
      ).rejects.toThrow(/cancelled/i);

      expect(estimateGasCalled).toBe(true);
      expect(sendRawTransactionCalled).toBe(false); // PROVES NO BROADCAST OCCURS!
      expect(session.isUnlocked()).toBe(false);
    });

    it('does not throw and allows transaction to succeed if locked after broadcast (in-flight)', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      let sendRawTransactionCalled = false;
      let getTransactionReceiptCalled = false;

      const mockProvider = {
        getBalance: vi.fn().mockResolvedValue(parseEther('1.0')),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
        send: vi.fn().mockImplementation(async (method: string, params: any[]) => {
          if (method === 'eth_sendRawTransaction') {
            sendRawTransactionCalled = true;
            session.lock(); // Lock immediately after raw dispatch
          }
          if (method === 'eth_getTransactionReceipt') {
            getTransactionReceiptCalled = true;
          }
          return '0x123';
        }),
      } as any;

      const signer = session.getSigner();
      vi.spyOn(signer, 'connect').mockReturnValue(signer);
      vi.spyOn(signer, 'sendTransaction').mockImplementation(async () => {
        await mockProvider.send('eth_sendRawTransaction', []);
        return {
          hash: '0xabc',
          wait: async (confirmations?: number) => {
            await mockProvider.send('eth_getTransactionReceipt', []);
            return {
              status: 1,
              blockNumber: 123456,
            } as any;
          },
        } as any;
      });

      const receipt = await executeX402Payment(challenge, session, {
        provider: mockProvider,
      });

      expect(receipt.status).toBe('success');
      expect(receipt.txHash).toBe('0xabc');
      expect(sendRawTransactionCalled).toBe(true);
      expect(getTransactionReceiptCalled).toBe(true); // proves receipt polling worked after lock!
      expect(session.isUnlocked()).toBe(false);
    });

    it('proves provider cancellation wrapper does not leak across different payments', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const challenge: X402PaymentChallenge = {
        token: 'tBNB',
        amount: '0.01',
        recipient: TEST_RECIPIENT,
        chainId: 97,
      };

      const mockProvider = {
        getBalance: vi.fn().mockResolvedValue(parseEther('1.0')),
        getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
        send: vi.fn().mockResolvedValue('0x123'),
      } as any;

      const signer = session.getSigner();
      vi.spyOn(signer, 'connect').mockReturnValue(signer);
      vi.spyOn(signer, 'sendTransaction').mockResolvedValue({
        hash: '0xabc',
        wait: vi.fn().mockResolvedValue({ status: 1 }),
      } as any);

      const controller = new AbortController();

      controller.abort();
      await expect(
        executeX402Payment(challenge, session, {
          provider: mockProvider,
          signal: controller.signal,
        })
      ).rejects.toThrow(/cancelled/i);

      const receipt = await executeX402Payment(challenge, session, {
        provider: mockProvider,
      });

      expect(receipt.status).toBe('success');
      expect(receipt.txHash).toBe('0xabc');
    });
  });

  describe('ERC-8004 Agent Identity & Discovery', () => {
    let session: AgentSession;
    let mockSignerWallet: Wallet;

    beforeEach(async () => {
      clearAgentRegistryCache();
      session = new AgentSession();
      mockSignerWallet = Wallet.createRandom();
    });

    it('registers agent identity with required name and description', async () => {
      const metadata = {
        name: 'Notch Data Searcher',
        description: 'Autonomous research agent for Web3 datasets',
      };

      const agentId = await registerAgentIdentity(metadata);
      expect(typeof agentId).toBe('string');
      expect(agentId.length).toBeGreaterThan(0);

      const found = await getAgentIdentity(agentId);
      expect(found).not.toBeNull();
      expect(found?.metadata.name).toBe('Notch Data Searcher');
    });

    it('registers agent identity with session and custom endpoints/tags', async () => {
      const keystore = await mockSignerWallet.encrypt('password123');
      await session.unlock(keystore, 'password123');

      const metadata = {
        name: 'Notch Oracle Agent',
        description: 'Provides real-time price feed queries via x402',
        endpoints: ['https://oracle.notch.example.com/api'],
        tags: ['oracle', 'finance', 'bsc'],
      };

      const agentId = await registerAgentIdentity(metadata, session);
      expect(typeof agentId).toBe('string');

      const agents = await discoverAgents({ query: 'Oracle' });
      expect(agents.length).toBe(1);
      expect(agents[0].metadata.name).toBe('Notch Oracle Agent');
      expect(agents[0].owner.toLowerCase()).toBe(
        session.getAddress().toLowerCase()
      );
      expect(agents[0].metadata.tags).toContain('oracle');
    });

    it('filters discovered agents by tag', async () => {
      await registerAgentIdentity({
        name: 'Agent A',
        description: 'DeFi Swap Assistant',
        tags: ['defi', 'swap'],
      });

      await registerAgentIdentity({
        name: 'Agent B',
        description: 'AI Code Reviewer',
        tags: ['devtools', 'coding'],
      });

      const defiAgents = await discoverAgents({ tags: ['defi'] });
      expect(defiAgents.length).toBe(1);
      expect(defiAgents[0].metadata.name).toBe('Agent A');

      const devAgents = await discoverAgents({ tags: ['coding'] });
      expect(devAgents.length).toBe(1);
      expect(devAgents[0].metadata.name).toBe('Agent B');
    });

    it('rejects registration with missing name or description', async () => {
      await expect(
        registerAgentIdentity({ name: '', description: 'Valid desc' })
      ).rejects.toThrow(/name/i);

      await expect(
        registerAgentIdentity({ name: 'Valid Name', description: '' })
      ).rejects.toThrow(/description/i);
    });
  });

  describe('BnbAgentSdk Wrapper', () => {
    let session: AgentSession;
    let mockSignerWallet: Wallet;

    beforeEach(async () => {
      clearAgentRegistryCache();
      session = new AgentSession();
      mockSignerWallet = Wallet.createRandom();
      const keystore = await mockSignerWallet.encrypt('pass');
      await session.unlock(keystore, 'pass');
    });

    it('provides unified SDK client methods for balance, payment, and identity', async () => {
      const sdk = new BnbAgentSdk(session);
      expect(sdk.session).toBe(session);
      expect(sdk.chainId).toBe(97);

      const challenge = sdk.parseChallenge({
        'www-authenticate': `x402 token="tBNB", amount="0.005", recipient="${TEST_RECIPIENT}", chainId="97"`,
      });
      expect(challenge.amount).toBe('0.005');

      const agentId = await sdk.registerIdentity({
        name: 'SDK Agent',
        description: 'Agent registered via SDK wrapper',
      });
      expect(typeof agentId).toBe('string');

      const singleAgent = await sdk.getAgent(agentId);
      expect(singleAgent?.metadata.name).toBe('SDK Agent');

      const discovered = await sdk.discover({ query: 'SDK' });
      expect(discovered.length).toBe(1);

      const headers = sdk.createPaymentHeaders({
        txHash: '0x9999999999999999999999999999999999999999999999999999999999999999',
      });
      expect(headers['Authorization']).toContain('0x99999');
    });
  });
});
