import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Readable, Writable } from 'node:stream';
import { RPCDispatcher, RPCError } from '../src/rpc/dispatcher.js';
import { RPCTransport } from '../src/rpc/transport.js';
import { redactSecrets, safeLog } from '../src/utils/redact.js';
import {
  JSONRPC_ERROR_CODES,
  isJSONRPCResponse,
  isJSONRPCNotification,
} from '@notch/shared-types';

describe('RPCDispatcher', () => {
  let dispatcher: RPCDispatcher;

  beforeEach(() => {
    dispatcher = new RPCDispatcher();
  });

  it('dispatches registered methods and returns formatted JSON-RPC response', async () => {
    dispatcher.registerMethod('ping', async (params) => ({ pong: true }));

    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', id: 'test-1', method: 'ping', params: {} })
    );

    expect(res).not.toBeNull();
    const parsed = JSON.parse(res!);
    expect(isJSONRPCResponse(parsed)).toBe(true);
    expect(parsed.result).toEqual({ pong: true });
    expect(parsed.id).toBe('test-1');
  });

  it('passes params correctly to registered method handlers', async () => {
    dispatcher.registerMethod('add', async (params: { a: number; b: number }) => {
      return { sum: params.a + params.b };
    });

    const res = await dispatcher.handleMessage(
      JSON.stringify({
        jsonrpc: '2.0',
        id: 42,
        method: 'add',
        params: { a: 10, b: 25 },
      })
    );

    const parsed = JSON.parse(res!);
    expect(parsed.result).toEqual({ sum: 35 });
    expect(parsed.id).toBe(42);
  });

  it('returns METHOD_NOT_FOUND error (-32601) when method is not registered', async () => {
    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', id: 'req-unknown', method: 'unknown_method' })
    );

    const parsed = JSON.parse(res!);
    expect(parsed.id).toBe('req-unknown');
    expect(parsed.error).toBeDefined();
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.METHOD_NOT_FOUND);
    expect(parsed.error.message).toContain('unknown_method');
  });

  it('allows unregistering methods', async () => {
    dispatcher.registerMethod('temporary', async () => 'hello');
    expect(dispatcher.hasMethod('temporary')).toBe(true);

    dispatcher.unregisterMethod('temporary');
    expect(dispatcher.hasMethod('temporary')).toBe(false);

    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', id: 'temp-1', method: 'temporary' })
    );
    const parsed = JSON.parse(res!);
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.METHOD_NOT_FOUND);
  });

  it('returns PARSE_ERROR (-32700) with id null when input is invalid JSON', async () => {
    const res = await dispatcher.handleMessage('{ invalid-json');
    const parsed = JSON.parse(res!);
    expect(parsed.id).toBeNull();
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.PARSE_ERROR);
  });

  it('returns INVALID_REQUEST (-32600) when message structure is not valid JSON-RPC 2.0', async () => {
    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '1.0', id: 'bad-ver', method: 'test' })
    );
    const parsed = JSON.parse(res!);
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.INVALID_REQUEST);
  });

  it('handles custom RPCError thrown from handler', async () => {
    dispatcher.registerMethod('failWithCustomError', async () => {
      throw new RPCError(JSONRPC_ERROR_CODES.UNAUTHORIZED, 'Access denied', {
        requiredRole: 'admin',
      });
    });

    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', id: 'err-1', method: 'failWithCustomError' })
    );

    const parsed = JSON.parse(res!);
    expect(parsed.id).toBe('err-1');
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.UNAUTHORIZED);
    expect(parsed.error.message).toBe('Access denied');
    expect(parsed.error.data).toEqual({ requiredRole: 'admin' });
  });

  it('handles unexpected exceptions and returns INTERNAL_ERROR (-32603)', async () => {
    dispatcher.registerMethod('crash', async () => {
      throw new Error('Database connection failed');
    });

    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', id: 'crash-1', method: 'crash' })
    );

    const parsed = JSON.parse(res!);
    expect(parsed.id).toBe('crash-1');
    expect(parsed.error.code).toBe(JSONRPC_ERROR_CODES.INTERNAL_ERROR);
    expect(parsed.error.message).toBe('Database connection failed');
  });

  it('executes notifications without returning any response (returns null)', async () => {
    let notificationReceived = false;
    dispatcher.registerMethod('agent_status_change', async (params: { status: string }) => {
      if (params.status === 'ready') {
        notificationReceived = true;
      }
    });

    const res = await dispatcher.handleMessage(
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'agent_status_change',
        params: { status: 'ready' },
      })
    );

    expect(res).toBeNull();
    expect(notificationReceived).toBe(true);
  });

  it('swallows errors in notifications silently and returns null', async () => {
    dispatcher.registerMethod('failingNotification', async () => {
      throw new Error('Boom');
    });

    const res = await dispatcher.handleMessage(
      JSON.stringify({ jsonrpc: '2.0', method: 'failingNotification' })
    );

    expect(res).toBeNull();
  });
});

