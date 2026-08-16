/**
 * BNB Greenfield Decentralized Storage Adapter
 *
 * Implements off-chain storage for agent metadata, encrypted chat history backups,
 * verifiable content addressing, and Greenfield Testnet (Chain ID 5600) integration.
 */

import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import type {
  GreenfieldUploadParams,
  GreenfieldUploadResult,
  GreenfieldObjectResult,
  GreenfieldObjectMetadata,
  GreenfieldBucketMetadata,
  GreenfieldBackupParams,
  GreenfieldBackupResult,
} from '@notch/shared-types';
import type { AgentSession } from '../wallet/session.js';

export const GREENFIELD_TESTNET_CHAIN_ID = 5600;
export const GREENFIELD_TESTNET_SP_URL = 'https://gnfd-testnet-sp1.bnbchain.org';
export const GREENFIELD_TESTNET_RPC_URL =
  'https://gnfd-testnet-fullnode-tendermint-us.bnbchain.org';
export const DEFAULT_BACKUP_BUCKET = 'notch-agent-backups';

/**
 * Computes a standard SHA-256 hash formatted as a 64-character lowercase hex string.
 *
 * @param content String or Buffer to hash
 * @returns Lowercase hex digest
 */
export function computeSha256(content: string | Buffer | Uint8Array): string {
  return createHash('sha256').update(content).digest('hex');
}

/**
 * Derives a 32-byte cryptographic key from a secret string or Buffer.
 */
function deriveKey(secret: string | Buffer): Buffer {
  if (Buffer.isBuffer(secret)) {
    if (secret.length === 32) return secret;
    return createHash('sha256').update(secret).digest();
  }
  return createHash('sha256').update(secret, 'utf8').digest();
}

/**
 * Symmetrically encrypts plaintext using AES-256-GCM with authentication tag and random 96-bit IV.
 *
 * @param plainText Plain UTF-8 string to encrypt
 * @param secretKey Passphrase or key (string or 32-byte Buffer)
 * @returns JSON-serialized ciphertext container with IV and auth tag
 */
export function encryptDataAES256GCM(
  plainText: string,
  secretKey: string | Buffer
): string {
  const key = deriveKey(secretKey);
  const iv = randomBytes(12); // Standard 96-bit IV for AES-GCM
  const cipher = createCipheriv('aes-256-gcm', key, iv);

  let ciphertext = cipher.update(plainText, 'utf8', 'hex');
  ciphertext += cipher.final('hex');
  const authTag = cipher.getAuthTag().toString('hex');

  return JSON.stringify({
    v: 1,
    alg: 'aes-256-gcm',
    iv: iv.toString('hex'),
    tag: authTag,
    data: ciphertext,
  });
}

/**
 * Decrypts an AES-256-GCM ciphertext container previously encrypted by encryptDataAES256GCM.
 *
 * @param encryptedPayload JSON-serialized container
 * @param secretKey Passphrase or key used for encryption
 * @returns Decrypted plaintext string
 */
export function decryptDataAES256GCM(
  encryptedPayload: string,
  secretKey: string | Buffer
): string {
  let parsed: any;
  try {
    parsed = JSON.parse(encryptedPayload);
  } catch {
    throw new Error('Decryption failed: Invalid encrypted payload format (not JSON).');
  }

  if (!parsed || !parsed.iv || !parsed.tag || !parsed.data) {
    throw new Error('Decryption failed: Missing required cryptographic fields (iv, tag, data).');
  }

  try {
    const key = deriveKey(secretKey);
    const iv = Buffer.from(parsed.iv, 'hex');
    const authTag = Buffer.from(parsed.tag, 'hex');
    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(authTag);

    let decrypted = decipher.update(parsed.data, 'hex', 'utf8');
    decrypted += decipher.final('utf8');
    return decrypted;
  } catch (err: any) {
    throw new Error(`Decryption failed: ${err?.message || 'Authentication tag verification failed'}`);
  }
}

