import { describe, it, expect } from 'vitest';
import {
  isGreenfieldUploadParams,
  isGreenfieldUploadResult,
  isGreenfieldObjectResult,
  isGreenfieldObjectMetadata,
  isGreenfieldBucketMetadata,
  isGreenfieldBackupParams,
  isGreenfieldBackupResult,
  type GreenfieldUploadParams,
  type GreenfieldUploadResult,
  type GreenfieldObjectResult,
  type GreenfieldObjectMetadata,
  type GreenfieldBucketMetadata,
  type GreenfieldBackupParams,
  type GreenfieldBackupResult,
} from '../src/greenfield.js';
import {
  isNetworkConfig,
  isNetworkSwitchParams,
  isNetworkSwitchResult,
  isSupportedChainId,
  SUPPORTED_CHAIN_IDS,
  type NetworkConfig,
  type NetworkSwitchParams,
  type NetworkSwitchResult,
  type SupportedChainId,
} from '../src/network.js';

describe('Phase 3 Greenfield Storage Schemas & Type Guards', () => {
  describe('isGreenfieldUploadParams', () => {
    it('validates minimal valid GreenfieldUploadParams', () => {
      const params: GreenfieldUploadParams = {
        bucket: 'notch-agent-storage',
        objectName: 'manifest.json',
        content: '{"name":"agent-001"}',
      };
      expect(isGreenfieldUploadParams(params)).toBe(true);
    });

    it('validates full GreenfieldUploadParams with optional contentType and isPrivate', () => {
      const params: GreenfieldUploadParams = {
        bucket: 'notch-agent-storage',
        objectName: 'encrypted-backup-12345.bin',
        content: 'dGVzdC1lbmNyeXB0ZWQtZGF0YQ==',
        contentType: 'application/octet-stream',
        isPrivate: true,
      };
      expect(isGreenfieldUploadParams(params)).toBe(true);
    });

    it('rejects invalid GreenfieldUploadParams', () => {
      expect(isGreenfieldUploadParams(null)).toBe(false);
      expect(isGreenfieldUploadParams(undefined)).toBe(false);
      expect(isGreenfieldUploadParams({})).toBe(false);
      expect(isGreenfieldUploadParams({ bucket: 'notch', objectName: 'file.txt' })).toBe(false); // missing content
      expect(isGreenfieldUploadParams({ bucket: 123, objectName: 'file.txt', content: 'hello' })).toBe(false); // non-string bucket
      expect(isGreenfieldUploadParams({ bucket: 'b', objectName: ['f'], content: 'hello' })).toBe(false); // non-string objectName
      expect(isGreenfieldUploadParams({ bucket: 'b', objectName: 'f', content: 12345 })).toBe(false); // non-string content
      expect(isGreenfieldUploadParams({ bucket: 'b', objectName: 'f', content: 'h', contentType: 123 })).toBe(false); // non-string contentType
      expect(isGreenfieldUploadParams({ bucket: 'b', objectName: 'f', content: 'h', isPrivate: 'true' })).toBe(false); // non-boolean isPrivate
    });
  });

  describe('isGreenfieldUploadResult', () => {
    it('validates minimal valid GreenfieldUploadResult', () => {
      const result: GreenfieldUploadResult = {
        objectId: 'gnfd-obj-001',
        bucket: 'notch-agent-storage',
        objectName: 'manifest.json',
        url: 'https://gnfd-testnet-sp1.bnbchain.org/download/notch-agent-storage/manifest.json',
      };
      expect(isGreenfieldUploadResult(result)).toBe(true);
    });

    it('validates full GreenfieldUploadResult with all optional metadata', () => {
      const result: GreenfieldUploadResult = {
        objectId: 'gnfd-obj-001',
        bucket: 'notch-agent-storage',
        objectName: 'manifest.json',
        url: 'https://gnfd-testnet-sp1.bnbchain.org/download/notch-agent-storage/manifest.json',
        contentHash: '0x3a4f6d8e9c',
        size: 1024,
        isPrivate: false,
        timestamp: 1723800000000,
      };
      expect(isGreenfieldUploadResult(result)).toBe(true);
    });

    it('rejects invalid GreenfieldUploadResult', () => {
      expect(isGreenfieldUploadResult(null)).toBe(false);
      expect(isGreenfieldUploadResult({})).toBe(false);
      expect(isGreenfieldUploadResult({ objectId: 'id', bucket: 'b', objectName: 'o' })).toBe(false); // missing url
      expect(isGreenfieldUploadResult({ objectId: 1, bucket: 'b', objectName: 'o', url: 'http' })).toBe(false); // non-string objectId
      expect(isGreenfieldUploadResult({ objectId: 'id', bucket: 'b', objectName: 'o', url: 'http', size: '1024' })).toBe(false); // non-number size
      expect(isGreenfieldUploadResult({ objectId: 'id', bucket: 'b', objectName: 'o', url: 'http', timestamp: 'now' })).toBe(false); // non-number timestamp
    });
  });

  describe('isGreenfieldObjectResult', () => {
    it('validates minimal valid GreenfieldObjectResult', () => {
      const result: GreenfieldObjectResult = {
        bucket: 'notch-agent-storage',
        objectName: 'manifest.json',
        content: '{"name":"notch-agent"}',
      };
      expect(isGreenfieldObjectResult(result)).toBe(true);
    });

    it('validates full GreenfieldObjectResult with optional fields', () => {
      const result: GreenfieldObjectResult = {
        bucket: 'notch-agent-storage',
        objectName: 'manifest.json',
        content: '{"name":"notch-agent"}',
        contentType: 'application/json',
        contentHash: '0x1234567890abcdef',
        size: 24,
        isPrivate: false,
        timestamp: 1723800000000,
      };
      expect(isGreenfieldObjectResult(result)).toBe(true);
    });

    it('rejects invalid GreenfieldObjectResult', () => {
      expect(isGreenfieldObjectResult(null)).toBe(false);
      expect(isGreenfieldObjectResult({ bucket: 'b', objectName: 'o' })).toBe(false); // missing content
      expect(isGreenfieldObjectResult({ bucket: 'b', content: 'c' })).toBe(false); // missing objectName
      expect(isGreenfieldObjectResult({ bucket: 'b', objectName: 'o', content: 'c', size: 'small' })).toBe(false); // non-number size
      expect(isGreenfieldObjectResult({ bucket: 'b', objectName: 'o', content: 'c', isPrivate: 1 })).toBe(false); // non-boolean isPrivate
    });
  });

  describe('isGreenfieldObjectMetadata', () => {
    it('validates minimal valid GreenfieldObjectMetadata', () => {
      const meta: GreenfieldObjectMetadata = {
        bucket: 'notch-agent-storage',
        objectName: 'chat-history-1.json',
        size: 4096,
      };
      expect(isGreenfieldObjectMetadata(meta)).toBe(true);
    });

    it('validates full GreenfieldObjectMetadata with optional fields', () => {
      const meta: GreenfieldObjectMetadata = {
        objectId: 'gnfd-obj-42',
        bucket: 'notch-agent-storage',
        objectName: 'chat-history-1.json',
        size: 4096,
        contentType: 'application/json',
        contentHash: 'sha256:abc1234',
        isPrivate: true,
        createdAt: 1723800000000,
        updatedAt: 1723800050000,
      };
      expect(isGreenfieldObjectMetadata(meta)).toBe(true);
    });

    it('rejects invalid GreenfieldObjectMetadata', () => {
      expect(isGreenfieldObjectMetadata(null)).toBe(false);
      expect(isGreenfieldObjectMetadata({ bucket: 'b', objectName: 'o' })).toBe(false); // missing size
      expect(isGreenfieldObjectMetadata({ bucket: 'b', objectName: 'o', size: '4096' })).toBe(false); // non-number size
      expect(isGreenfieldObjectMetadata({ bucket: 'b', size: 10 })).toBe(false); // missing objectName
      expect(isGreenfieldObjectMetadata({ objectName: 'o', size: 10 })).toBe(false); // missing bucket
      expect(isGreenfieldObjectMetadata({ bucket: 'b', objectName: 'o', size: 10, createdAt: 'yesterday' })).toBe(false);
    });
  });

  describe('isGreenfieldBucketMetadata', () => {
    it('validates minimal valid GreenfieldBucketMetadata', () => {
      const meta: GreenfieldBucketMetadata = {
        bucketName: 'notch-agent-storage',
        owner: '0x1111111111111111111111111111111111111111',
      };
      expect(isGreenfieldBucketMetadata(meta)).toBe(true);
    });

    it('validates full GreenfieldBucketMetadata with optional visibility and createdAt', () => {
      const meta: GreenfieldBucketMetadata = {
        bucketName: 'notch-agent-storage',
        owner: '0x1111111111111111111111111111111111111111',
        visibility: 'public',
        createdAt: 1723800000000,
      };
      expect(isGreenfieldBucketMetadata(meta)).toBe(true);
    });

    it('rejects invalid GreenfieldBucketMetadata', () => {
      expect(isGreenfieldBucketMetadata(null)).toBe(false);
      expect(isGreenfieldBucketMetadata({ bucketName: 'notch' })).toBe(false); // missing owner
      expect(isGreenfieldBucketMetadata({ owner: '0x123' })).toBe(false); // missing bucketName
      expect(isGreenfieldBucketMetadata({ bucketName: 123, owner: '0x123' })).toBe(false); // non-string bucketName
      expect(isGreenfieldBucketMetadata({ bucketName: 'b', owner: 123 })).toBe(false); // non-string owner
      expect(isGreenfieldBucketMetadata({ bucketName: 'b', owner: '0x1', visibility: 123 })).toBe(false); // non-string visibility
    });
  });

  describe('isGreenfieldBackupParams & isGreenfieldBackupResult', () => {
    it('validates GreenfieldBackupParams', () => {
      const params: GreenfieldBackupParams = {
        sessionId: 'session-2026-08-16',
        encryptedData: 'aes256:iv:ciphertext:tag',
      };
      expect(isGreenfieldBackupParams(params)).toBe(true);
      expect(isGreenfieldBackupParams({ sessionId: 's1' })).toBe(false);
      expect(isGreenfieldBackupParams({ sessionId: 1, encryptedData: 'd' })).toBe(false);
    });

    it('validates GreenfieldBackupResult', () => {
      const result: GreenfieldBackupResult = {
        objectId: 'obj-backup-1',
        url: 'https://gnfd-testnet-sp1.bnbchain.org/download/notch/backup.bin',
        sessionId: 'session-2026-08-16',
        timestamp: 1723800000000,
      };
      expect(isGreenfieldBackupResult(result)).toBe(true);
      expect(isGreenfieldBackupResult({ objectId: '1' })).toBe(false);
    });
  });
});

