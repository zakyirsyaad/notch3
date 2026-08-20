import { afterEach, describe, expect, it, vi } from 'vitest';
import { AgentExecutor } from '../src/agent/loop.js';
import { createDefaultTools } from '../src/agent/tools.js';
import { validateProviderConfig } from '../src/agent/provider-config.js';
import {
  AgentSession,
  BnbAgentSdk,
  createAgentDispatcher,
} from '../src/index.js';

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

async function sendRpc(
  dispatcher: ReturnType<typeof createAgentDispatcher>,
  method: string,
  params?: unknown
): Promise<Record<string, any>> {
  const raw = await dispatcher.handleMessage(
    JSON.stringify({
      jsonrpc: '2.0',
      id: 'adjustment-test',
      method,
      ...(params === undefined ? {} : { params }),
    })
  );

  expect(raw).not.toBeNull();
  return JSON.parse(raw!);
}

function createRuntime(executor: AgentExecutor) {
  const session = new AgentSession();
  const sdk = new BnbAgentSdk(session, { provider: {} as any });
  const dispatcher = createAgentDispatcher({ session, sdk, executor });
  return { dispatcher, sdk };
}

describe('Notch3 TypeScript runtime adjustments', () => {
  let temporaryDirectory: string | undefined;

  afterEach(() => {
    vi.unstubAllEnvs();
    if (temporaryDirectory) {
      rmSync(temporaryDirectory, { recursive: true, force: true });
      temporaryDirectory = undefined;
    }
  });

  describe('provider configuration validation', () => {
    it.each([
      'https://api.openai.com/v1',
      'https://provider.example/v1',
      'http://localhost:11434/v1',
      'http://127.0.0.1:11434/v1',
      'http://[::1]:11434/v1',
    ])('accepts %s', (openaiBaseUrl) => {
      expect(() =>
        validateProviderConfig({ openaiBaseUrl, openaiModel: 'local-model' })
      ).not.toThrow();
    });

    it.each([
      ['', 'local-model'],
      ['https://provider.example/v1', ''],
      ['https://provider.example/v1', '   '],
      ['not-a-url', 'local-model'],
      ['http://provider.example/v1', 'local-model'],
      ['ftp://provider.example/v1', 'local-model'],
      ['https://user:password@provider.example/v1', 'local-model'],
      ['https://provider.example/v1?api_key=secret', 'local-model'],
      ['https://provider.example/v1#api_key=secret', 'local-model'],
    ])('rejects invalid provider config %j', (openaiBaseUrl, openaiModel) => {
      expect(() =>
        validateProviderConfig({ openaiBaseUrl, openaiModel })
      ).toThrow();
    });
  });

  describe('keyless OpenAI-compatible providers', () => {
    it('omits Authorization when the API key is blank', async () => {
      const fetchMock = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          choices: [{ message: { content: 'local response' } }],
        }),
      });
      const executor = new AgentExecutor({
        openaiApiKey: '',
        openaiBaseUrl: 'http://127.0.0.1:11434/v1',
        openaiModel: 'local-model',
        fetch: fetchMock as unknown as typeof fetch,
      });

      await executor.executePrompt('hello local provider');

      const headers = fetchMock.mock.calls[0][1].headers as Record<string, string>;
      expect(headers.Authorization).toBeUndefined();
      expect(headers['Content-Type']).toBe('application/json');
    });

    it('does not inherit OPENAI_API_KEY when agent.init configures a keyless provider', async () => {
      vi.stubEnv('OPENAI_API_KEY', 'inherited-process-secret');
      const fetchMock = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ choices: [{ message: { content: 'response' } }] }),
      });
      const executor = new AgentExecutor({
        openaiBaseUrl: 'https://provider.example/v1',
        openaiModel: 'remote-model',
        fetch: fetchMock as unknown as typeof fetch,
      });
      const { dispatcher } = createRuntime(executor);

      const response = await sendRpc(dispatcher, 'agent.init', {
        openaiBaseUrl: 'http://127.0.0.1:11434/v1',
        openaiModel: 'local-model',
      });
      expect(response.error).toBeUndefined();

      await executor.executePrompt('hello local provider');
      const headers = fetchMock.mock.calls[0][1].headers as Record<string, string>;
      expect(headers.Authorization).toBeUndefined();
    });

    it('retains Authorization for a non-empty API key', async () => {
      const fetchMock = vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          choices: [{ message: { content: 'remote response' } }],
        }),
      });
      const executor = new AgentExecutor({
        openaiApiKey: 'secret-key',
        openaiBaseUrl: 'https://provider.example/v1',
        openaiModel: 'remote-model',
        fetch: fetchMock as unknown as typeof fetch,
      });

      await executor.executePrompt('hello remote provider');

      const headers = fetchMock.mock.calls[0][1].headers as Record<string, string>;
      expect(headers.Authorization).toBe('Bearer secret-key');
    });
  });

  describe('agent.init and legacy runtime state', () => {
    it('applies exact OpenAI fields, clears a key, and redacts it from readback', async () => {
      const executor = new AgentExecutor({
        openaiApiKey: 'existing-secret',
        openaiBaseUrl: 'https://old-provider.example/v1',
        openaiModel: 'old-model',
      });
      const { dispatcher } = createRuntime(executor);

      const response = await sendRpc(dispatcher, 'agent.init', {
        openaiApiKey: '',
        openaiBaseUrl: 'http://127.0.0.1:11434/v1',
        openaiModel: 'local-model',
      });

      expect(response.error).toBeUndefined();
      expect(executor.apiKey).toBe('');
      expect(executor.baseUrl).toBe('http://127.0.0.1:11434/v1');
      expect(executor.model).toBe('local-model');
      expect(response.result.config).not.toHaveProperty('openaiApiKey');
      expect(JSON.stringify(response.result.config)).not.toContain('existing-secret');
    });

    it('rejects invalid provider settings at agent.init', async () => {
      const executor = new AgentExecutor({
        openaiBaseUrl: 'https://provider.example/v1',
        openaiModel: 'model',
      });
      const { dispatcher } = createRuntime(executor);

      const response = await sendRpc(dispatcher, 'agent.init', {
        openaiBaseUrl: 'http://provider.example/v1',
        openaiModel: 'model',
      });

      expect(response.error.code).toBe(-32602);
      expect(executor.baseUrl).toBe('https://provider.example/v1');
    });

    it('does not load, expose, or rewrite a legacy auto-pay file value', async () => {
      temporaryDirectory = mkdtempSync(path.join(tmpdir(), 'notch3-adjustments-'));
      const configPath = path.join(temporaryDirectory, 'runtime.json');
      const legacyFile = JSON.stringify(
        { autoPayMaxTBNB: '999', openaiApiKey: 'persisted-secret' },
        null,
        2
      );
      writeFileSync(configPath, legacyFile, 'utf8');
      vi.stubEnv('NOTCH_CONFIG_PATH', configPath);

      const executor = new AgentExecutor({
        openaiBaseUrl: 'https://provider.example/v1',
        openaiModel: 'model',
      });
      const { dispatcher, sdk } = createRuntime(executor);

      const initResponse = await sendRpc(dispatcher, 'agent.init', {
        openaiApiKey: 'runtime-secret',
        openaiBaseUrl: 'https://provider.example/v1',
        openaiModel: 'model',
      });
      const statusResponse = await sendRpc(dispatcher, 'agent.getStatus');

      expect(initResponse.result.config).not.toHaveProperty('autoPayMaxTBNB');
      expect(initResponse.result.config).not.toHaveProperty('openaiApiKey');
      expect(statusResponse.result).not.toHaveProperty('autoPayMaxTBNB');
      expect('autoPayMaxTBNB' in sdk).toBe(false);
      expect(readFileSync(configPath, 'utf8')).toBe(legacyFile);
    });

    it('does not register legacy auto-pay limit RPC methods', async () => {
      const executor = new AgentExecutor({
        openaiBaseUrl: 'https://provider.example/v1',
        openaiModel: 'model',
      });
      const { dispatcher } = createRuntime(executor);

      expect(dispatcher.hasMethod('wallet.getAutoPayLimit')).toBe(false);
      expect(dispatcher.hasMethod('wallet.setAutoPayLimit')).toBe(false);

      const response = await sendRpc(dispatcher, 'wallet.getAutoPayLimit');
      expect(response.error.code).toBe(-32601);
    });
  });

  describe('chat payment tool', () => {
    it('passes no nominal max amount to the SDK', async () => {
      const paymentReceipt = {
        txHash: '0xpayment',
        token: 'tBNB',
        amount: '5',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
        timestamp: Date.now(),
        status: 'success' as const,
      };
      const payX402 = vi.fn().mockResolvedValue(paymentReceipt);
      const sdk = { chainId: 97, payX402 } as any;
      const paymentTool = createDefaultTools({ sdk }).find(
        (tool) => tool.definition.function.name === 'pay_x402_service'
      )!;
      const challenge = {
        token: 'tBNB',
        amount: '5',
        recipient: '0x1111111111111111111111111111111111111111',
        chainId: 97,
      };

      await expect(paymentTool.handler({ challenge })).resolves.toEqual(paymentReceipt);
      expect(payX402).toHaveBeenCalledWith(challenge);
      expect(payX402.mock.calls[0]).toHaveLength(1);
    });
  });
});
