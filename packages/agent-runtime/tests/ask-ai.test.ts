import { describe, it, expect } from 'vitest';
import {
  sanitizeBNBResponse,
  filterReadOnlyTools,
  isReadOnlyTool,
  assertReadOnlyTool,
  queryBNBDocumentation,
  type BNBDocEntry,
} from '../src/bnb/ask-ai.js';

describe('Ask AI & BNB Documentation Adapter', () => {
  describe('sanitizeBNBResponse', () => {
    it('formats citations and ensures clean answer formatting', () => {
      const rawAnswer = 'To deploy on BSC Testnet, use chainId 97 and get tBNB from the faucet.';
      const sources = ['https://docs.bnbchain.org/docs/testnet/'];
      const formatted = sanitizeBNBResponse(rawAnswer, sources);

      expect(formatted.answer).toContain(rawAnswer);
      expect(formatted.answer).toContain('### References');
      expect(formatted.answer).toContain('https://docs.bnbchain.org/docs/testnet/');
      expect(formatted.citations).toHaveLength(1);
      expect(formatted.citations[0]).toBe('https://docs.bnbchain.org/docs/testnet/');
    });

    it('deduplicates citations and ignores invalid URLs', () => {
      const rawAnswer = 'BNB Smart Chain supports EVM compatibility.';
      const sources = [
        'https://docs.bnbchain.org/docs/overview',
        'https://docs.bnbchain.org/docs/overview',
        'not-a-valid-url',
        'https://docs.bnbchain.org/docs/evm',
      ];
      const formatted = sanitizeBNBResponse(rawAnswer, sources);

      expect(formatted.citations).toEqual([
        'https://docs.bnbchain.org/docs/overview',
        'https://docs.bnbchain.org/docs/evm',
      ]);
    });

    it('does not duplicate References section if already present in answer', () => {
      const rawAnswer = 'Here is the info.\n\n### References\n- [BNB Docs](https://docs.bnbchain.org)';
      const sources = ['https://docs.bnbchain.org'];
      const formatted = sanitizeBNBResponse(rawAnswer, sources);

      const refCount = (formatted.answer.match(/### References/g) || []).length;
      expect(refCount).toBe(1);
      expect(formatted.citations).toContain('https://docs.bnbchain.org');
    });

    it('sanitizes and redacts sensitive credentials if leaked in output', () => {
      const sensitiveAnswer =
        'Private key: 0x4f3edf983ac636a65a842ce7c78d5aa706d4a1b2a7e9dfca4eab24f12be1541f is test.';
      const formatted = sanitizeBNBResponse(sensitiveAnswer, ['https://docs.bnbchain.org']);

      expect(formatted.answer).not.toContain('0x4f3edf983ac636a65a842ce7c78d5aa706d4a1b2a7e9dfca4eab24f12be1541f');
      expect(formatted.answer).toContain('[REDACTED_PRIVATE_KEY]');
    });

    it('handles empty or undefined sources gracefully', () => {
      const formatted = sanitizeBNBResponse('Simple explanation without explicit sources.');
      expect(formatted.answer).toBe('Simple explanation without explicit sources.');
      expect(formatted.citations).toEqual([]);
    });
  });

  describe('filterReadOnlyTools & Read-Only Safety Gates', () => {
    const mockTools = [
      { name: 'query_bnb_docs', description: 'Search BNB documentation' },
      { name: 'check_agent_balance', description: 'Check wallet balance' },
      { name: 'get_token_balance', description: 'Get ERC20 balance' },
      { name: 'discover_erc8004_agents', description: 'Search registered agents' },
      { name: 'pay_x402_service', description: 'Pay for autonomous service' },
      { name: 'transfer_tokens', description: 'Transfer tBNB or tokens' },
      { name: 'send_transaction', description: 'Send write transaction' },
      { name: 'register_agent_identity', description: 'Register ERC-8004 agent' },
      { name: 'sign_message', description: 'Sign an arbitrary message' },
    ];

    it('filters out write-operations and preserves only read-only tools', () => {
      const readOnlyTools = filterReadOnlyTools(mockTools);
      const toolNames = readOnlyTools.map((t) => t.name);

      expect(toolNames).toContain('query_bnb_docs');
      expect(toolNames).toContain('check_agent_balance');
      expect(toolNames).toContain('get_token_balance');
      expect(toolNames).toContain('discover_erc8004_agents');

      expect(toolNames).not.toContain('pay_x402_service');
      expect(toolNames).not.toContain('transfer_tokens');
      expect(toolNames).not.toContain('send_transaction');
      expect(toolNames).not.toContain('register_agent_identity');
      expect(toolNames).not.toContain('sign_message');
    });

    it('works with OpenAI function tool definition format', () => {
      const openAiTools = [
        {
          type: 'function' as const,
          function: {
            name: 'query_bnb_docs',
            description: 'Query docs',
            parameters: {},
          },
        },
        {
          type: 'function' as const,
          function: {
            name: 'pay_x402_service',
            description: 'Pay service',
            parameters: {},
          },
        },
      ];

      const filtered = filterReadOnlyTools(openAiTools);
      expect(filtered).toHaveLength(1);
      expect(filtered[0].function.name).toBe('query_bnb_docs');
    });

    it('respects explicit readonly flags when present', () => {
      const toolsWithFlag = [
        { name: 'custom_indexer', readonly: true },
        { name: 'custom_writer', readonly: false },
        { name: 'read_contract', readonly: true },
      ];

      const filtered = filterReadOnlyTools(toolsWithFlag);
      expect(filtered.map((t) => t.name)).toEqual(['custom_indexer', 'read_contract']);
    });

    it('correctly validates tool names with isReadOnlyTool', () => {
      expect(isReadOnlyTool('query_bnb_docs')).toBe(true);
      expect(isReadOnlyTool('get_balance')).toBe(true);
      expect(isReadOnlyTool('check_status')).toBe(true);
      expect(isReadOnlyTool('discover_agents')).toBe(true);
      expect(isReadOnlyTool('estimate_gas')).toBe(true);

      expect(isReadOnlyTool('pay_x402_service')).toBe(false);
      expect(isReadOnlyTool('transfer_funds')).toBe(false);
      expect(isReadOnlyTool('send_raw_transaction')).toBe(false);
      expect(isReadOnlyTool('execute_order')).toBe(false);
      expect(isReadOnlyTool('delete_keystore')).toBe(false);
    });

    it('throws error in assertReadOnlyTool for modifying tools', () => {
      expect(() => assertReadOnlyTool('query_bnb_docs')).not.toThrow();
      expect(() => assertReadOnlyTool('pay_x402_service')).toThrow(
        /Write operations are strictly disallowed/
      );
      expect(() => assertReadOnlyTool('transfer_tokens')).toThrow(
        /Write operations are strictly disallowed/
      );
    });
  });

  describe('queryBNBDocumentation', () => {
    it('returns accurate testnet documentation and citations for BSC Testnet query', async () => {
      const result = await queryBNBDocumentation('How do I connect to BSC Testnet and what is the chainId?');

      expect(result.answer).toContain('97');
      expect(result.answer).toContain('tBNB');
      expect(result.citations.length).toBeGreaterThan(0);
      expect(result.citations.some((c) => c.includes('docs.bnbchain.org'))).toBe(true);
    });

    it('returns accurate information for opBNB query', async () => {
      const result = await queryBNBDocumentation('What is opBNB and what are its chain IDs?');

      expect(result.answer.toLowerCase()).toContain('opbnb');
      expect(result.answer).toContain('204');
      expect(result.answer).toContain('5611');
      expect(result.citations.some((c) => c.includes('docs.bnbchain.org'))).toBe(true);
    });

    it('returns information for ERC-8004 Agent Identity Registry', async () => {
      const result = await queryBNBDocumentation('What is ERC-8004 agent identity standard on BNB Chain?');

      expect(result.answer).toContain('ERC-8004');
      expect(result.citations.length).toBeGreaterThan(0);
      expect(result.citations.some((c) => c.includes('8004') || c.includes('bnbchain'))).toBe(true);
    });

    it('returns information for ERC-8056 Scaled UI Amount conversion', async () => {
      const result = await queryBNBDocumentation('How does ERC-8056 Scaled UI Amount work?');

      expect(result.answer).toContain('ERC-8056');
      expect(result.citations.length).toBeGreaterThan(0);
    });

    it('returns information for x402 autonomous payment protocol', async () => {
      const result = await queryBNBDocumentation('Explain x402 HTTP challenge payment flow on BSC');

      expect(result.answer).toContain('402');
      expect(result.citations.length).toBeGreaterThan(0);
    });

    it('supports custom documentation entries via options', async () => {
      const customEntries: BNBDocEntry[] = [
        {
          id: 'custom-bridge',
          title: 'Custom Notch Bridge',
          keywords: ['notch', 'bridge', 'custom'],
          content: 'The Notch Bridge connects macOS native UI with BSC Testnet seamlessly.',
          citation: 'https://docs.notch.agent/bridge',
        },
      ];

      const result = await queryBNBDocumentation('Tell me about the custom notch bridge', {
        customKnowledge: customEntries,
      });

      expect(result.answer).toContain('Notch Bridge');
      expect(result.citations).toContain('https://docs.notch.agent/bridge');
    });

    it('returns helpful fallback and core documentation links for unknown queries', async () => {
      const result = await queryBNBDocumentation('xyzabc unindexed topic 12345');

      expect(result.answer.length).toBeGreaterThan(0);
      expect(result.citations).toContain('https://docs.bnbchain.org');
    });
  });
});
