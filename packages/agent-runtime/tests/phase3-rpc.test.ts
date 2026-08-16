import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  createAgentDispatcher,
  AgentSession,
  BnbAgentSdk,
  BSC_TESTNET_CHAIN_ID,
  BSC_MAINNET_CHAIN_ID,
  OPBNB_TESTNET_CHAIN_ID,
  OPBNB_MAINNET_CHAIN_ID,
} from '../src/index.js';
import {
  JSONRPC_ERROR_CODES,
  isJSONRPCResponse,
  isGreenfieldUploadResult,
  isGreenfieldObjectResult,
  isGreenfieldObjectMetadata,
  isGreenfieldBackupResult,
  isNetworkConfig,
  isNetworkSwitchResult,
  type GreenfieldUploadParams,
  type GreenfieldBackupParams,
  type NetworkConfig,
  type NetworkSwitchResult,
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

describe('Phase 3 JSON-RPC Dispatcher Method Bindings', () => {
  let session: AgentSession;
  let sdk: BnbAgentSdk;
  let dispatcher: ReturnType<typeof createAgentDispatcher>;

  beforeEach(() => {
    session = new AgentSession();
    sdk = new BnbAgentSdk(session, { chainId: 97 });
    dispatcher = createAgentDispatcher({
      session,
      sdk,
    });
  });

  describe('Greenfield Decentralized Storage RPC Endpoints', () => {
    describe('greenfield.uploadObject', () => {
      it('uploads string content with explicit bucket and objectName', async () => {
        const params: GreenfieldUploadParams = {
          bucket: 'agent-data',
          objectName: 'configs/agent-settings.json',
          content: JSON.stringify({ model: 'gpt-4o', temperature: 0.7 }),
          contentType: 'application/json',
          isPrivate: false,
        };

        const res = await sendRpc(dispatcher, 'greenfield.uploadObject', params);

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(isGreenfieldUploadResult(res.result)).toBe(true);
        expect(res.result.bucket).toBe('agent-data');
        expect(res.result.objectName).toBe('configs/agent-settings.json');
        expect(res.result.url).toContain('https://gnfd-testnet-sp1.bnbchain.org');
        expect(res.result.url).toContain('agent-data/configs/agent-settings.json');
        expect(res.result.objectId).toBeDefined();
        expect(res.result.contentHash).toBeDefined();
        expect(res.result.size).toBeGreaterThan(0);
        expect(res.result.isPrivate).toBe(false);
      });

      it('uploads object with default bucket when bucket is omitted', async () => {
        const params = {
          objectName: 'notes/meeting.txt',
          content: 'BNB Greenfield integration meeting notes',
        };

        const res = await sendRpc(dispatcher, 'greenfield.uploadObject', params);

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(res.result.bucket).toBe('notch-agent-backups');
        expect(res.result.objectName).toBe('notes/meeting.txt');
      });

      it('accepts positional array parameters for upload', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.uploadObject', [
          'my-bucket',
          'docs/whitepaper.pdf',
          'mock-pdf-binary-data',
          'application/pdf',
          true,
        ]);

        expect(res.error).toBeUndefined();
        expect(res.result.bucket).toBe('my-bucket');
        expect(res.result.objectName).toBe('docs/whitepaper.pdf');
        expect(res.result.isPrivate).toBe(true);
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602) when objectName is missing', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'agent-data',
          content: 'some data',
        });

        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602) when content is missing', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'agent-data',
          objectName: 'test.txt',
        });

        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });
    });

    describe('greenfield.getObject', () => {
      it('retrieves previously uploaded object content and metadata', async () => {
        const content = 'Persisted memory snippet for agent session';
        await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'session-store',
          objectName: 'memories/mem1.txt',
          content,
          contentType: 'text/plain',
        });

        const res = await sendRpc(dispatcher, 'greenfield.getObject', {
          bucket: 'session-store',
          objectName: 'memories/mem1.txt',
        });

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(isGreenfieldObjectResult(res.result)).toBe(true);
        expect(res.result.bucket).toBe('session-store');
        expect(res.result.objectName).toBe('memories/mem1.txt');
        expect(res.result.content).toBe(content);
        expect(res.result.contentType).toBe('text/plain');
        expect(res.result.size).toBe(Buffer.byteLength(content, 'utf-8'));
      });

      it('accepts positional array arguments [bucket, objectName]', async () => {
        await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'public-files',
          objectName: 'readme.md',
          content: '# Notch Agent Shared Memory',
        });

        const res = await sendRpc(dispatcher, 'greenfield.getObject', [
          'public-files',
          'readme.md',
        ]);

        expect(res.error).toBeUndefined();
        expect(res.result.content).toBe('# Notch Agent Shared Memory');
      });

      it('retrieves object from default bucket when bucket is omitted in object parameter', async () => {
        await sendRpc(dispatcher, 'greenfield.uploadObject', {
          objectName: 'default-file.txt',
          content: 'Default bucket file content',
        });

        const res = await sendRpc(dispatcher, 'greenfield.getObject', {
          objectName: 'default-file.txt',
        });

        expect(res.error).toBeUndefined();
        expect(res.result.content).toBe('Default bucket file content');
      });

      it('returns error when requested object does not exist', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.getObject', {
          bucket: 'nonexistent-bucket',
          objectName: 'missing.json',
        });

        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INTERNAL_ERROR);
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602) when objectName is missing', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.getObject', {
          bucket: 'some-bucket',
        });

        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });
    });

    describe('greenfield.listObjects', () => {
      beforeEach(async () => {
        await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'test-list-bucket',
          objectName: 'agents/agent-1.json',
          content: '{"id":1}',
        });
        await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'test-list-bucket',
          objectName: 'agents/agent-2.json',
          content: '{"id":2}',
        });
        await sendRpc(dispatcher, 'greenfield.uploadObject', {
          bucket: 'test-list-bucket',
          objectName: 'logs/2026-08-16.log',
          content: 'Agent initialized',
        });
      });

      it('lists all objects in specified bucket', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.listObjects', {
          bucket: 'test-list-bucket',
        });

        expect(res.error).toBeUndefined();
        expect(Array.isArray(res.result)).toBe(true);
        expect(res.result).toHaveLength(3);
        expect(res.result.every((o: any) => isGreenfieldObjectMetadata(o))).toBe(true);
      });

      it('filters objects by prefix', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.listObjects', {
          bucket: 'test-list-bucket',
          prefix: 'agents/',
        });

        expect(res.error).toBeUndefined();
        expect(res.result).toHaveLength(2);
        expect(res.result.map((o: any) => o.objectName)).toEqual([
          'agents/agent-1.json',
          'agents/agent-2.json',
        ]);
      });

      it('accepts positional array arguments [bucket, prefix]', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.listObjects', [
          'test-list-bucket',
          'logs/',
        ]);

        expect(res.error).toBeUndefined();
        expect(res.result).toHaveLength(1);
        expect(res.result[0].objectName).toBe('logs/2026-08-16.log');
      });

      it('uses default bucket if bucket is omitted in params', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.listObjects');
        expect(res.error).toBeUndefined();
        expect(Array.isArray(res.result)).toBe(true);
      });
    });

    describe('greenfield.backupChatHistory', () => {
      it('backs up encrypted chat history with sessionId and encryptedData', async () => {
        const backupParams: GreenfieldBackupParams = {
          sessionId: 'session-chat-999',
          encryptedData: 'aes-gcm-encrypted-hex-payload-content',
        };

        const res = await sendRpc(dispatcher, 'greenfield.backupChatHistory', backupParams);

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(isGreenfieldBackupResult(res.result)).toBe(true);
        expect(res.result.sessionId).toBe('session-chat-999');
        expect(res.result.url).toContain('backups/session-chat-999.json');
        expect(res.result.objectId).toBeDefined();
        expect(res.result.timestamp).toBeGreaterThan(0);
      });

      it('backs up chat history with client-side encryption when rawHistory is provided', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.backupChatHistory', {
          sessionId: 'session-client-enc-101',
          rawHistory: [
            { role: 'user', content: 'Swap 1 BNB to CAKE' },
            { role: 'assistant', content: 'Swap completed' },
          ],
          encryptionKey: 'my-super-secret-key',
        });

        expect(res.error).toBeUndefined();
        expect(res.result.sessionId).toBe('session-client-enc-101');
      });

      it('accepts positional array parameters [sessionId, encryptedData, bucket]', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.backupChatHistory', [
          'session-arr-123',
          'encrypted-string-content',
          'custom-backup-bucket',
        ]);

        expect(res.error).toBeUndefined();
        expect(res.result.sessionId).toBe('session-arr-123');
        expect(res.result.url).toContain('custom-backup-bucket/backups/session-arr-123.json');
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602) when sessionId is missing', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.backupChatHistory', {
          encryptedData: 'some data',
        });

        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602) when both encryptedData and rawHistory are missing', async () => {
        const res = await sendRpc(dispatcher, 'greenfield.backupChatHistory', {
          sessionId: 'session-invalid-empty',
        });

        expect(res.error).toBeDefined();
        expect(res.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });
    });
  });

  describe('Multi-Chain Network Switcher RPC Endpoints', () => {
    describe('network.getNetworks', () => {
      it('returns all 4 supported network configurations', async () => {
        const res = await sendRpc(dispatcher, 'network.getNetworks');

        expect(res.error).toBeUndefined();
        expect(Array.isArray(res.result)).toBe(true);
        expect(res.result).toHaveLength(4);

        for (const net of res.result) {
          expect(isNetworkConfig(net)).toBe(true);
        }

        const chainIds = res.result.map((n: NetworkConfig) => n.chainId);
        expect(chainIds).toContain(BSC_TESTNET_CHAIN_ID);
        expect(chainIds).toContain(BSC_MAINNET_CHAIN_ID);
        expect(chainIds).toContain(OPBNB_TESTNET_CHAIN_ID);
        expect(chainIds).toContain(OPBNB_MAINNET_CHAIN_ID);
      });
    });

    describe('network.getCurrentNetwork', () => {
      it('returns active network configuration (BSC Testnet 97 by default)', async () => {
        const res = await sendRpc(dispatcher, 'network.getCurrentNetwork');

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(isNetworkConfig(res.result)).toBe(true);
        expect(res.result.chainId).toBe(97);
        expect(res.result.name).toBe('BSC Testnet');
        expect(res.result.isTestnet).toBe(true);
      });
    });

    describe('network.switchNetwork', () => {
      it('switches to BSC Mainnet (56) using object parameter { chainId: 56 }', async () => {
        const res = await sendRpc(dispatcher, 'network.switchNetwork', { chainId: 56 });

        expect(res.error).toBeUndefined();
        expect(res.result).toBeDefined();
        expect(isNetworkSwitchResult(res.result)).toBe(true);
        expect(res.result.success).toBe(true);
        expect(res.result.activeNetwork.chainId).toBe(56);
        expect(res.result.activeNetwork.name).toBe('BSC Mainnet');
        expect(res.result.previousChainId).toBe(97);

        // Verify getCurrentNetwork reflects the switch
        const currentRes = await sendRpc(dispatcher, 'network.getCurrentNetwork');
        expect(currentRes.result.chainId).toBe(56);
        expect(currentRes.result.name).toBe('BSC Mainnet');
      });

      it('switches to opBNB Testnet (5611) using array parameter [5611]', async () => {
        const res = await sendRpc(dispatcher, 'network.switchNetwork', [5611]);

        expect(res.error).toBeUndefined();
        expect(res.result.success).toBe(true);
        expect(res.result.activeNetwork.chainId).toBe(5611);
        expect(res.result.activeNetwork.name).toBe('opBNB Testnet');
        expect(res.result.previousChainId).toBe(97);

        const currentRes = await sendRpc(dispatcher, 'network.getCurrentNetwork');
        expect(currentRes.result.chainId).toBe(5611);
      });

      it('switches to opBNB Mainnet (204) using array parameter [204]', async () => {
        const res = await sendRpc(dispatcher, 'network.switchNetwork', [204]);

        expect(res.error).toBeUndefined();
        expect(res.result.success).toBe(true);
        expect(res.result.activeNetwork.chainId).toBe(204);
        expect(res.result.activeNetwork.name).toBe('opBNB Mainnet');

        const currentRes = await sendRpc(dispatcher, 'network.getCurrentNetwork');
        expect(currentRes.result.chainId).toBe(204);
      });

      it('handles switching back to BSC Testnet (97)', async () => {
        // First switch to BSC Mainnet
        await sendRpc(dispatcher, 'network.switchNetwork', { chainId: 56 });

        // Switch back to BSC Testnet
        const res = await sendRpc(dispatcher, 'network.switchNetwork', { chainId: 97 });
        expect(res.error).toBeUndefined();
        expect(res.result.success).toBe(true);
        expect(res.result.activeNetwork.chainId).toBe(97);
        expect(res.result.previousChainId).toBe(56);

        const currentRes = await sendRpc(dispatcher, 'network.getCurrentNetwork');
        expect(currentRes.result.chainId).toBe(97);
      });

      it('returns success: false for unsupported chainId without altering active network', async () => {
        const initialRes = await sendRpc(dispatcher, 'network.getCurrentNetwork');
        // If method is not yet registered, initialRes.result might be undefined, handle safely
        const initialChainId = initialRes.result?.chainId ?? 97;

        const res = await sendRpc(dispatcher, 'network.switchNetwork', { chainId: 999999 });

        expect(res.error).toBeUndefined();
        expect(res.result.success).toBe(false);
        expect(res.result.activeNetwork.chainId).toBe(initialChainId);

        const currentRes = await sendRpc(dispatcher, 'network.getCurrentNetwork');
        expect(currentRes.result.chainId).toBe(initialChainId);
      });

      it('rejects invalid parameters with INVALID_PARAMS (-32602) when chainId is non-numeric or missing', async () => {
        const res1 = await sendRpc(dispatcher, 'network.switchNetwork', {
          invalidKey: 'test',
        });
        expect(res1.error).toBeDefined();
        expect(res1.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);

        const res2 = await sendRpc(dispatcher, 'network.switchNetwork', {
          chainId: 'not-a-number',
        });
        expect(res2.error).toBeDefined();
        expect(res2.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);

        const res3 = await sendRpc(dispatcher, 'network.switchNetwork', []);
        expect(res3.error).toBeDefined();
        expect(res3.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_PARAMS);
      });
    });
  });
});
