/**
 * MPP (Machine Payment Protocol) HTTP 402 Server
 * Lightweight embedded Node.js HTTP server implementing Agent Maker Mode
 * with on-chain settlement verification and durable replay protection.
 */

import http from 'node:http';
import { parseEther, formatEther, ZeroAddress } from 'ethers';
import type {
  MPPServerConfig,
  MPPServerStatus,
  MPPSaleReceipt,
} from '@notch/shared-types';
import { MPPReplayStore } from './replay-store.js';
import { getBSCProvider } from '../bnb/provider.js';
import { safeLog } from '../utils/redact.js';

export type EndpointHandler = (
  req: http.IncomingMessage,
  body?: any,
  query?: Record<string, string>
) => Promise<any> | any;

export interface EndpointDefinition {
  path: string;
  handler: EndpointHandler;
  price?: string;
}

export interface MPPServerOptions extends MPPServerConfig {
  provider?: any;
  replayStore?: MPPReplayStore;
}

export class MPPServer {
  private config: MPPServerConfig;
  private provider: any;
  private replayStore: MPPReplayStore;
  private server: http.Server | null = null;
  private running: boolean = false;
  private actualPort?: number;
  private startTime?: number;
  private salesHistory: MPPSaleReceipt[] = [];
  private totalSales: number = 0;
  private totalRevenue: string = '0';
  private endpoints: Map<string, EndpointDefinition> = new Map();

  constructor(options: MPPServerOptions = {}) {
    this.config = {
      port: options.port ?? 3402,
      host: options.host ?? '127.0.0.1',
      recipient: options.recipient || ZeroAddress,
      chainId: options.chainId ?? 97,
      defaultPrice: options.defaultPrice ?? '0.001',
      token: options.token ?? 'tBNB',
      replayStorePath: options.replayStorePath,
      allowedEndpoints: options.allowedEndpoints,
    };

    this.provider = options.provider;
    this.replayStore =
      options.replayStore ||
      new MPPReplayStore({ storePath: this.config.replayStorePath });

    this.registerDefaultEndpoints();
  }

  private registerDefaultEndpoints(): void {
    // 1. Weather Tool Endpoint
    this.registerEndpoint(
      '/api/v1/tools/weather',
      async (_req, _body, query) => {
        const city = query?.city || 'BNB City';
        return {
          tool: 'weather',
          city,
          temp: '25°C',
          condition: 'Sunny',
          humidity: '45%',
          timestamp: Date.now(),
        };
      },
      this.config.defaultPrice
    );

    // 2. Analyze Tool Endpoint
    this.registerEndpoint(
      '/api/v1/tools/analyze',
      async (_req, body, query) => {
        const target = body?.target || query?.target || 'BNB Ecosystem';
        return {
          tool: 'analyze',
          target,
          analyzed: true,
          sentiment: 'Bullish',
          summary: 'High transaction activity and low fees observed on BSC Testnet.',
          confidence: 0.94,
          timestamp: Date.now(),
        };
      },
      this.config.defaultPrice
    );

    // 3. Status Tool Endpoint
    this.registerEndpoint(
      '/api/v1/tools/status',
      async () => {
        return {
          tool: 'status',
          status: 'operational',
          version: '0.1.0',
          timestamp: Date.now(),
        };
      },
      this.config.defaultPrice
    );
  }

  /**
   * Registers or overrides a tool endpoint on the MPP server.
   */
  registerEndpoint(path: string, handler: EndpointHandler, price?: string): void {
    const normalizedPath = path.startsWith('/') ? path : `/${path}`;
    this.endpoints.set(normalizedPath, {
      path: normalizedPath,
      handler,
      price: price || this.config.defaultPrice || '0.001',
    });
  }

  /**
   * Sets or updates the recipient Agent Wallet address.
   */
  setRecipient(recipient: string): void {
    this.config.recipient = recipient;
  }

  /**
   * Replaces the provider used for on-chain settlement verification.
   * Call after a network switch so payments are verified on the active chain.
   */
  setProvider(provider: any): void {
    this.provider = provider;
  }

  /**
   * Updates the chain ID advertised in payment challenges.
   */
  setChainId(chainId: number): void {
    this.config.chainId = chainId;
  }

  /**
   * Returns the underlying replay protection store.
   */
  getReplayStore(): MPPReplayStore {
    return this.replayStore;
  }

  /**
   * Checks if the server is currently active.
   */
  isRunning(): boolean {
    return this.running;
  }

  /**
   * Returns the actual listening port if running.
   */
  getPort(): number | undefined {
    return this.actualPort;
  }

