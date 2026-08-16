import {
  JSONRPC_ERROR_CODES,
  createJSONRPCSuccessResponse,
  createJSONRPCErrorResponse,
  isJSONRPCRequest,
  isJSONRPCNotification,
} from '@notch/shared-types';
import { safeLog } from '../utils/redact.js';

export class RPCError extends Error {
  public readonly code: number;
  public readonly data?: unknown;

  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = 'RPCError';
    this.code = code;
    this.data = data;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

export type RPCHandler<TParams = unknown, TResult = unknown> = (
  params: TParams
) => Promise<TResult> | TResult;

export class RPCDispatcher {
  private readonly methods = new Map<string, RPCHandler<any, any>>();

  /**
   * Registers an RPC method handler.
   */
  public registerMethod<TParams = unknown, TResult = unknown>(
    name: string,
    handler: RPCHandler<TParams, TResult>
  ): void {
    if (!name || typeof name !== 'string') {
      throw new Error('Method name must be a non-empty string');
    }
    this.methods.set(name, handler);
  }

  /**
   * Unregisters an RPC method by name.
   */
  public unregisterMethod(name: string): void {
    this.methods.delete(name);
  }

  /**
   * Checks whether a method handler is registered.
   */
  public hasMethod(name: string): boolean {
    return this.methods.has(name);
  }

  /**
   * Handles an incoming JSON-RPC raw message or parsed object.
   * Returns stringified JSON-RPC response, or null if the message is a notification.
   */
  public async handleMessage(rawMessage: string | Record<string, unknown>): Promise<string | null> {
    let payload: unknown;

    if (typeof rawMessage === 'string') {
      try {
        payload = JSON.parse(rawMessage);
      } catch (err) {
        return JSON.stringify(
          createJSONRPCErrorResponse(null, JSONRPC_ERROR_CODES.PARSE_ERROR, 'Parse error')
        );
      }
    } else {
      payload = rawMessage;
    }

    if (typeof payload !== 'object' || payload === null) {
      return JSON.stringify(
        createJSONRPCErrorResponse(null, JSONRPC_ERROR_CODES.INVALID_REQUEST, 'Invalid Request')
      );
    }

    // Handle Notification (no response expected)
    if (isJSONRPCNotification(payload)) {
      const handler = this.methods.get(payload.method);
      if (handler) {
        try {
          await handler(payload.params);
        } catch (err) {
          safeLog('warn', `Error handling notification '${payload.method}':`, err);
        }
      }
      return null;
    }

    // Handle Request
    if (isJSONRPCRequest(payload)) {
      const handler = this.methods.get(payload.method);
      if (!handler) {
        return JSON.stringify(
          createJSONRPCErrorResponse(
            payload.id,
            JSONRPC_ERROR_CODES.METHOD_NOT_FOUND,
            `Method '${payload.method}' not found`
          )
        );
      }

      try {
        const result = await handler(payload.params);
        return JSON.stringify(createJSONRPCSuccessResponse(payload.id, result));
      } catch (err) {
        if (err instanceof RPCError) {
          return JSON.stringify(
            createJSONRPCErrorResponse(payload.id, err.code, err.message, err.data)
          );
        }

        const message = err instanceof Error ? err.message : 'Internal error';
        safeLog('error', `RPC handler exception on '${payload.method}':`, err);
        return JSON.stringify(
          createJSONRPCErrorResponse(payload.id, JSONRPC_ERROR_CODES.INTERNAL_ERROR, message)
        );
      }
    }

    // Invalid JSON-RPC structure
    const candidateId =
      typeof (payload as any).id === 'string' ||
      typeof (payload as any).id === 'number' ||
      (payload as any).id === null
        ? (payload as any).id
        : null;

    return JSON.stringify(
      createJSONRPCErrorResponse(candidateId, JSONRPC_ERROR_CODES.INVALID_REQUEST, 'Invalid Request')
    );
  }
}
