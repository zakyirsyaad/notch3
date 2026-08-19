import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { parseEther, Wallet, ZeroAddress } from 'ethers';
import { MPPReplayStore } from '../src/mpp/replay-store.js';
import { MPPServer } from '../src/mpp/server.js';
import type { MPPReplayRecord, MPPServerConfig } from '@notch/shared-types';

const TEST_RECIPIENT = '0x1111111111111111111111111111111111111111';
const TEST_PAYER = '0x2222222222222222222222222222222222222222';
const TEST_TX_HASH = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

function makeHttpRequest(
  options: http.RequestOptions,
  body?: string | object
): Promise<{ statusCode: number; headers: http.IncomingHttpHeaders; body: any; rawBody: string }> {
  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        let parsed = data;
        try {
          parsed = JSON.parse(data);
        } catch {
          // not JSON
        }
        resolve({
          statusCode: res.statusCode || 0,
          headers: res.headers,
          body: parsed,
          rawBody: data,
        });
      });
    });

    req.on('error', reject);

    if (body) {
      const data = typeof body === 'string' ? body : JSON.stringify(body);
      req.setHeader('Content-Type', 'application/json');
      req.setHeader('Content-Length', Buffer.byteLength(data));
      req.write(data);
    }
    req.end();
  });
}

describe('MPP Replay Store (MPPReplayStore)', () => {
  let tempDir: string;
  let tempFilePath: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mpp-test-'));
    tempFilePath = path.join(tempDir, 'replays.json');
  });

  afterEach(() => {
    try {
      if (fs.existsSync(tempDir)) {
        fs.rmSync(tempDir, { recursive: true, force: true });
      }
    } catch {
      // ignore
    }
  });

  it('in-memory cache tracks and checks redeemed txHashes', async () => {
    const store = new MPPReplayStore();
    expect(await store.has(TEST_TX_HASH)).toBe(false);
    expect(store.getAll().length).toBe(0);

    const record: MPPReplayRecord = {
      txHash: TEST_TX_HASH,
      payer: TEST_PAYER,
      recipient: TEST_RECIPIENT,
      amount: '0.001',
      token: 'tBNB',
      chainId: 97,
      endpoint: '/api/v1/tools/weather',
      timestamp: Date.now(),
      blockNumber: 12345,
    };

    await store.record(record);
    expect(await store.has(TEST_TX_HASH)).toBe(true);
    expect(store.get(TEST_TX_HASH)).toEqual({
      ...record,
      status: 'completed',
    });
    expect(store.getAll().length).toBe(1);
    expect(store.getAll()[0].txHash.toLowerCase()).toBe(TEST_TX_HASH.toLowerCase());
  });

  it('normalizes hex txHash case-insensitively', async () => {
    const store = new MPPReplayStore();
    const upperTx = '0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    const lowerTx = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    await store.record({
      txHash: upperTx,
      payer: TEST_PAYER,
      recipient: TEST_RECIPIENT,
      amount: '0.001',
      token: 'tBNB',
      chainId: 97,
      endpoint: '/test',
      timestamp: Date.now(),
    });

    expect(await store.has(lowerTx)).toBe(true);
    expect(await store.has(upperTx)).toBe(true);
    expect(store.get(lowerTx)?.txHash.toLowerCase()).toBe(lowerTx);
  });

  it('persists records to disk and reloads on initialization', async () => {
    const store1 = new MPPReplayStore({ storePath: tempFilePath });
    expect(await store1.has(TEST_TX_HASH)).toBe(false);

    await store1.record({
      txHash: TEST_TX_HASH,
      payer: TEST_PAYER,
      recipient: TEST_RECIPIENT,
      amount: '0.05',
      token: 'tBNB',
      chainId: 97,
      endpoint: '/api/v1/tools/analyze',
      timestamp: 1718000000,
      blockNumber: 5555,
    });

    expect(fs.existsSync(tempFilePath)).toBe(true);
    const diskContent = fs.readFileSync(tempFilePath, 'utf8');
    expect(diskContent).toContain(TEST_TX_HASH);

    // Initialize second store from same file
    const store2 = new MPPReplayStore({ storePath: tempFilePath });
    expect(await store2.has(TEST_TX_HASH)).toBe(true);
    expect(store2.getAll().length).toBe(1);
    expect(store2.get(TEST_TX_HASH)?.amount).toBe('0.05');
  });

  it('clears records properly', async () => {
    const store = new MPPReplayStore({ storePath: tempFilePath });
    await store.record({
      txHash: TEST_TX_HASH,
      payer: TEST_PAYER,
      recipient: TEST_RECIPIENT,
      amount: '0.001',
      token: 'tBNB',
      chainId: 97,
      endpoint: '/test',
      timestamp: Date.now(),
    });

    expect(await store.has(TEST_TX_HASH)).toBe(true);
    await store.clear();
    expect(await store.has(TEST_TX_HASH)).toBe(false);
    expect(store.getAll().length).toBe(0);
  });

  it('fails closed and throws error if replay file is corrupted/invalid JSON', async () => {
    fs.writeFileSync(tempFilePath, 'invalid-json-corruption-data', 'utf8');
    expect(() => new MPPReplayStore({ storePath: tempFilePath })).toThrow(/corruption/i);
  });

  it('prevents concurrent double claims from two different stores pointing to the same file', async () => {
    const store1 = new MPPReplayStore({ storePath: tempFilePath });
    const store2 = new MPPReplayStore({ storePath: tempFilePath });

    const record1: MPPReplayRecord = {
      txHash: TEST_TX_HASH,
      payer: TEST_PAYER,
      recipient: TEST_RECIPIENT,
      amount: '0.001',
      token: 'tBNB',
      chainId: 97,
      endpoint: '/test',
      timestamp: Date.now(),
    };

    const record2 = { ...record1 };

    // Jalankan kedua claim secara paralel (konkuren) pada file yang sama
    const results = await Promise.allSettled([
      store1.claim(record1),
      store2.claim(record2)
    ]);

    // Tepat satu claim harus berhasil (fulfilled), dan claim lainnya harus gagal (rejected)
    const fulfilledCount = results.filter(r => r.status === 'fulfilled').length;
    const rejectedCount = results.filter(r => r.status === 'rejected').length;

    expect(fulfilledCount).toBe(1);
    expect(rejectedCount).toBe(1);

    const rejectedResult = results.find(r => r.status === 'rejected') as PromiseRejectedResult;
    expect(rejectedResult.reason.message).toMatch(/already redeemed|lock/i);
  });
});

