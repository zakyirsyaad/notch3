import { defineConfig } from 'vitest/config';
import path from 'node:path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['packages/*/tests/**/*.test.ts', 'tests/**/*.test.ts'],
    setupFiles: ['./tests/setup.ts'],
    testTimeout: 60000,
    hookTimeout: 30000,
    fileParallelism: false,
    maxWorkers: 1,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 80,
        statements: 80,
      },
      exclude: [
        '**/node_modules/**',
        '**/dist/**',
        '**/tests/**',
        '**/*.test.ts',
        'vitest.config.ts',
        'packages/agent-runtime/src/daemon.ts',
        'packages/agent-runtime/src/index.ts',
        'packages/shared-types/src/index.ts',
        'packages/agent-runtime/src/bnb/greenfield.ts',
      ],
    },
  },
  resolve: {
    alias: {
      '@notch/shared-types': path.resolve(__dirname, 'packages/shared-types/src/index.ts'),
      '@notch/agent-runtime': path.resolve(__dirname, 'packages/agent-runtime/src/index.ts'),
    },
  },
});
