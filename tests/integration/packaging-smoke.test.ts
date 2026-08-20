import { describe, it, expect } from 'vitest';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';

describe('Packaging Smoke Test', () => {
  it('launches the embedded daemon from the build directory and processes a JSON-RPC request', () => {
    const rootDir = path.resolve(__dirname, '../../');
    const appBundlePath = path.join(rootDir, 'build/Notch3.app');
    
    // Smoke test only runs if the bundle has been built (e.g. during scripts/build-macos-app.sh)
    if (!fs.existsSync(appBundlePath)) {
      console.log('Skipping packaging smoke test (Notch3.app not yet built). Run pnpm run bundle:app first.');
      return;
    }

    const daemonPath = path.join(appBundlePath, 'Contents/Resources/agent-runtime/daemon.js');
    const nodeBinPath = path.join(appBundlePath, 'Contents/Resources/agent-runtime/node');

    expect(fs.existsSync(daemonPath)).toBe(true);
    expect(fs.existsSync(nodeBinPath)).toBe(true);

    // Spawn the daemon using the embedded node binary
    const daemon = spawn(nodeBinPath, [daemonPath]);

    let outputData = '';
    let errorData = '';

    daemon.stdout.on('data', (chunk) => {
      outputData += chunk;
    });

    daemon.stderr.on('data', (chunk) => {
      errorData += chunk;
    });

    return new Promise<void>((resolve, reject) => {
      // Send a valid JSON-RPC 2.0 request
      const rpcRequest = JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'agent.getStatus',
      }) + '\n';

      daemon.stdin.write(rpcRequest);

      // Give it a brief moment to answer and then exit
      setTimeout(() => {
        daemon.stdin.end();
      }, 500);

      daemon.on('close', (code) => {
        try {
          expect(code).toBe(0);
          
          // Parse stdout response
          const lines = outputData.trim().split('\n');
          const lastLine = lines[lines.length - 1];
          const response = JSON.parse(lastLine);

          expect(response.jsonrpc).toBe('2.0');
          expect(response.id).toBe(1);
          expect(response.result).toBeDefined();
          expect(response.result.lockState).toBe('locked'); // Fresh daemon should be locked
          
          resolve();
        } catch (err: any) {
          reject(new Error(`Daemon smoke test failed: ${err.message}. Stderr: ${errorData}`));
        }
      });
    });
  });
});