describe('MPP Server (MPPServer)', () => {
  let server: MPPServer;
  let mockProvider: any;
  let serverPort: number;

  beforeEach(async () => {
    mockProvider = {
      getTransactionReceipt: vi.fn(),
      getTransaction: vi.fn(),
      getNetwork: vi.fn().mockResolvedValue({ chainId: 97n }),
    };

    server = new MPPServer({
      recipient: TEST_RECIPIENT,
      port: 0, // Ephemeral port for test isolation
      chainId: 97,
      defaultPrice: '0.001',
      token: 'tBNB',
      provider: mockProvider,
    });
  });

  afterEach(async () => {
    if (server && server.isRunning()) {
      await server.stop();
    }
  });

  it('starts on ephemeral port, reports status, and stops cleanly', async () => {
    const startResult = await server.start();
    expect(startResult.port).toBeGreaterThan(0);
    expect(server.isRunning()).toBe(true);

    const status = server.getStatus();
    expect(status.running).toBe(true);
    expect(status.port).toBe(startResult.port);
    expect(status.recipient).toBe(TEST_RECIPIENT);
    expect(status.chainId).toBe(97);
    expect(status.totalSales).toBe(0);
    expect(status.totalRevenue).toBe('0');
    expect(status.activeEndpoints).toContain('/api/v1/tools/weather');
    expect(status.activeEndpoints).toContain('/api/v1/tools/analyze');

    await server.stop();
    expect(server.isRunning()).toBe(false);
    expect(server.getStatus().running).toBe(false);
  });

  it('handles CORS and OPTIONS preflight requests', async () => {
    const { port } = await server.start();

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'OPTIONS',
    });

    expect(res.statusCode).toBe(204);
    expect(res.headers['access-control-allow-origin']).toBe('*');
    expect(res.headers['access-control-allow-methods']).toContain('GET');
    expect(res.headers['access-control-allow-headers']).toContain('Authorization');
  });

  it('returns 404 for unknown endpoints', async () => {
    const { port } = await server.start();

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/unknown-endpoint',
      method: 'GET',
    });

    expect(res.statusCode).toBe(404);
    expect(res.body.error).toMatch(/not found/i);
  });

  it('returns 402 Payment Required challenge on unauthenticated request', async () => {
    const { port } = await server.start();

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'GET',
    });

    expect(res.statusCode).toBe(402);
    expect(res.headers['www-authenticate']).toBeDefined();
    const authHeader = res.headers['www-authenticate'] as string;
    expect(authHeader).toContain('x402');
    expect(authHeader).toContain('token="tBNB"');
    expect(authHeader).toContain('amount="0.001"');
    expect(authHeader).toContain(`recipient="${TEST_RECIPIENT}"`);
    expect(authHeader).toContain('chainId="97"');

    expect(res.body.error).toBe('Payment Required');
    expect(res.body.x402).toBeDefined();
    expect(res.body.x402.amount).toBe('0.001');
    expect(res.body.x402.recipient).toBe(TEST_RECIPIENT);
  });

  it('rejects replayed transactions with 403 Forbidden', async () => {
    const { port } = await server.start();

    // Pre-record txHash in replay store
    await server.getReplayStore().record({
      txHash: TEST_TX_HASH,
      payer: TEST_PAYER,
      recipient: TEST_RECIPIENT,
      amount: '0.001',
      token: 'tBNB',
      chainId: 97,
      endpoint: '/api/v1/tools/weather',
      timestamp: Date.now(),
    });

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(res.statusCode).toBe(403);
    expect(res.body.error).toMatch(/already redeemed|replay/i);
  });

  it('rejects unmined or non-existent transaction hash with 402/400', async () => {
    const { port } = await server.start();

    mockProvider.getTransactionReceipt.mockResolvedValue(null);
    mockProvider.getTransaction.mockResolvedValue(null);

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(res.statusCode).toBe(402);
    expect(res.body.error).toMatch(/not found|not mined/i);
  });

  it('rejects reverted transaction with 402/400', async () => {
    const { port } = await server.start();

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 0, // Reverted
      blockNumber: 123456,
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.001'),
    });

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(res.statusCode).toBe(402);
    expect(res.body.error).toMatch(/reverted|failed/i);
  });

  it('rejects transaction with wrong recipient', async () => {
    const { port } = await server.start();

    const wrongRecipient = '0x9999999999999999999999999999999999999999';

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123456,
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: wrongRecipient,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: wrongRecipient,
      value: parseEther('0.001'),
    });

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(res.statusCode).toBe(402);
    expect(res.body.error).toMatch(/recipient/i);
  });

  it('rejects transaction with insufficient paid amount', async () => {
    const { port } = await server.start();

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123456,
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.0001'), // Required is 0.001
    });

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(res.statusCode).toBe(402);
    expect(res.body.error).toMatch(/insufficient|amount/i);
  });

  it('verifies valid settlement, records replay protection, updates metrics, and returns 200 payload', async () => {
    const { port } = await server.start();

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123456,
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: TEST_TX_HASH,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.001'),
    });

    const res = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather?city=Paris',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(res.statusCode).toBe(200);
    expect(res.body.city).toBe('Paris');
    expect(res.body.condition).toBeDefined();

    // Verify replay protection is recorded
    expect(await server.getReplayStore().has(TEST_TX_HASH)).toBe(true);

    // Verify sales metrics updated
    const sales = server.getSalesHistory();
    expect(sales.length).toBe(1);
    expect(sales[0].txHash).toBe(TEST_TX_HASH);
    expect(sales[0].payer).toBe(TEST_PAYER);
    expect(sales[0].recipient).toBe(TEST_RECIPIENT);
    expect(sales[0].amount).toBe('0.001');
    expect(sales[0].status).toBe('settled');

    const status = server.getStatus();
    expect(status.totalSales).toBe(1);
    expect(status.totalRevenue).toBe('0.001');

    // Immediate replay attempt must now fail with 403 Forbidden
    const replayRes = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/weather?city=Paris',
      method: 'GET',
      headers: {
        Authorization: `x402 ${TEST_TX_HASH}`,
      },
    });

    expect(replayRes.statusCode).toBe(403);
    expect(replayRes.body.error).toMatch(/already redeemed|replay/i);
  });

  it('supports custom endpoint registration with custom price and handler', async () => {
    server.registerEndpoint(
      '/api/v1/tools/custom-echo',
      async (req, body) => {
        return { custom: true, received: body };
      },
      '0.005'
    );

    const { port } = await server.start();

    // 1. Unauthenticated challenge gives custom price
    const challengeRes = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/custom-echo',
      method: 'POST',
      body: { message: 'hello' },
    });

    expect(challengeRes.statusCode).toBe(402);
    expect(challengeRes.headers['www-authenticate']).toContain('amount="0.005"');

    // 2. Paid request with 0.005 settles and returns handler output
    const customTx = '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123458,
      hash: customTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: customTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.005'),
    });

    const paidRes = await makeHttpRequest(
      {
        hostname: '127.0.0.1',
        port,
        path: '/api/v1/tools/custom-echo',
        method: 'POST',
        headers: {
          Authorization: `x402 ${customTx}`,
        },
      },
      { message: 'hello world' }
    );

    expect(paidRes.statusCode).toBe(200);
    expect(paidRes.body.custom).toBe(true);
    expect(paidRes.body.received).toEqual({ message: 'hello world' });
    expect(server.getStatus().totalRevenue).toBe('0.005');
  });

  it('enforces idempotency by returning cached handler response without executing it twice on retry', async () => {
    let executionCount = 0;
    server.registerEndpoint(
      '/api/v1/tools/idempotent-test',
      async () => {
        executionCount += 1;
        return { count: executionCount };
      },
      '0.001'
    );

    const { port } = await server.start();
    const testTx = '0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123459,
      hash: testTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: testTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.001'),
    });

    const res1 = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/idempotent-test',
      method: 'GET',
      headers: {
        Authorization: `x402 ${testTx}`,
      },
    });

    expect(res1.statusCode).toBe(200);
    expect(res1.body.count).toBe(1);
    expect(executionCount).toBe(1);

    const res2 = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/idempotent-test',
      method: 'GET',
      headers: {
        Authorization: `x402 ${testTx}`,
      },
    });

    expect(res2.statusCode).toBe(403); // Replay must be blocked
    expect(executionCount).toBe(1); // Handler must NOT execute twice
  });

  it('enforces fail-closed protection by blocking retry with 403 when the first handler execution fails', async () => {
    let executionCount = 0;

    server.registerEndpoint(
      '/api/v1/tools/retry-block-test',
      async () => {
        executionCount += 1;
        throw new Error('Transient error');
      },
      '0.001'
    );

    const { port } = await server.start();
    const testTx = '0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123460,
      hash: testTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: testTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.001'),
    });

    // First request fails
    const res1 = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/retry-block-test',
      method: 'GET',
      headers: {
        Authorization: `x402 ${testTx}`,
      },
    });

    expect(res1.statusCode).toBe(500);
    expect(executionCount).toBe(1);

    // Second request with same hash must be blocked with 403
    const res2 = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/retry-block-test',
      method: 'GET',
      headers: {
        Authorization: `x402 ${testTx}`,
      },
    });

    expect(res2.statusCode).toBe(403);
    expect(executionCount).toBe(1);
  });

  it('enforces fail-closed protection when updateStatus completed persistence fails', async () => {
    let executionCount = 0;

    server.registerEndpoint(
      '/api/v1/tools/persistence-fail-test',
      async () => {
        executionCount += 1;
        return { success: true };
      },
      '0.001'
    );

    const { port } = await server.start();
    const testTx = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

    mockProvider.getTransactionReceipt.mockResolvedValue({
      status: 1,
      blockNumber: 123461,
      hash: testTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
    });
    mockProvider.getTransaction.mockResolvedValue({
      hash: testTx,
      from: TEST_PAYER,
      to: TEST_RECIPIENT,
      value: parseEther('0.001'),
    });

    // Mock updateStatus agar melempar error
    const originalUpdate = server.getReplayStore().updateStatus;
    server.getReplayStore().updateStatus = vi.fn().mockRejectedValue(new Error('Disk write failure'));

    // Request pertama -> mengembalikan 500
    const res1 = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/persistence-fail-test',
      method: 'GET',
      headers: {
        Authorization: `x402 ${testTx}`,
      },
    });

    expect(res1.statusCode).toBe(500);
    expect(executionCount).toBe(1);

    // Kembalikan method asli
    server.getReplayStore().updateStatus = originalUpdate;

    // Request kedua -> Harus ditolak dengan 409
    const res2 = await makeHttpRequest({
      hostname: '127.0.0.1',
      port,
      path: '/api/v1/tools/persistence-fail-test',
      method: 'GET',
      headers: {
        Authorization: `x402 ${testTx}`,
      },
    });

    expect(res2.statusCode).toBe(409);
    expect(executionCount).toBe(1);
  });
});