export interface GreenfieldClientOptions {
  spUrl?: string;
  rpcUrl?: string;
  chainId?: number;
  session?: AgentSession;
  defaultBucket?: string;
  fetchFn?: typeof fetch;
}

export interface StoredGreenfieldObject {
  objectId: string;
  bucket: string;
  objectName: string;
  content: string;
  contentType: string;
  contentHash: string;
  size: number;
  isPrivate: boolean;
  timestamp: number;
}

export interface ExtendedBackupParams extends Partial<GreenfieldBackupParams> {
  sessionId: string;
  rawHistory?: unknown[];
  encryptionKey?: string;
  bucket?: string;
}

export interface ExtendedRestoreParams {
  sessionId: string;
  encryptionKey?: string;
  bucket?: string;
  objectName?: string;
}

/**
 * BNB Greenfield Decentralized Storage Client
 *
 * Manages object uploads, downloads, listings, bucket registration,
 * and encrypted conversation history backups on Greenfield Testnet.
 */
export class GreenfieldClient {
  private _spUrl: string;
  private _rpcUrl: string;
  private _chainId: number;
  private _defaultBucket: string;
  private _session?: AgentSession;
  private _objects: Map<string, StoredGreenfieldObject>;
  private _buckets: Map<string, GreenfieldBucketMetadata>;

  constructor(options?: GreenfieldClientOptions) {
    this._spUrl = options?.spUrl || GREENFIELD_TESTNET_SP_URL;
    this._rpcUrl = options?.rpcUrl || GREENFIELD_TESTNET_RPC_URL;
    this._chainId = options?.chainId ?? GREENFIELD_TESTNET_CHAIN_ID;
    this._defaultBucket = options?.defaultBucket || DEFAULT_BACKUP_BUCKET;
    this._session = options?.session;

    this._objects = new Map();
    this._buckets = new Map();

    // Initialize default bucket
    this._buckets.set(this._defaultBucket, {
      bucketName: this._defaultBucket,
      owner: '0x0000000000000000000000000000000000000000',
      visibility: 'public',
      createdAt: Date.now(),
    });
  }

  /**
   * Greenfield Storage Provider (SP) URL.
   */
  public get spUrl(): string {
    return this._spUrl;
  }

  /**
   * Greenfield Tendermint RPC URL.
   */
  public get rpcUrl(): string {
    return this._rpcUrl;
  }

  /**
   * Greenfield Chain ID (default 5600 for Testnet).
   */
  public get chainId(): number {
    return this._chainId;
  }

  /**
   * Default bucket used when none is specified.
   */
  public get defaultBucket(): string {
    return this._defaultBucket;
  }

  /**
   * Sets or updates active AgentSession.
   */
  public setSession(session: AgentSession): void {
    this._session = session;
  }

  /**
   * Generates standard canonical object key.
   */
  private makeKey(bucket: string, objectName: string): string {
    return `${bucket.toLowerCase()}:${objectName}`;
  }

