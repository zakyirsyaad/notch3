/**
 * Utility functions for secret redaction in logging and error outputs.
 * Ensures private keys, seed phrases, and credentials are never leaked.
 */

// Regex for 64-character hex strings (private keys), with or without 0x prefix
const HEX_64_PREFIX_REGEX = /\b0x[0-9a-fA-F]{64}\b/g;
const HEX_64_RAW_REGEX = /\b[0-9a-fA-F]{64}\b/g;

// Regex for 12 to 24 word mnemonic seed phrases (lowercase alphabetic words separated by spaces)
const MNEMONIC_SEED_REGEX = /\b([a-z]{3,10}\s+){11,23}[a-z]{3,10}\b/gi;

// Regex for API Keys (OpenAI style sk-..., Bearer tokens, etc.)
const API_KEY_SK_REGEX = /\bsk-[a-zA-Z0-9_\-]{16,}\b/g;
const BEARER_TOKEN_REGEX = /\bBearer\s+[a-zA-Z0-9_\-\.]{10,}\b/gi;

// Sensitive property keys in objects
const SENSITIVE_KEYS = new Set([
  'privatekey',
  'private_key',
  'seedphrase',
  'seed_phrase',
  'mnemonic',
  'password',
  'secret',
  'apikey',
  'api_key',
  'accesstoken',
  'access_token',
  'refreshtoken',
  'refresh_token',
  'authorization',
]);

/**
 * Recursively redacts sensitive values from an object, array, or primitive.
 */
function sanitizeValue(value: unknown, seen = new WeakSet()): unknown {
  if (value === null || value === undefined) {
    return value;
  }

  if (typeof value === 'string') {
    return applyStringRedactions(value);
  }

  if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
    return value;
  }

  if (typeof value === 'object') {
    if (seen.has(value as object)) {
      return '[CIRCULAR]';
    }
    seen.add(value as object);

    if (Array.isArray(value)) {
      return value.map((item) => sanitizeValue(item, seen));
    }

    const sanitizedObj: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const normalizedKey = k.toLowerCase().replace(/[^a-z0-9]/g, '');
      if (SENSITIVE_KEYS.has(normalizedKey)) {
        sanitizedObj[k] = '[REDACTED_SECRET]';
      } else {
        sanitizedObj[k] = sanitizeValue(v, seen);
      }
    }
    return sanitizedObj;
  }

  return String(value);
}

/**
 * Applies pattern-based redactions to a raw string.
 */
function applyStringRedactions(text: string): string {
  let result = text;

  // Redact 0x-prefixed 64-character hex keys first
  result = result.replace(HEX_64_PREFIX_REGEX, '[REDACTED_KEY]');
  // Redact raw 64-character hex keys
  result = result.replace(HEX_64_RAW_REGEX, '[REDACTED_KEY]');

  // Redact Bearer tokens
  result = result.replace(BEARER_TOKEN_REGEX, 'Bearer [REDACTED_SECRET]');
  // Redact sk-... API keys
  result = result.replace(API_KEY_SK_REGEX, '[REDACTED_SECRET]');

  // Redact 12-24 word seed phrases
  result = result.replace(MNEMONIC_SEED_REGEX, (match) => {
    const wordCount = match.trim().split(/\s+/).length;
    if (wordCount >= 12 && wordCount <= 24) {
      return '[REDACTED_SEED]';
    }
    return match;
  });

  return result;
}

/**
 * Sanitizes and redacts secrets from any message, string, or object.
 */
export function redactSecrets(input: unknown): string {
  if (typeof input === 'string') {
    return applyStringRedactions(input);
  }

  const sanitized = sanitizeValue(input);
  if (typeof sanitized === 'string') {
    return sanitized;
  }

  try {
    return JSON.stringify(sanitized);
  } catch {
    return applyStringRedactions(String(input));
  }
}

/**
 * Writes safe, redacted log messages to stderr (never stdout).
 */
export function safeLog(
  level: 'debug' | 'info' | 'warn' | 'error',
  message: unknown,
  ...args: unknown[]
): void {
  const timestamp = new Date().toISOString();
  const formattedMsg = redactSecrets(message);
  const formattedArgs = args.length > 0 ? ' ' + args.map((a) => redactSecrets(a)).join(' ') : '';
  const line = `[${timestamp}] [${level.toUpperCase()}] ${formattedMsg}${formattedArgs}\n`;
  process.stderr.write(line);
}
