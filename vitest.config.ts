import { defineConfig } from 'vitest/config';
import path from 'node:path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['packages/*/tests/**/*.test.ts', 'tests/**/*.test.ts'],
    testTimeout: 30000,
  },
  resolve: {
    alias: {
      '@notch/shared-types': path.resolve(__dirname, 'packages/shared-types/src/index.ts'),
      '@notch/agent-runtime': path.resolve(__dirname, 'packages/agent-runtime/src/index.ts'),
    },
  },
});