describe('Phase 3 Multi-Chain Network Schemas & Type Guards', () => {
  describe('SUPPORTED_CHAIN_IDS & isSupportedChainId', () => {
    it('contains expected chain IDs (97, 56, 5611, 204)', () => {
      expect(SUPPORTED_CHAIN_IDS).toContain(97);
      expect(SUPPORTED_CHAIN_IDS).toContain(56);
      expect(SUPPORTED_CHAIN_IDS).toContain(5611);
      expect(SUPPORTED_CHAIN_IDS).toContain(204);
    });

    it('validates supported chain IDs', () => {
      expect(isSupportedChainId(97)).toBe(true);
      expect(isSupportedChainId(56)).toBe(true);
      expect(isSupportedChainId(5611)).toBe(true);
      expect(isSupportedChainId(204)).toBe(true);
      expect(isSupportedChainId(1)).toBe(false);
      expect(isSupportedChainId('97')).toBe(false);
      expect(isSupportedChainId(null)).toBe(false);
    });
  });

  describe('isNetworkConfig', () => {
    it('validates valid NetworkConfig for BSC Testnet', () => {
      const config: NetworkConfig = {
        chainId: 97,
        name: 'BSC Testnet',
        rpcUrl: 'https://data-seed-prebsc-1-s1.binance.org:8545/',
        nativeToken: 'tBNB',
        explorerUrl: 'https://testnet.bscscan.com',
        isTestnet: true,
      };
      expect(isNetworkConfig(config)).toBe(true);
    });

    it('validates valid NetworkConfig for BSC Mainnet with optional wsRpcUrl & currencySymbol', () => {
      const config: NetworkConfig = {
        chainId: 56,
        name: 'BSC Mainnet',
        rpcUrl: 'https://bsc-dataseed.binance.org/',
        nativeToken: 'BNB',
        explorerUrl: 'https://bscscan.com',
        isTestnet: false,
        wsRpcUrl: 'wss://bsc-ws-node.nariox.org:443',
        currencySymbol: 'BNB',
      };
      expect(isNetworkConfig(config)).toBe(true);
    });

    it('validates valid NetworkConfig for opBNB Testnet & Mainnet', () => {
      const opbnbTestnet: NetworkConfig = {
        chainId: 5611,
        name: 'opBNB Testnet',
        rpcUrl: 'https://opbnb-testnet-rpc.bnbchain.org',
        nativeToken: 'tBNB',
        explorerUrl: 'https://testnet.opbnbscan.com',
        isTestnet: true,
      };
      const opbnbMainnet: NetworkConfig = {
        chainId: 204,
        name: 'opBNB Mainnet',
        rpcUrl: 'https://opbnb-mainnet-rpc.bnbchain.org',
        nativeToken: 'BNB',
        explorerUrl: 'https://opbnbscan.com',
        isTestnet: false,
      };
      expect(isNetworkConfig(opbnbTestnet)).toBe(true);
      expect(isNetworkConfig(opbnbMainnet)).toBe(true);
    });

    it('rejects invalid NetworkConfig objects', () => {
      expect(isNetworkConfig(null)).toBe(false);
      expect(isNetworkConfig(undefined)).toBe(false);
      expect(isNetworkConfig({})).toBe(false);
      expect(
        isNetworkConfig({
          chainId: 97,
          name: 'BSC Testnet',
          rpcUrl: 'https://rpc.com',
          nativeToken: 'tBNB',
          explorerUrl: 'https://testnet.bscscan.com',
          // missing isTestnet
        })
      ).toBe(false);
      expect(
        isNetworkConfig({
          chainId: '97', // non-number chainId
          name: 'BSC Testnet',
          rpcUrl: 'https://rpc.com',
          nativeToken: 'tBNB',
          explorerUrl: 'https://testnet.bscscan.com',
          isTestnet: true,
        })
      ).toBe(false);
      expect(
        isNetworkConfig({
          chainId: 97,
          name: 123, // non-string name
          rpcUrl: 'https://rpc.com',
          nativeToken: 'tBNB',
          explorerUrl: 'https://testnet.bscscan.com',
          isTestnet: true,
        })
      ).toBe(false);
      expect(
        isNetworkConfig({
          chainId: 97,
          name: 'BSC Testnet',
          rpcUrl: 'https://rpc.com',
          nativeToken: 'tBNB',
          explorerUrl: 'https://testnet.bscscan.com',
          isTestnet: 'true', // non-boolean isTestnet
        })
      ).toBe(false);
    });
  });

  describe('isNetworkSwitchParams', () => {
    it('validates valid NetworkSwitchParams', () => {
      const params: NetworkSwitchParams = {
        chainId: 56,
      };
      expect(isNetworkSwitchParams(params)).toBe(true);
    });

    it('rejects invalid NetworkSwitchParams', () => {
      expect(isNetworkSwitchParams(null)).toBe(false);
      expect(isNetworkSwitchParams({})).toBe(false);
      expect(isNetworkSwitchParams({ chainId: '56' })).toBe(false); // non-number chainId
      expect(isNetworkSwitchParams({ chainId: true })).toBe(false);
    });
  });

  describe('isNetworkSwitchResult', () => {
    it('validates valid NetworkSwitchResult', () => {
      const result: NetworkSwitchResult = {
        success: true,
        activeNetwork: {
          chainId: 56,
          name: 'BSC Mainnet',
          rpcUrl: 'https://bsc-dataseed.binance.org/',
          nativeToken: 'BNB',
          explorerUrl: 'https://bscscan.com',
          isTestnet: false,
        },
        previousChainId: 97,
      };
      expect(isNetworkSwitchResult(result)).toBe(true);
    });

    it('rejects invalid NetworkSwitchResult', () => {
      expect(isNetworkSwitchResult(null)).toBe(false);
      expect(isNetworkSwitchResult({ success: true })).toBe(false); // missing activeNetwork
      expect(
        isNetworkSwitchResult({
          success: 'true',
          activeNetwork: {
            chainId: 56,
            name: 'BSC Mainnet',
            rpcUrl: 'https://bsc-dataseed.binance.org/',
            nativeToken: 'BNB',
            explorerUrl: 'https://bscscan.com',
            isTestnet: false,
          },
        })
      ).toBe(false); // non-boolean success
      expect(
        isNetworkSwitchResult({
          success: true,
          activeNetwork: { chainId: 56 }, // invalid NetworkConfig
        })
      ).toBe(false);
    });
  });
});
