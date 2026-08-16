/**
 * MPP Replay Protection Store
 * Durable on-disk and in-memory replay prevention for x402 settled transactions.
 */

import fs from 'node:fs';
import path from 'node:path';
import type { MPPReplayRecord } from '@notch/shared-types';

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
      this.loadFromDisk();
    }
  }

  private normalizeHash(txHash: string): string {
    return txHash.toLowerCase().trim();
  }

  private loadFromDisk(): void {
    if (!this.storePath) return;

    try {
      if (fs.existsSync(this.storePath)) {
        const raw = fs.readFileSync(this.storePath, 'utf8');
        if (raw.trim()) {
          const parsed: MPPReplayRecord[] = JSON.parse(raw);
          if (Array.isArray(parsed)) {
            for (const item of parsed) {
              if (item && item.txHash) {
                this.records.set(this.normalizeHash(item.txHash), item);
              }
            }
          }
        }
      }
    } catch (err) {
      console.warn(`[MPPReplayStore] Failed to load replay store from ${this.storePath}:`, err);
    }
  }

  private persistToDisk(): void {
    if (!this.storePath) return;

    try {
      const dir = path.dirname(this.storePath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }

      const allRecords = Array.from(this.records.values());
      fs.writeFileSync(this.storePath, JSON.stringify(allRecords, null, 2), 'utf8');
    } catch (err) {
      console.error(`[MPPReplayStore] Failed to persist replay store to ${this.storePath}:`, err);
    }
  }

  /**
   * Checks if a transaction hash has already been redeemed.
   */
  async has(txHash: string): Promise<boolean> {
    if (!txHash) return false;
    return this.records.has(this.normalizeHash(txHash));
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
    };

    this.records.set(normalizedHash, normalizedRecord);
    this.persistToDisk();
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
    this.persistToDisk();
  }

  /**
   * Total number of stored replay records.
   */
  get count(): number {
    return this.records.size;
  }
}