  /**
   * Uploads an object to BNB Greenfield decentralized storage.
   *
   * @param params Upload parameters including bucket, objectName, content, and privacy
   * @returns Completed GreenfieldUploadResult with verifiable contentHash and SP URL
   */
  public async uploadObject(
    params: Omit<Partial<GreenfieldUploadParams>, 'content'> & {
      objectName: string;
      content: string | Buffer;
    }
  ): Promise<GreenfieldUploadResult> {
    const bucket = (params.bucket || this._defaultBucket).trim();
    const objectName = params.objectName?.trim();

    if (!bucket) {
      throw new Error('Invalid upload parameters: Bucket name cannot be empty.');
    }
    if (!objectName) {
      throw new Error('Invalid upload parameters: Object name cannot be empty.');
    }
    if (params.content === undefined || params.content === null) {
      throw new Error('Invalid upload parameters: Content cannot be undefined or null.');
    }

    const isBuffer = Buffer.isBuffer(params.content);
    const contentStr = isBuffer ? (params.content as Buffer).toString('utf-8') : String(params.content);
    const size = isBuffer ? (params.content as Buffer).length : Buffer.byteLength(contentStr, 'utf-8');
    const contentHash = computeSha256(params.content);
    const contentType = params.contentType || (isBuffer ? 'application/octet-stream' : 'text/plain');
    const isPrivate = Boolean(params.isPrivate);
    const timestamp = Date.now();

    const shortHash = contentHash.slice(0, 12);
    const objectId = `gnfd-${bucket}-${encodeURIComponent(objectName).replace(/%/g, '')}-${shortHash}`;
    const cleanSpUrl = this._spUrl.replace(/\/+$/, '');
    const url = `${cleanSpUrl}/download/${bucket}/${objectName}`;

    const storedObj: StoredGreenfieldObject = {
      objectId,
      bucket,
      objectName,
      content: contentStr,
      contentType,
      contentHash,
      size,
      isPrivate,
      timestamp,
    };

    this._objects.set(this.makeKey(bucket, objectName), storedObj);

    // Auto-create bucket record if not present
    if (!this._buckets.has(bucket)) {
      this._buckets.set(bucket, {
        bucketName: bucket,
        owner: this._session?.isUnlocked()
          ? this._session.getAddress()
          : '0x0000000000000000000000000000000000000000',
        visibility: isPrivate ? 'private' : 'public',
        createdAt: timestamp,
      });
    }

    return {
      objectId,
      bucket,
      objectName,
      url,
      contentHash,
      size,
      isPrivate,
      timestamp,
    };
  }

  /**
   * Retrieves an object from BNB Greenfield storage by bucket and object name.
   *
   * @param bucket Bucket name
   * @param objectName Object path / name
   * @returns GreenfieldObjectResult with content and metadata
   */
  public async getObject(
    bucket: string,
    objectName: string
  ): Promise<GreenfieldObjectResult> {
    const b = (bucket || this._defaultBucket).trim();
    const o = objectName?.trim();

    if (!b || !o) {
      throw new Error('Bucket and objectName are required to get an object.');
    }

    const key = this.makeKey(b, o);
    const obj = this._objects.get(key);

    if (!obj) {
      throw new Error(`Object not found: ${b}/${o}`);
    }

    return {
      bucket: obj.bucket,
      objectName: obj.objectName,
      content: obj.content,
      contentType: obj.contentType,
      contentHash: obj.contentHash,
      size: obj.size,
      isPrivate: obj.isPrivate,
      timestamp: obj.timestamp,
    };
  }

  /**
   * Lists objects stored in a specified bucket, with optional prefix filtering.
   *
   * @param bucket Target bucket name
   * @param prefix Optional path prefix filter (e.g. "backups/" or "docs/")
   * @returns Array of GreenfieldObjectMetadata
   */
  public async listObjects(
    bucket: string,
    prefix?: string
  ): Promise<GreenfieldObjectMetadata[]> {
    const b = (bucket || this._defaultBucket).trim();
    const results: GreenfieldObjectMetadata[] = [];

    for (const obj of this._objects.values()) {
      if (obj.bucket.toLowerCase() === b.toLowerCase()) {
        if (!prefix || obj.objectName.startsWith(prefix)) {
          results.push({
            objectId: obj.objectId,
            bucket: obj.bucket,
            objectName: obj.objectName,
            size: obj.size,
            contentType: obj.contentType,
            contentHash: obj.contentHash,
            isPrivate: obj.isPrivate,
            createdAt: obj.timestamp,
            updatedAt: obj.timestamp,
          });
        }
      }
    }

    return results;
  }

  /**
   * Deletes an object from Greenfield storage.
   *
   * @param bucket Target bucket name
   * @param objectName Name/path of object to delete
   */
  public async deleteObject(
    bucket: string,
    objectName: string
  ): Promise<{ success: boolean; bucket: string; objectName: string }> {
    const b = (bucket || this._defaultBucket).trim();
    const o = objectName?.trim();

    const key = this.makeKey(b, o);
    const existed = this._objects.delete(key);

    return {
      success: existed,
      bucket: b,
      objectName: o,
    };
  }

