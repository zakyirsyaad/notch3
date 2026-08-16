import { describe, it, expect, beforeEach } from 'vitest';
import {
  GreenfieldClient,
  GREENFIELD_TESTNET_CHAIN_ID,
  GREENFIELD_TESTNET_SP_URL,
  GREENFIELD_TESTNET_RPC_URL,
  DEFAULT_BACKUP_BUCKET,
  computeSha256,
  encryptDataAES256GCM,
  decryptDataAES256GCM,
} from '../src/bnb/greenfield.js';
import {
  isGreenfieldUploadResult,
  isGreenfieldObjectResult,
  isGreenfieldObjectMetadata,
  isGreenfieldBucketMetadata,
  isGreenfieldBackupResult,
  type GreenfieldUploadParams,
  type GreenfieldBackupParams,
} from '@notch/shared-types';
import { AgentSession } from '../src/wallet/session.js';
import { BnbAgentSdk } from '../src/bnb/bnb-sdk.js';

describe('BNB Greenfield Decentralized Storage Adapter', () => {
  describe('Constants & Configuration', () => {
    it('exports standard Greenfield Testnet constants', () => {
      expect(GREENFIELD_TESTNET_CHAIN_ID).toBe(5600);
      expect(GREENFIELD_TESTNET_SP_URL).toBe('https://gnfd-testnet-sp1.bnbchain.org');
      expect(GREENFIELD_TESTNET_RPC_URL).toBe(
        'https://gnfd-testnet-fullnode-tendermint-us.bnbchain.org'
      );
      expect(DEFAULT_BACKUP_BUCKET).toBe('notch-agent-backups');
    });

    it('initializes GreenfieldClient with default parameters', () => {
      const client = new GreenfieldClient();
      expect(client.chainId).toBe(5600);
      expect(client.spUrl).toBe('https://gnfd-testnet-sp1.bnbchain.org');
      expect(client.rpcUrl).toBe('https://gnfd-testnet-fullnode-tendermint-us.bnbchain.org');
      expect(client.defaultBucket).toBe('notch-agent-backups');
    });

    it('allows custom configuration in constructor', () => {
      const client = new GreenfieldClient({
        chainId: 5601,
        spUrl: 'https://custom-sp.bnbchain.org',
        rpcUrl: 'https://custom-rpc.bnbchain.org',
        defaultBucket: 'my-custom-bucket',
      });
      expect(client.chainId).toBe(5601);
      expect(client.spUrl).toBe('https://custom-sp.bnbchain.org');
      expect(client.rpcUrl).toBe('https://custom-rpc.bnbchain.org');
      expect(client.defaultBucket).toBe('my-custom-bucket');
    });
  });

  describe('Cryptographic Helpers', () => {
    describe('computeSha256', () => {
      it('computes deterministic SHA-256 hex string for string content', () => {
        const hash1 = computeSha256('Hello BNB Greenfield');
        const hash2 = computeSha256('Hello BNB Greenfield');
        const hash3 = computeSha256('Different content');

        expect(hash1).toBe(hash2);
        expect(hash1).not.toBe(hash3);
        expect(hash1).toMatch(/^[0-9a-f]{64}$/i);
      });

      it('computes hash for Buffer input identical to string input', () => {
        const str = 'Notch Agent Decentralized Payload';
        const strHash = computeSha256(str);
        const bufHash = computeSha256(Buffer.from(str, 'utf-8'));

        expect(bufHash).toBe(strHash);
      });
    });

    describe('encryptDataAES256GCM & decryptDataAES256GCM', () => {
      const testSecret = 'agent-super-secret-backup-passphrase-2026';
      const plainText = JSON.stringify({
        sessionId: 'session-xyz-123',
        messages: [
          { role: 'user', content: 'Swap 0.1 BNB for CAKE' },
          { role: 'assistant', content: 'Swap executed: tx 0x123' },
        ],
      });

      it('encrypts plaintext and decrypts back to original content', () => {
        const encrypted = encryptDataAES256GCM(plainText, testSecret);
        expect(encrypted).not.toBe(plainText);
        expect(typeof encrypted).toBe('string');

        const decrypted = decryptDataAES256GCM(encrypted, testSecret);
        expect(decrypted).toBe(plainText);
        expect(JSON.parse(decrypted).sessionId).toBe('session-xyz-123');
      });

      it('fails decryption with incorrect passphrase/key', () => {
        const encrypted = encryptDataAES256GCM(plainText, testSecret);
        expect(() => {
          decryptDataAES256GCM(encrypted, 'wrong-passphrase-1234');
        }).toThrow(/decryption failed|unsupported state|auth tag/i);
      });

      it('fails decryption if encrypted payload is tampered with', () => {
        const encrypted = encryptDataAES256GCM(plainText, testSecret);
        const tampered = encrypted.slice(0, -4) + 'abcd';
        expect(() => {
          decryptDataAES256GCM(tampered, testSecret);
        }).toThrow();
      });

      it('handles unicode characters and complex JSON payloads', () => {
        const unicodeData = 'Agent 🚀 智能合约 BNB Chain ⚡️';
        const enc = encryptDataAES256GCM(unicodeData, testSecret);
        const dec = decryptDataAES256GCM(enc, testSecret);
        expect(dec).toBe(unicodeData);
      });
    });
  });

  describe('GreenfieldClient Storage Operations', () => {
    let client: GreenfieldClient;

    beforeEach(() => {
      client = new GreenfieldClient({
        defaultBucket: 'test-bucket',
      });
    });

    describe('uploadObject', () => {
      it('uploads a string object and returns valid GreenfieldUploadResult', async () => {
        const params: GreenfieldUploadParams = {
          bucket: 'agent-data',
          objectName: 'identity/metadata.json',
          content: JSON.stringify({ name: 'NotchAgent007', version: '1.0.0' }),
          contentType: 'application/json',
          isPrivate: false,
        };

        const result = await client.uploadObject(params);

        expect(isGreenfieldUploadResult(result)).toBe(true);
        expect(result.bucket).toBe('agent-data');
        expect(result.objectName).toBe('identity/metadata.json');
        expect(result.url).toContain('https://gnfd-testnet-sp1.bnbchain.org');
        expect(result.url).toContain('agent-data/identity/metadata.json');
        expect(result.contentHash).toBe(computeSha256(params.content));
        expect(result.size).toBe(Buffer.byteLength(params.content, 'utf-8'));
        expect(result.isPrivate).toBe(false);
        expect(result.objectId).toBeDefined();
        expect(result.timestamp).toBeGreaterThan(0);
      });

      it('uploads Buffer content and computes correct size and hash', async () => {
        const buf = Buffer.from('Binary / Raw agent storage content', 'utf-8');
        const result = await client.uploadObject({
          bucket: 'binary-bucket',
          objectName: 'blobs/data.bin',
          content: buf,
          contentType: 'application/octet-stream',
          isPrivate: true,
        });

        expect(result.size).toBe(buf.length);
        expect(result.contentHash).toBe(computeSha256(buf));
        expect(result.isPrivate).toBe(true);
      });

      it('uses defaultBucket if bucket is omitted in parameters', async () => {
        const result = await client.uploadObject({
          objectName: 'default-path.txt',
          content: 'Hello default bucket',
        });

        expect(result.bucket).toBe('test-bucket');
        expect(result.objectName).toBe('default-path.txt');
      });

      it('throws error when objectName or content is missing/empty', async () => {
        await expect(
          client.uploadObject({
            bucket: 'test-bucket',
            objectName: '',
            content: 'some content',
          })
        ).rejects.toThrow(/object name/i);

        await expect(
          client.uploadObject({
            bucket: 'test-bucket',
            objectName: 'test.txt',
            content: undefined as any,
          })
        ).rejects.toThrow(/content/i);
      });
    });

    describe('getObject', () => {
      it('retrieves uploaded object content and metadata correctly', async () => {
        const content = 'Decentralized Agent Memory 2026';
        await client.uploadObject({
          bucket: 'memory-bucket',
          objectName: 'context/mem1.txt',
          content,
          contentType: 'text/plain',
        });

        const obj = await client.getObject('memory-bucket', 'context/mem1.txt');

        expect(isGreenfieldObjectResult(obj)).toBe(true);
        expect(obj.bucket).toBe('memory-bucket');
        expect(obj.objectName).toBe('context/mem1.txt');
        expect(obj.content).toBe(content);
        expect(obj.contentType).toBe('text/plain');
        expect(obj.contentHash).toBe(computeSha256(content));
        expect(obj.size).toBe(Buffer.byteLength(content, 'utf-8'));
      });

      it('throws error when requested object does not exist', async () => {
        await expect(
          client.getObject('nonexistent-bucket', 'nonexistent-object.json')
        ).rejects.toThrow(/object not found/i);
      });
    });

    describe('listObjects', () => {
      it('lists all objects in a bucket', async () => {
        await client.uploadObject({
          bucket: 'list-bucket',
          objectName: 'docs/doc1.md',
          content: '# Doc 1',
        });
        await client.uploadObject({
          bucket: 'list-bucket',
          objectName: 'docs/doc2.md',
          content: '# Doc 2',
        });
        await client.uploadObject({
          bucket: 'list-bucket',
          objectName: 'images/logo.png',
          content: 'fake-png-data',
        });

        const objects = await client.listObjects('list-bucket');
        expect(objects).toHaveLength(3);
        expect(objects.every((o) => isGreenfieldObjectMetadata(o))).toBe(true);
        expect(objects.map((o) => o.objectName)).toContain('docs/doc1.md');
        expect(objects.map((o) => o.objectName)).toContain('docs/doc2.md');
        expect(objects.map((o) => o.objectName)).toContain('images/logo.png');
      });

      it('filters objects by prefix when provided', async () => {
        await client.uploadObject({
          bucket: 'prefix-bucket',
          objectName: 'logs/2026-08-01.log',
          content: 'log 1',
        });
        await client.uploadObject({
          bucket: 'prefix-bucket',
          objectName: 'logs/2026-08-02.log',
          content: 'log 2',
        });
        await client.uploadObject({
          bucket: 'prefix-bucket',
          objectName: 'config/settings.json',
          content: '{}',
        });

        const logsOnly = await client.listObjects('prefix-bucket', 'logs/');
        expect(logsOnly).toHaveLength(2);
        expect(logsOnly.every((o) => o.objectName.startsWith('logs/'))).toBe(true);
      });

      it('returns empty array for empty bucket', async () => {
        const emptyList = await client.listObjects('empty-bucket');
        expect(emptyList).toEqual([]);
      });
    });

    describe('createBucket & listBuckets', () => {
      it('creates and lists buckets with metadata', async () => {
        const bucket = await client.createBucket('my-agent-bucket', {
          visibility: 'public',
        });

        expect(isGreenfieldBucketMetadata(bucket)).toBe(true);
        expect(bucket.bucketName).toBe('my-agent-bucket');
        expect(bucket.visibility).toBe('public');

        const buckets = await client.listBuckets();
        expect(buckets.some((b) => b.bucketName === 'my-agent-bucket')).toBe(true);
      });
    });

    describe('deleteObject', () => {
      it('deletes an object and makes subsequent getObject fail', async () => {
        await client.uploadObject({
          bucket: 'delete-bucket',
          objectName: 'temp.txt',
          content: 'temporary file',
        });

        const delResult = await client.deleteObject('delete-bucket', 'temp.txt');
        expect(delResult.success).toBe(true);

        await expect(
          client.getObject('delete-bucket', 'temp.txt')
        ).rejects.toThrow(/not found/i);
      });
    });

    describe('backupChatHistory & restoreChatHistory', () => {
      it('backs up pre-encrypted chat history and returns GreenfieldBackupResult', async () => {
        const encryptedData = encryptDataAES256GCM(
          JSON.stringify([{ role: 'user', content: 'What is Greenfield?' }]),
          'secret-key-123'
        );

        const params: GreenfieldBackupParams = {
          sessionId: 'session-chat-456',
          encryptedData,
        };

        const result = await client.backupChatHistory(params);

        expect(isGreenfieldBackupResult(result)).toBe(true);
        expect(result.sessionId).toBe('session-chat-456');
        expect(result.url).toContain('test-bucket/backups/session-chat-456.json');
        expect(result.objectId).toBeDefined();
        expect(result.timestamp).toBeGreaterThan(0);
      });

      it('backs up using default notch-agent-backups bucket when unconfigured', async () => {
        const defaultClient = new GreenfieldClient();
        const res = await defaultClient.backupChatHistory({
          sessionId: 'session-default-bucket',
          encryptedData: 'dummy-encrypted-data',
        });
        expect(res.url).toContain('notch-agent-backups/backups/session-default-bucket.json');
      });

      it('supports client-side rawHistory encryption during backup and restoration', async () => {
        const rawHistory = [
          { role: 'system', content: 'You are Notch Agent on BNB Chain.' },
          { role: 'user', content: 'How do I register on ERC-8004?' },
          { role: 'assistant', content: 'Call wallet.registerERC8004Identity' },
        ];
        const encryptionKey = 'chat-session-aes-key';

        const backup = await client.backupChatHistory({
          sessionId: 'session-e2e-789',
          rawHistory,
          encryptionKey,
        });

        expect(backup.sessionId).toBe('session-e2e-789');

        // Restore chat history
        const restored = await client.restoreChatHistory({
          sessionId: 'session-e2e-789',
          encryptionKey,
        });

        expect(restored.sessionId).toBe('session-e2e-789');
        expect(restored.rawHistory).toEqual(rawHistory);
      });

      it('fails restoration if incorrect encryption key is provided', async () => {
        const rawHistory = [{ role: 'user', content: 'Secret trading prompt' }];
        await client.backupChatHistory({
          sessionId: 'session-fail-key',
          rawHistory,
          encryptionKey: 'correct-key',
        });

        await expect(
          client.restoreChatHistory({
            sessionId: 'session-fail-key',
            encryptionKey: 'wrong-key',
          })
        ).rejects.toThrow(/decryption failed|auth tag|unsupported state/i);
      });
    });
  });

  describe('BnbAgentSdk Facade Integration', () => {
    let session: AgentSession;
    let sdk: BnbAgentSdk;

    beforeEach(() => {
      session = new AgentSession();
      sdk = new BnbAgentSdk(session);
    });

    it('exposes greenfield client instance and helper methods on BnbAgentSdk', async () => {
      expect(sdk.greenfield).toBeInstanceOf(GreenfieldClient);
      expect(sdk.greenfield.chainId).toBe(5600);

      const uploadResult = await sdk.uploadToGreenfield({
        bucket: 'sdk-bucket',
        objectName: 'agent-config.json',
        content: JSON.stringify({ model: 'gpt-4o' }),
      });

      expect(isGreenfieldUploadResult(uploadResult)).toBe(true);
      expect(uploadResult.objectName).toBe('agent-config.json');

      const getResult = await sdk.getFromGreenfield('sdk-bucket', 'agent-config.json');
      expect(getResult.content).toContain('gpt-4o');

      const listResult = await sdk.listGreenfieldObjects('sdk-bucket');
      expect(listResult).toHaveLength(1);

      const backupResult = await sdk.backupChatHistory({
        sessionId: 'sdk-session-1',
        encryptedData: 'enc-data-test',
      });
      expect(isGreenfieldBackupResult(backupResult)).toBe(true);
      expect(backupResult.sessionId).toBe('sdk-session-1');
    });
  });
});
