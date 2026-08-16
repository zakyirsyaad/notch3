/**
 * Mock x402 HTTP Server
 *
 * Implements a lightweight HTTP server issuing 402 Payment Required challenges
 * and validating authorization bearer / x402 payment receipts for end-to-end testing.
 */

import http, { type Server, type IncomingMessage, type ServerResponse } from 'http';
import type { AddressInfo } from 'net';

export interface MockX402ServerOptions {
  token?: string;
  amount?: string;
  recipient?: string;
  chainId?: number;
  resource?: string;
  description?: string;
  nonce?: string;
  responseData?: unknown;
}

export interface MockX402ServerInstance {
  server: Server;
  url: string;
  port: number;
  close: () => Promise<void>;
  getRequestCount: () => number;
  getPaidRequestCount: () => number;
  getLastAuthHeader: () => string | undefined;
}

export const DEFAULT_MOCK_X402_CONFIG = {
  token: 'tBNB',
  amount: '0.001',
  recipient: '0x1111111111111111111111111111111111111111',
  chainId: 97,
  resource: '/api/v1/forecast',
  description: 'Premium AI Forecast Data Access',
  responseData: { success: true, data: 'Premium Forecast Data' },
};

/**
 * Creates an http.Server that returns 402 Payment Required unless a valid
 * payment proof (Bearer 0x..., x402 0x..., or X-402-TxHash) is supplied.
 */
export function createMockX402Server(
  portOrOptions?: number | MockX402ServerOptions,
  options?: MockX402ServerOptions
): Server {
  const opts: MockX402ServerOptions =
    typeof portOrOptions === 'object' && portOrOptions !== null
      ? portOrOptions
      : options || {};

  const token = opts.token ?? DEFAULT_MOCK_X402_CONFIG.token;
  const amount = opts.amount ?? DEFAULT_MOCK_X402_CONFIG.amount;
  const recipient = opts.recipient ?? DEFAULT_MOCK_X402_CONFIG.recipient;
  const chainId = opts.chainId ?? DEFAULT_MOCK_X402_CONFIG.chainId;
  const resource = opts.resource ?? DEFAULT_MOCK_X402_CONFIG.resource;
  const description = opts.description ?? DEFAULT_MOCK_X402_CONFIG.description;
  const nonce = opts.nonce ?? 'mock-nonce-12345';
  const responseData = opts.responseData ?? DEFAULT_MOCK_X402_CONFIG.responseData;

  const challengeHeader = `x402 token="${token}", amount="${amount}", recipient="${recipient}", chainId="${chainId}", resource="${resource}", description="${description}", nonce="${nonce}"`;

  return http.createServer((req: IncomingMessage, res: ServerResponse) => {
    const authHeader = req.headers['authorization'];
    const txHashHeader = req.headers['x-402-txhash'];

    const hasValidAuth =
      (authHeader &&
        (authHeader.startsWith('Bearer 0x') ||
          authHeader.startsWith('x402 0x') ||
          authHeader.startsWith('0x'))) ||
      (typeof txHashHeader === 'string' && txHashHeader.startsWith('0x'));

    if (!hasValidAuth) {
      res.writeHead(402, {
        'WWW-Authenticate': challengeHeader,
        'Content-Type': 'application/json',
      });
      res.end(
        JSON.stringify({
          error: 'Payment Required',
          token,
          amount,
          recipient,
          chainId,
          resource,
          description,
        })
      );
      return;
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(responseData));
  });
}

/**
 * Starts the mock x402 server on an ephemeral or specified port,
 * returning helper methods to query URLs, inspect request counters, and close cleanly.
 */
export async function startMockX402Server(
  portOrOptions?: number | MockX402ServerOptions,
  options?: MockX402ServerOptions
): Promise<MockX402ServerInstance> {
  const targetPort = typeof portOrOptions === 'number' ? portOrOptions : 0;
  const opts = typeof portOrOptions === 'object' ? portOrOptions : options;

  let requestCount = 0;
  let paidRequestCount = 0;
  let lastAuthHeader: string | undefined;

  const server = createMockX402Server(targetPort, opts);

  // Wrap request listener for counter tracking
  const originalListeners = server.listeners('request').slice();
  server.removeAllListeners('request');

  server.on('request', (req: IncomingMessage, res: ServerResponse) => {
    requestCount++;
    const auth = req.headers['authorization'];
    if (auth) {
      lastAuthHeader = Array.isArray(auth) ? auth[0] : auth;
      paidRequestCount++;
    } else if (req.headers['x-402-txhash']) {
      paidRequestCount++;
    }
    for (const listener of originalListeners) {
      (listener as (req: IncomingMessage, res: ServerResponse) => void)(req, res);
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.listen(targetPort, '127.0.0.1', () => resolve());
    server.once('error', reject);
  });

  const address = server.address() as AddressInfo;
  const port = address.port;
  const url = `http://127.0.0.1:${port}`;

  return {
    server,
    url,
    port,
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        server.close((err) => {
          if (err) reject(err);
          else resolve();
        });
      });
    },
    getRequestCount: () => requestCount,
    getPaidRequestCount: () => paidRequestCount,
    getLastAuthHeader: () => lastAuthHeader,
  };
}
