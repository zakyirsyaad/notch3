import * as readline from 'node:readline';
import { createJSONRPCNotification, JSONRPCResponse } from '@notch/shared-types';
import { RPCDispatcher } from './dispatcher.js';
import { safeLog } from '../utils/redact.js';

export interface RPCTransportOptions {
  input?: NodeJS.ReadableStream;
  output?: NodeJS.WritableStream;
  dispatcher: RPCDispatcher;
}

export class RPCTransport {
  private readonly input: NodeJS.ReadableStream;
  private readonly output: NodeJS.WritableStream;
  private readonly dispatcher: RPCDispatcher;
  private rl: readline.Interface | null = null;
  private isRunning = false;

  constructor(options: RPCTransportOptions) {
    this.input = options.input ?? process.stdin;
    this.output = options.output ?? process.stdout;
    this.dispatcher = options.dispatcher;
  }

  /**
   * Starts listening for newline-delimited JSON-RPC messages on the input stream.
   */
  public start(): void {
    if (this.isRunning) {
      return;
    }

    this.isRunning = true;
    this.rl = readline.createInterface({
      input: this.input,
      terminal: false,
      crlfDelay: Infinity,
    });

    this.rl.on('line', async (line: string) => {
      const trimmed = line.trim();
      if (!trimmed) {
        return;
      }

      try {
        const response = await this.dispatcher.handleMessage(trimmed);
        if (response !== null && this.isRunning) {
          this.writeOutput(response);
        }
      } catch (err) {
        safeLog('error', 'Unhandled error processing incoming RPC message:', err);
      }
    });

    this.rl.on('close', () => {
      this.isRunning = false;
      this.rl = null;
    });
  }

  /**
   * Stops listening and cleans up the readline interface.
   */
  public stop(): void {
    if (!this.isRunning) {
      return;
    }

    this.isRunning = false;
    if (this.rl) {
      this.rl.close();
      this.rl = null;
    }
  }

  /**
   * Sends a JSON-RPC 2.0 Notification to the output stream.
   */
  public sendNotification(method: string, params?: unknown): void {
    const notif = createJSONRPCNotification(method, params);
    this.writeOutput(JSON.stringify(notif));
  }

  /**
   * Sends a JSON-RPC 2.0 Response directly to the output stream.
   */
  public sendResponse(response: JSONRPCResponse | string): void {
    const str = typeof response === 'string' ? response : JSON.stringify(response);
    this.writeOutput(str);
  }

  private writeOutput(content: string): void {
    this.output.write(content + '\n');
  }
}
