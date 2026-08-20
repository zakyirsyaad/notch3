/**
 * Validation for OpenAI-compatible provider settings.
 *
 * Local HTTP endpoints are supported for keyless providers. Remote providers
 * must use HTTPS so API traffic is not sent over a clear-text connection.
 */

export interface ProviderConfig {
  openaiBaseUrl?: string;
  openaiModel?: string;
}

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '::1']);

function isLoopbackHost(hostname: string): boolean {
  return LOOPBACK_HOSTS.has(hostname.toLowerCase().replace(/^\[|\]$/g, ''));
}

/**
 * Validates the required OpenAI-compatible base URL and model fields.
 *
 * @throws Error when the provider configuration is missing or unsafe.
 */
export function validateProviderConfig(config: ProviderConfig): void {
  if (typeof config.openaiBaseUrl !== 'string' || !config.openaiBaseUrl.trim()) {
    throw new Error('OpenAI-compatible base URL must be non-empty.');
  }

  if (typeof config.openaiModel !== 'string' || !config.openaiModel.trim()) {
    throw new Error('OpenAI-compatible model must be non-empty.');
  }

  let url: URL;
  try {
    url = new URL(config.openaiBaseUrl);
  } catch {
    throw new Error('OpenAI-compatible base URL is malformed.');
  }

  if (url.username || url.password) {
    throw new Error('OpenAI-compatible base URLs must not contain embedded credentials.');
  }

  if (url.search || url.hash) {
    throw new Error(
      'OpenAI-compatible base URLs must not contain query parameters or fragments; store API keys explicitly.'
    );
  }

  if (url.protocol === 'https:') {
    return;
  }

  if (url.protocol === 'http:' && isLoopbackHost(url.hostname)) {
    return;
  }

  if (url.protocol === 'http:') {
    throw new Error(
      'OpenAI-compatible remote base URLs must use HTTPS; HTTP is allowed only for loopback hosts.'
    );
  }

  throw new Error('OpenAI-compatible base URL must use HTTP or HTTPS.');
}