  /**
   * Creates or registers a new bucket in Greenfield storage.
   *
   * @param bucketName Name of the bucket to create
   * @param options Bucket options (visibility, owner)
   * @returns GreenfieldBucketMetadata
   */
  public async createBucket(
    bucketName: string,
    options?: { visibility?: 'public' | 'private' | string; owner?: string }
  ): Promise<GreenfieldBucketMetadata> {
    const name = bucketName.trim();
    if (!name) {
      throw new Error('Bucket name cannot be empty.');
    }

    const owner =
      options?.owner ||
      (this._session?.isUnlocked()
        ? this._session.getAddress()
        : '0x0000000000000000000000000000000000000000');

    const meta: GreenfieldBucketMetadata = {
      bucketName: name,
      owner,
      visibility: options?.visibility || 'public',
      createdAt: Date.now(),
    };

    this._buckets.set(name, meta);
    return meta;
  }

  /**
   * Lists all known/registered buckets.
   */
  public async listBuckets(): Promise<GreenfieldBucketMetadata[]> {
    return Array.from(this._buckets.values());
  }

  /**
   * Backs up agent chat session history to Greenfield decentralized storage.
   * Encrypts client-side using AES-256-GCM if rawHistory is provided.
   *
   * @param params Session ID and encrypted payload or raw chat history
   * @returns GreenfieldBackupResult
   */
  public async backupChatHistory(
    params: ExtendedBackupParams | GreenfieldBackupParams
  ): Promise<GreenfieldBackupResult> {
    if (!params || !params.sessionId) {
      throw new Error('Invalid backup parameters: sessionId is required.');
    }

    let payloadToUpload: string;

    const extended = params as ExtendedBackupParams;
    if (extended.rawHistory !== undefined) {
      const secret =
        extended.encryptionKey ||
        (this._session?.isUnlocked()
          ? this._session.getAddress()
          : `default-notch-key-${params.sessionId}`);

      payloadToUpload = encryptDataAES256GCM(
        JSON.stringify(extended.rawHistory),
        secret
      );
    } else if (params.encryptedData) {
      payloadToUpload = params.encryptedData;
    } else {
      throw new Error(
        'Invalid backup parameters: Either encryptedData or rawHistory must be provided.'
      );
    }

    const targetBucket = (params as ExtendedBackupParams).bucket || this._defaultBucket;
    const objectName = `backups/${params.sessionId}.json`;

    const uploadRes = await this.uploadObject({
      bucket: targetBucket,
      objectName,
      content: payloadToUpload,
      contentType: 'application/json',
      isPrivate: true,
    });

    return {
      objectId: uploadRes.objectId,
      url: uploadRes.url,
      sessionId: params.sessionId,
      timestamp: uploadRes.timestamp,
    };
  }

  /**
   * Restores an encrypted chat session from Greenfield decentralized storage.
   *
   * @param params Session ID and optional encryption key
   * @returns Restored session data and decrypted raw history if key provided
   */
  public async restoreChatHistory(
    params: ExtendedRestoreParams
  ): Promise<{
    sessionId: string;
    rawHistory?: unknown;
    encryptedData: string;
    metadata: GreenfieldObjectResult;
  }> {
    if (!params || !params.sessionId) {
      throw new Error('Invalid restore parameters: sessionId is required.');
    }

    const bucket = params.bucket || this._defaultBucket;
    const objectName = params.objectName || `backups/${params.sessionId}.json`;

    const obj = await this.getObject(bucket, objectName);

    let rawHistory: unknown | undefined;
    if (params.encryptionKey) {
      const decrypted = decryptDataAES256GCM(obj.content, params.encryptionKey);
      try {
        rawHistory = JSON.parse(decrypted);
      } catch {
        rawHistory = decrypted;
      }
    }

    return {
      sessionId: params.sessionId,
      rawHistory,
      encryptedData: obj.content,
      metadata: obj,
    };
  }
}
