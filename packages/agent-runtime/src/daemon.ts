/**
 * Agent Runtime Daemon Entrypoint
 *
 * Runs the Notch Agent RPC runtime as a long-lived subprocess listening for
 * newline-delimited JSON-RPC 2.0 messages on stdin and answering on stdout.
 * Logs are written to stderr only — stdout is reserved for the RPC stream.
 */

import { createAgentDispatcher } from './index.js';
import { RPCTransport } from './rpc/transport.js';
import { safeLog } from './utils/redact.js';

export function startDaemon(): RPCTransport {
  const dispatcher = createAgentDispatcher();
  const transport = new RPCTransport({
    input: process.stdin,
    output: process.stdout,
    dispatcher,
  });

  transport.start();
  safeLog('info', 'Notch Agent runtime daemon ready — JSON-RPC 2.0 on stdin/stdout');

  process.on('SIGTERM', () => {
    safeLog('info', 'Received SIGTERM — shutting down agent runtime');
    transport.stop();
    process.exit(0);
  });

  process.on('SIGINT', () => {
    transport.stop();
    process.exit(0);
  });

  process.stdin.on('end', () => {
    safeLog('info', 'stdin closed — parent process gone, exiting');
    transport.stop();
    process.exit(0);
  });

  process.on('uncaughtException', (err) => {
    safeLog('error', 'Uncaught exception in agent runtime:', err);
  });

  process.on('unhandledRejection', (reason) => {
    safeLog('error', 'Unhandled rejection in agent runtime:', reason);
  });

  return transport;
}

// Execute directly (node dist/daemon.js), not when imported by tests.
if (process.argv[1] && process.argv[1].endsWith('daemon.js')) {
  startDaemon();
}
