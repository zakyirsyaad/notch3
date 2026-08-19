/**
 * MPP Replay Protection Store
 * Durable on-disk and in-memory replay prevention for x402 settled transactions.
 */

import fs from 'node:fs';
import path from 'node:path';
import type { MPPReplayRecord } from '@notch/shared-types';
import { safeLog } from '../utils/redact.js';

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export interface MPPReplayStoreOptions {
  storePath?: string;
}

export class MPPReplayStore {
  private records: Map<string, MPPReplayRecord> = new Map();
  private storePath?: string;

  constructor(options?: string | MPPReplayStoreOptions) {
    if (typeof options === 'string') {
      this.storePath = options;
    } else if (options && typeof options === 'object') {
      this.storePath = options.storePath;
    }

    if (this.storePath) {
      try {
        this.loadFromDiskSyncInternal();
      } catch (err: any) {
        throw new Error(`Replay store corruption detected: ${err.message}`);
      }
    }
  }

  private normalizeHash(txHash: string): string {
    return txHash.toLowerCase().trim();
  }

  private getLockPath(): string | undefined {
    return this.storePath ? `${this.storePath}.lock` : undefined;
  }

  private acquireLockSync(): void {
    const lockPath = this.getLockPath();
    if (!lockPath) return;

    const maxRetries = 5;
    const retryDelay = 50;

    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        const dir = path.dirname(lockPath);
        if (!fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        const fd = fs.openSync(lockPath, 'wx');
        fs.writeSync(fd, String(process.pid));
        fs.closeSync(fd);
        return;
      } catch (err: any) {
        if (err.code === 'EEXIST') {
          if (attempt === maxRetries) {
            throw new Error(`Failed to acquire lock on ${lockPath} after ${maxRetries} attempts`);
          }
          const start = Date.now();
          while (Date.now() - start < retryDelay) {
            // block
          }
        } else {
          throw err;
        }
      }
    }
  }

  private async acquireLock(): Promise<void> {
    const lockPath = this.getLockPath();
    if (!lockPath) return;

    const maxRetries = 5;
    const retryDelay = 50;

    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        const dir = path.dirname(lockPath);
        if (!fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        const fd = fs.openSync(lockPath, 'wx');
        fs.writeSync(fd, String(process.pid));
        fs.closeSync(fd);
        return;
      } catch (err: any) {
        if (err.code === 'EEXIST') {
          if (attempt === maxRetries) {
            throw new Error(`Failed to acquire lock on ${lockPath} after ${maxRetries} attempts`);
          }
          await sleep(retryDelay);
        } else {
          throw err;
        }
      }
    }
  }

  private releaseLock(): void {
    const lockPath = this.getLockPath();
    if (!lockPath) return;

    try {
      if (fs.existsSync(lockPath)) {
        fs.unlinkSync(lockPath);
      }
    } catch (err) {
      safeLog('error', `Failed to release lock on ${lockPath}:`, err);
    }
  }

  private loadFromDiskSyncInternal(): void {
    if (!this.storePath) return;
    if (fs.existsSync(this.storePath)) {
      const raw = fs.readFileSync(this.storePath, 'utf8');
      if (raw.trim()) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          this.records.clear();
          for (const item of parsed) {
            if (item && item.txHash) {
              this.records.set(this.normalizeHash(item.txHash), item);
            }
          }
        } else {
          throw new Error('Replay records data format must be an array');
        }
      }
    }
  }

  private loadFromDiskSync(): void {
    if (!this.storePath) return;

    this.acquireLockSync();
    try {
      this.loadFromDiskSyncInternal();
    } catch (err: any) {
      safeLog('error', `Failed to load replay store from ${this.storePath}:`, err);
      throw new Error(`Replay store corruption detected: ${err.message}`);
    } finally {
      this.releaseLock();
    }
  }

  private persistToDiskSyncInternal(): void {
    if (!this.storePath) return;
    const tmpPath = `${this.storePath}.tmp`;
    const allRecords = Array.from(this.records.values());
    fs.writeFileSync(tmpPath, JSON.stringify(allRecords, null, 2), 'utf8');
    fs.renameSync(tmpPath, this.storePath);
  }

  private async persistToDisk(): Promise<void> {
    if (!this.storePath) return;

    await this.acquireLock();
    try {
      this.persistToDiskSyncInternal();
    } catch (err) {
      safeLog('error', `Failed to persist replay store to ${this.storePath}:`, err);
      throw err;
    } finally {
      this.releaseLock();
    }
  }

  /**
   * Checks if a transaction hash has already been redeemed.
   */
  async has(txHash: string): Promise<boolean> {
    if (!txHash) return false;

    if (this.storePath) {
      this.acquireLockSync();
      try {
        this.loadFromDiskSyncInternal();
      } catch (err) {
        // ignore
      } finally {
        this.releaseLock();
      }
    }

    const record = this.records.get(this.normalizeHash(txHash));
    if (!record) return false;
    return record.status !== 'failed';
  }

  /**
   * Claims and records a transaction hash atomically.
   * Throws if the transaction has already been claimed or if persistence fails.
   */
  async claim(record: MPPReplayRecord): Promise<void> {
    const normalizedHash = this.normalizeHash(record.txHash);
    
    await this.acquireLock();
    try {
      this.loadFromDiskSyncInternal();
      
      const existing = this.records.get(normalizedHash);
      if (existing && existing.status !== 'failed') {
        throw new Error(`Transaction ${record.txHash} already redeemed or processing (replay detected)`);
      }

      const normalizedRecord: MPPReplayRecord = {
        ...record,
        txHash: normalizedHash,
        status: record.status || 'reserved',
      };

      this.records.set(normalizedHash, normalizedRecord);
      this.persistToDiskSyncInternal();
    } catch (err) {
      throw err;
    } finally {
      this.releaseLock();
    }
  }

  /**
   * Updates the status of a claimed record.
   */
  async updateStatus(txHash: string, status: 'reserved' | 'completed' | 'failed', response?: any): Promise<void> {
    const normalizedHash = this.normalizeHash(txHash);
    
    await this.acquireLock();
    try {
      this.loadFromDiskSyncInternal();
      
      const record = this.records.get(normalizedHash);
      if (!record) {
        throw new Error(`Transaction ${txHash} not found in replay store to update status.`);
      }

      record.status = status;
      if (response !== undefined) {
        record.response = response;
      }

      this.persistToDiskSyncInternal();
    } catch (err) {
      throw err;
    } finally {
      this.releaseLock();
    }
  }

  /**
   * Releases/deletes a transaction hash from the store.
   */
  async release(txHash: string): Promise<void> {
    const normalizedHash = this.normalizeHash(txHash);
    
    await this.acquireLock();
    try {
      this.loadFromDiskSyncInternal();
      this.records.delete(normalizedHash);
      this.persistToDiskSyncInternal();
    } catch (err) {
      throw err;
    } finally {
      this.releaseLock();
    }
  }

  /**
   * Retrieves a replay record by transaction hash.
   */
  get(txHash: string): MPPReplayRecord | undefined {
    if (!txHash) return undefined;
    
    if (this.storePath) {
      this.acquireLockSync();
      try {
        this.loadFromDiskSyncInternal();
      } catch (err) {
        // ignore
      } finally {
        this.releaseLock();
      }
    }
    
    return this.records.get(this.normalizeHash(txHash));
  }

  /**
   * Records a redeemed transaction hash.
   */
  async record(record: MPPReplayRecord): Promise<void> {
    const normalizedHash = this.normalizeHash(record.txHash);
    
    await this.acquireLock();
    try {
      this.loadFromDiskSyncInternal();
      
      const normalizedRecord: MPPReplayRecord = {
        ...record,
        txHash: normalizedHash,
        status: record.status || 'completed',
      };

      this.records.set(normalizedHash, normalizedRecord);
      this.persistToDiskSyncInternal();
    } catch (err) {
      throw err;
    } finally {
      this.releaseLock();
    }
  }

  /**
   * Returns all recorded replay entries.
   */
  getAll(): MPPReplayRecord[] {
    return Array.from(this.records.values());
  }

  /**
   * Clears all in-memory and persisted records.
   */
  async clear(): Promise<void> {
    this.records.clear();
    await this.persistToDisk();
  }

  /**
   * Total number of stored replay records.
   */
  get count(): number {
    return this.records.size;
  }
}
