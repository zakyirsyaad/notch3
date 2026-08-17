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
      this.loadFromDiskSync();
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

  private loadFromDiskSync(): void {
    if (!this.storePath) return;

    this.acquireLockSync();
    try {
      if (fs.existsSync(this.storePath)) {
        const raw = fs.readFileSync(this.storePath, 'utf8');
        if (raw.trim()) {
          const parsed = JSON.parse(raw);
          if (Array.isArray(parsed)) {
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
    } catch (err: any) {
      safeLog('error', `Failed to load replay store from ${this.storePath}:`, err);
      throw new Error(`Replay store corruption detected: ${err.message}`);
    } finally {
      this.releaseLock();
    }
  }

  private async persistToDisk(): Promise<void> {
    if (!this.storePath) return;

    await this.acquireLock();
    try {
      const dir = path.dirname(this.storePath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }

      const tmpPath = `${this.storePath}.tmp`;
      const allRecords = Array.from(this.records.values());
      fs.writeFileSync(tmpPath, JSON.stringify(allRecords, null, 2), 'utf8');
      fs.renameSync(tmpPath, this.storePath);
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

    try {
      await this.persistToDisk();
    } catch (err) {
      if (existing) {
        this.records.set(normalizedHash, existing);
      } else {
        this.records.delete(normalizedHash);
      }
      throw err;
    }
  }

  /**
   * Updates the status of a claimed record.
   */
  async updateStatus(txHash: string, status: 'reserved' | 'completed' | 'failed', response?: any): Promise<void> {
    const normalizedHash = this.normalizeHash(txHash);
    const record = this.records.get(normalizedHash);
    if (!record) {
      throw new Error(`Transaction ${txHash} not found in replay store to update status.`);
    }

    const oldStatus = record.status;
    const oldResponse = record.response;
    
    record.status = status;
    if (response !== undefined) {
      record.response = response;
    }

    try {
      await this.persistToDisk();
    } catch (err) {
      record.status = oldStatus;
      record.response = oldResponse;
      throw err;
    }
  }

  /**
   * Releases/deletes a transaction hash from the store.
   */
  async release(txHash: string): Promise<void> {
    const normalizedHash = this.normalizeHash(txHash);
    const existing = this.records.get(normalizedHash);
    if (!existing) return;

    this.records.delete(normalizedHash);

    try {
      await this.persistToDisk();
    } catch (err) {
      this.records.set(normalizedHash, existing);
      throw err;
    }
  }

  /**
   * Retrieves a replay record by transaction hash.
   */
  get(txHash: string): MPPReplayRecord | undefined {
    if (!txHash) return undefined;
    return this.records.get(this.normalizeHash(txHash));
  }

  /**
   * Records a redeemed transaction hash.
   */
  async record(record: MPPReplayRecord): Promise<void> {
    const normalizedHash = this.normalizeHash(record.txHash);
    const normalizedRecord: MPPReplayRecord = {
      ...record,
      txHash: normalizedHash,
      status: record.status || 'completed',
    };

    this.records.set(normalizedHash, normalizedRecord);
    await this.persistToDisk();
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
