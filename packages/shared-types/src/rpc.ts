/**
 * JSON-RPC 2.0 Specification Protocol Types and Type Guards
 * @see https://www.jsonrpc.org/specification
 */

export type JSONRPCId = string | number | null;

export interface JSONRPCRequest<T = unknown> {
  jsonrpc: '2.0';
  id: JSONRPCId;
  method: string;
  params?: T;
}

export interface JSONRPCNotification<T = unknown> {
  jsonrpc: '2.0';
  method: string;
  params?: T;
}

export interface JSONRPCError<D = unknown> {
  code: number;
  message: string;
  data?: D;
}

export interface JSONRPCSuccessResponse<T = unknown> {
  jsonrpc: '2.0';
  id: JSONRPCId;
  result: T;
  error?: never;
}

export interface JSONRPCErrorResponse<D = unknown> {
  jsonrpc: '2.0';
  id: JSONRPCId;
  result?: never;
  error: JSONRPCError<D>;
}

export type JSONRPCResponse<T = unknown, D = unknown> =
  | JSONRPCSuccessResponse<T>
  | JSONRPCErrorResponse<D>;

export type JSONRPCMessage =
  | JSONRPCRequest
  | JSONRPCNotification
  | JSONRPCResponse;

/** Standard JSON-RPC 2.0 and Application Error Codes */
export const JSONRPC_ERROR_CODES = {
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL_ERROR: -32603,
  SERVER_ERROR_START: -32000,
  SERVER_ERROR_END: -32099,
  // Application-level error codes
  UNAUTHORIZED: -32001,
  WALLET_LOCKED: -32002,
  INSUFFICIENT_FUNDS: -32003,
  PAYMENT_FAILED: -32004,
  RATE_LIMITED: -32005,
} as const;

export type JSONRPCErrorCode =
  | (typeof JSONRPC_ERROR_CODES)[keyof typeof JSONRPC_ERROR_CODES]
  | number;

function isRecord(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val);
}

function isValidId(id: unknown): id is JSONRPCId {
  return typeof id === 'string' || typeof id === 'number' || id === null;
}

/**
 * Validates whether an unknown payload matches the JSON-RPC 2.0 Request contract.
 */
export function isJSONRPCRequest(val: unknown): val is JSONRPCRequest {
  if (!isRecord(val)) return false;
  if (val['jsonrpc'] !== '2.0') return false;
  if (typeof val['method'] !== 'string') return false;
  if (!('id' in val) || !isValidId(val['id'])) return false;
  if ('params' in val && val['params'] !== undefined) {
    if (typeof val['params'] !== 'object' || val['params'] === null) {
      return false;
    }
  }
  return true;
}

/**
 * Validates whether an unknown payload matches the JSON-RPC 2.0 Notification contract.
 */
export function isJSONRPCNotification(val: unknown): val is JSONRPCNotification {
  if (!isRecord(val)) return false;
  if (val['jsonrpc'] !== '2.0') return false;
  if (typeof val['method'] !== 'string') return false;
  if ('id' in val && val['id'] !== undefined) return false;
  if ('params' in val && val['params'] !== undefined) {
    if (typeof val['params'] !== 'object' || val['params'] === null) {
      return false;
    }
  }
  return true;
}

/**
 * Validates whether an unknown payload matches the JSON-RPC 2.0 Error object structure.
 */
export function isJSONRPCError(val: unknown): val is JSONRPCError {
  if (!isRecord(val)) return false;
  if (typeof val['code'] !== 'number') return false;
  if (typeof val['message'] !== 'string') return false;
  return true;
}

/**
 * Validates whether an unknown payload matches the JSON-RPC 2.0 Response contract (Success or Error).
 */
export function isJSONRPCResponse(val: unknown): val is JSONRPCResponse {
  if (!isRecord(val)) return false;
  if (val['jsonrpc'] !== '2.0') return false;
  if (!('id' in val) || !isValidId(val['id'])) return false;

  const hasResult = 'result' in val && val['result'] !== undefined;
  const hasError = 'error' in val && val['error'] !== undefined;

  // Must have either result or error, but not both or neither
  if (hasResult && hasError) return false;
  if (!hasResult && !hasError) return false;

  if (hasError && !isJSONRPCError(val['error'])) {
    return false;
  }

  return true;
}

/**
 * Factory helper for creating JSON-RPC 2.0 Requests
 */
export function createJSONRPCRequest<T = unknown>(
  id: JSONRPCId,
  method: string,
  params?: T
): JSONRPCRequest<T> {
  const req: JSONRPCRequest<T> = {
    jsonrpc: '2.0',
    id,
    method,
  };
  if (params !== undefined) {
    req.params = params;
  }
  return req;
}

/**
 * Factory helper for creating JSON-RPC 2.0 Notifications
 */
export function createJSONRPCNotification<T = unknown>(
  method: string,
  params?: T
): JSONRPCNotification<T> {
  const notif: JSONRPCNotification<T> = {
    jsonrpc: '2.0',
    method,
  };
  if (params !== undefined) {
    notif.params = params;
  }
  return notif;
}

/**
 * Factory helper for creating successful JSON-RPC 2.0 Responses
 */
export function createJSONRPCSuccessResponse<T = unknown>(
  id: JSONRPCId,
  result: T
): JSONRPCSuccessResponse<T> {
  return {
    jsonrpc: '2.0',
    id,
    result,
  };
}

/**
 * Factory helper for creating JSON-RPC 2.0 Error Responses
 */
export function createJSONRPCErrorResponse<D = unknown>(
  id: JSONRPCId,
  code: number,
  message: string,
  data?: D
): JSONRPCErrorResponse<D> {
  const error: JSONRPCError<D> = { code, message };
  if (data !== undefined) {
    error.data = data;
  }
  return {
    jsonrpc: '2.0',
    id,
    error,
  };
}