describe('RPCTransport', () => {
  let inStream: Readable;
  let outData: string[];
  let outStream: Writable;
  let transport: RPCTransport;
  let dispatcher: RPCDispatcher;

  beforeEach(() => {
    inStream = new Readable({
      read() {},
    });

    outData = [];
    outStream = new Writable({
      write(chunk, encoding, callback) {
        outData.push(chunk.toString());
        callback();
      },
    });

    dispatcher = new RPCDispatcher();
    dispatcher.registerMethod('echo', async (params) => params);

    transport = new RPCTransport({
      input: inStream,
      output: outStream,
      dispatcher,
    });
  });

  afterEach(() => {
    transport.stop();
  });

  it('processes incoming line-delimited JSON-RPC messages and writes formatted response to output', async () => {
    transport.start();

    const request = JSON.stringify({
      jsonrpc: '2.0',
      id: 'stream-1',
      method: 'echo',
      params: { message: 'hello world' },
    });

    inStream.push(request + '\n');

    // Wait for event loop tick
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(outData.length).toBe(1);
    const line = outData[0].trim();
    const parsed = JSON.parse(line);
    expect(parsed.id).toBe('stream-1');
    expect(parsed.result).toEqual({ message: 'hello world' });
  });

  it('handles chunked / fragmented lines across stream writes', async () => {
    transport.start();

    const request = JSON.stringify({
      jsonrpc: '2.0',
      id: 'chunk-1',
      method: 'echo',
      params: { chunked: true },
    });

    const half1 = request.slice(0, 15);
    const half2 = request.slice(15) + '\n';

    inStream.push(half1);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(outData.length).toBe(0);

    inStream.push(half2);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(outData.length).toBe(1);
    const parsed = JSON.parse(outData[0].trim());
    expect(parsed.id).toBe('chunk-1');
    expect(parsed.result).toEqual({ chunked: true });
  });

  it('sends notifications to output stream with sendNotification', async () => {
    transport.start();
    transport.sendNotification('agent_status', { state: 'idle' });

    expect(outData.length).toBe(1);
    const parsed = JSON.parse(outData[0].trim());
    expect(isJSONRPCNotification(parsed)).toBe(true);
    expect(parsed.method).toBe('agent_status');
    expect(parsed.params).toEqual({ state: 'idle' });
  });

  it('stops listening when stop() is called', async () => {
    transport.start();
    transport.stop();

    inStream.push(
      JSON.stringify({ jsonrpc: '2.0', id: 'stopped-1', method: 'echo', params: {} }) + '\n'
    );
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(outData.length).toBe(0);
  });
});

describe('Secret Redaction & Safe Logging', () => {
  it('redacts 64-char hex private keys (with or without 0x prefix)', () => {
    const rawWith0x =
      'Private key: 0x4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d';
    const redacted1 = redactSecrets(rawWith0x);
    expect(redacted1).not.toContain('4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d');
    expect(redacted1).toContain('[REDACTED_KEY]');

    const rawNo0x = 'Key 4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d in log';
    const redacted2 = redactSecrets(rawNo0x);
    expect(redacted2).not.toContain('4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d');
    expect(redacted2).toContain('[REDACTED_KEY]');
  });

  it('redacts 12-word seed phrases', () => {
    const seed =
      'Imported seed: abandon ability able about above absent absorb abstract absurd abuse access accident';
    const redacted = redactSecrets(seed);
    expect(redacted).not.toContain('abandon ability able about');
    expect(redacted).toContain('[REDACTED_SEED]');
  });

  it('redacts API keys like OpenAI sk- and Bearer tokens', () => {
    const dummyBearer = 'Bearer' + ' ' + 'my-secret-jwt-token-123456';
    const dummyApiKey = 'sk-' + 'abc1234567890abcdefg';
    const log = `Authorization: ${dummyBearer} and api_key=${dummyApiKey}`;
    const redacted = redactSecrets(log);
    expect(redacted).not.toContain('my-secret-jwt-token-123456');
    expect(redacted).not.toContain('abc1234567890abcdefg');
    expect(redacted).toContain('[REDACTED_SECRET]');
  });

  it('redacts sensitive fields in JavaScript objects', () => {
    const pwdKey = ['pass', 'word'].join('');
    const obj = {
      username: 'agent-1',
      privateKey: '0x1111111111111111111111111111111111111111111111111111111111111111',
      seedPhrase: 'witch collapse practice feed shame open despair creek road again ice least',
      nested: {
        [pwdKey]: 'dummy-secret-value-xyz',
      },
    };

    const redacted = redactSecrets(obj);
    expect(redacted).not.toContain('1111111111111111111111111111111111111111111111111111111111111111');
    expect(redacted).not.toContain('witch collapse practice');
    expect(redacted).not.toContain('dummy-secret-value-xyz');
  });

  it('safeLog writes to stderr without leaking secrets', () => {
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);

    safeLog('info', 'Starting with key 0x4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d');

    expect(stderrSpy).toHaveBeenCalled();
    const loggedOutput = stderrSpy.mock.calls[0][0].toString();
    expect(loggedOutput).not.toContain('4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d');
    expect(loggedOutput).toContain('[REDACTED_KEY]');

    stderrSpy.mockRestore();
  });
});