  /**
   * Starts the HTTP server on configured or specified port.
   */
  async start(port?: number): Promise<{ port: number; host: string }> {
    if (this.running && this.server && this.actualPort) {
      return { port: this.actualPort, host: this.config.host || '127.0.0.1' };
    }

    const listenPort = port !== undefined ? port : this.config.port ?? 3402;
    const listenHost = this.config.host || '127.0.0.1';

    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => {
        this.handleRequest(req, res).catch((err) => {
          safeLog('error', 'Unhandled MPP request error:', err);
          if (!res.headersSent) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
          }
          res.end(JSON.stringify({ error: 'Internal server error' }));
        });
      });

      this.server.on('error', (err) => {
        reject(err);
      });

      this.server.listen(listenPort, listenHost, () => {
        const address = this.server?.address();
        if (address && typeof address === 'object') {
          this.actualPort = address.port;
        } else {
          this.actualPort = listenPort;
        }

        this.running = true;
        this.startTime = Date.now();
        resolve({ port: this.actualPort, host: listenHost });
      });
    });
  }

  /**
   * Stops the HTTP server.
   */
  async stop(): Promise<{ stopped: boolean }> {
    if (!this.running || !this.server) {
      this.running = false;
      return { stopped: true };
    }

    return new Promise((resolve, reject) => {
      this.server?.close((err) => {
        if (err) {
          reject(err);
        } else {
          this.running = false;
          this.server = null;
          this.actualPort = undefined;
          resolve({ stopped: true });
        }
      });
    });
  }

  /**
   * Returns runtime server status and metrics.
   */
  getStatus(): MPPServerStatus {
    return {
      running: this.running,
      port: this.actualPort || this.config.port,
      host: this.config.host || '127.0.0.1',
      recipient: this.config.recipient,
      chainId: this.config.chainId || 97,
      totalSales: this.totalSales,
      totalRevenue: this.totalRevenue,
      uptime:
        this.running && this.startTime
          ? Math.floor((Date.now() - this.startTime) / 1000)
          : 0,
      activeEndpoints: Array.from(this.endpoints.keys()),
    };
  }

  /**
   * Returns list of settled sales receipts.
   */
  getSalesHistory(): MPPSaleReceipt[] {
    return [...this.salesHistory];
  }

  private async parseRequestBody(req: http.IncomingMessage): Promise<any> {
    return new Promise((resolve) => {
      let body = '';
      req.on('data', (chunk) => {
        body += chunk;
        if (body.length > 1e6) {
          req.destroy();
        }
      });

      req.on('end', () => {
        if (!body.trim()) {
          resolve(undefined);
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch {
          resolve(body);
        }
      });

      req.on('error', () => {
        resolve(undefined);
      });
    });
  }

  private extractTxHash(req: http.IncomingMessage): string | null {
    const customHeader = req.headers['x-402-txhash'];
    if (typeof customHeader === 'string' && customHeader.trim().startsWith('0x')) {
      return customHeader.trim();
    }

    const auth = req.headers['authorization'];
    if (!auth || typeof auth !== 'string') {
      return null;
    }

    const trimmed = auth.trim();
    if (/^x402\s+/i.test(trimmed)) {
      return trimmed.replace(/^x402\s+/i, '').trim();
    }
    if (/^Bearer\s+x402\s+/i.test(trimmed)) {
      return trimmed.replace(/^Bearer\s+x402\s+/i, '').trim();
    }
    if (/^Bearer\s+0x[0-9a-fA-F]{64}$/i.test(trimmed)) {
      return trimmed.replace(/^Bearer\s+/i, '').trim();
    }

    return null;
  }

  private sendJson(res: http.ServerResponse, statusCode: number, data: any, extraHeaders?: http.OutgoingHttpHeaders): void {
    res.writeHead(statusCode, {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-402-TxHash, WWW-Authenticate',
      'Access-Control-Expose-Headers': 'WWW-Authenticate, X-402-TxHash',
      ...extraHeaders,
    });
    res.end(JSON.stringify(data));
  }

  private async handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    // 1. CORS Preflight
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-402-TxHash, WWW-Authenticate',
        'Access-Control-Expose-Headers': 'WWW-Authenticate, X-402-TxHash',
      });
      res.end();
      return;
    }

    const parsedUrl = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);
    const pathname = parsedUrl.pathname;
    const query = Object.fromEntries(parsedUrl.searchParams.entries());

    // 2. Lookup registered endpoint
    const endpointDef = this.endpoints.get(pathname);
    if (!endpointDef) {
      this.sendJson(res, 404, {
        error: 'Not Found',
        message: `Endpoint ${pathname} not found`,
      });
      return;
    }

    const price = endpointDef.price || this.config.defaultPrice || '0.001';
    const recipient = this.config.recipient || ZeroAddress;
    const token = this.config.token || 'tBNB';
    const chainId = this.config.chainId || 97;

    // 3. Extract transaction hash proof
    const txHash = this.extractTxHash(req);

    if (!txHash) {
      // 402 Payment Required Challenge
      const challengeHeader = `x402 token="${token}", amount="${price}", recipient="${recipient}", chainId="${chainId}", resource="${pathname}"`;
      this.sendJson(
        res,
        402,
        {
          error: 'Payment Required',
          code: 402,
          x402: {
            token,
            amount: price,
            recipient,
            chainId,
            endpoint: pathname,
          },
        },
        {
          'WWW-Authenticate': challengeHeader,
        }
      );
      return;
    }

    // 4. Replay Protection Check
    const isReplay = await this.replayStore.has(txHash);
    if (isReplay) {
      this.sendJson(res, 403, {
        error: 'Payment already redeemed (replay detected)',
        code: 403,
        txHash,
      });
      return;
    }

    // 5. On-Chain Settlement Verification
    const provider = this.provider || getBSCProvider();

    let receipt: any;
    let tx: any;

    try {
      [receipt, tx] = await Promise.all([
        provider.getTransactionReceipt(txHash),
        provider.getTransaction(txHash),
      ]);
    } catch (err: any) {
      this.sendJson(res, 402, {
        error: `Failed to query transaction on chain: ${err?.message || String(err)}`,
        code: 402,
        txHash,
      });
      return;
    }

    if (!receipt || !tx) {
      this.sendJson(res, 402, {
        error: 'Transaction not found or not yet mined',
        code: 402,
        txHash,
      });
      return;
    }

    if (receipt.status !== 1) {
      this.sendJson(res, 402, {
        error: 'Transaction execution failed or reverted',
        code: 402,
        txHash,
      });
      return;
    }

    // Check the transaction was mined on the expected chain
    if (tx.chainId !== undefined && tx.chainId !== null && Number(tx.chainId) !== chainId) {
      this.sendJson(res, 402, {
        error: `Transaction chain mismatch: expected chainId ${chainId}, got ${Number(tx.chainId)}`,
        code: 402,
        txHash,
      });
      return;
    }

    // Check recipient
    const actualRecipient = (tx.to || receipt.to || '').toLowerCase();
    if (actualRecipient !== recipient.toLowerCase()) {
      this.sendJson(res, 402, {
        error: `Transaction recipient mismatch: expected ${recipient}, got ${tx.to || receipt.to}`,
        code: 402,
        txHash,
      });
      return;
    }

    // Check amount
    let requiredAmountWei: bigint;
    let actualAmountWei: bigint;
    try {
      requiredAmountWei = parseEther(price);
      actualAmountWei = tx.value !== undefined ? BigInt(tx.value) : 0n;
    } catch {
      this.sendJson(res, 500, {
        error: `Invalid configured price "${price}": cannot parse as ether amount`,
      });
      return;
    }

    if (actualAmountWei < requiredAmountWei) {
      this.sendJson(res, 402, {
        error: `Insufficient payment amount: expected at least ${price} ${token}, got ${formatEther(actualAmountWei)}`,
        code: 402,
        txHash,
      });
      return;
    }

    // 6. Settle and Record Replay
    const payer = tx.from || receipt.from || ZeroAddress;

    await this.replayStore.record({
      txHash,
      payer,
      recipient,
      amount: price,
      token,
      chainId,
      endpoint: pathname,
      timestamp: Date.now(),
      blockNumber: receipt.blockNumber,
    });

    const saleRecord: MPPSaleReceipt = {
      txHash,
      payer,
      recipient,
      amount: price,
      token,
      chainId,
      endpoint: pathname,
      timestamp: Date.now(),
      blockNumber: receipt.blockNumber,
      status: 'settled',
    };

    this.salesHistory.push(saleRecord);
    this.totalSales += 1;

    try {
      const currentRevWei = parseEther(this.totalRevenue || '0');
      const addedRevWei = parseEther(price || '0');
      this.totalRevenue = formatEther(currentRevWei + addedRevWei);
    } catch {
      this.totalRevenue = (parseFloat(this.totalRevenue || '0') + parseFloat(price || '0')).toString();
    }

    // 7. Execute handler and return 200 OK
    try {
      const body = await this.parseRequestBody(req);
      const result = await endpointDef.handler(req, body, query);
      this.sendJson(res, 200, result);
    } catch (err: any) {
      this.sendJson(res, 500, {
        error: 'Internal handler error',
        message: err?.message || String(err),
      });
    }
  }
}
