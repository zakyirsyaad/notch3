/**
 * @notch/agent-runtime
 * Core agent runtime, JSON-RPC 2.0 message dispatcher, wallet management,
 * BNB Chain SDK capabilities, PancakeSwap DEX adapter, and MPP HTTP 402 server.
 */

import {
  JSONRPC_ERROR_CODES,
  type AgentConfig,
  type AgentStatus,
  type AgentExecutionResult,
  type TokenBalance,
  type SwapQuoteParams,
  type SwapQuoteResult,
  type BuildSwapParams,
  type UnsignedTransactionPayload,
  type MPPServerStatus,
  type MPPSaleReceipt,
} from '@notch/shared-types';
import { RPCDispatcher, RPCError } from './rpc/dispatcher.js';
import { AgentSession } from './wallet/session.js';
import { BnbAgentSdk } from './bnb/bnb-sdk.js';
import { queryBNBDocumentation, type BNBDocResponse } from './bnb/ask-ai.js';
import {
  AgentExecutor,
  type AgentExecutorOptions,
} from './agent/loop.js';
import { createDefaultTools } from './agent/tools.js';
import { MPPServer } from './mpp/server.js';

export * from './rpc/dispatcher.js';
export * from './rpc/transport.js';
export * from './utils/redact.js';
export * from './wallet/index.js';
export * from './bnb/index.js';
export * from './agent/index.js';
export * from './mpp/index.js';

export interface AgentRuntimeOptions {
  session?: AgentSession;
  sdk?: BnbAgentSdk;
  executor?: AgentExecutor;
  mppServer?: MPPServer;
  config?: Partial<AgentConfig>;
}

export interface AgentDispatcherInstance {
  dispatcher: RPCDispatcher;
  session: AgentSession;
  sdk: BnbAgentSdk;
  executor: AgentExecutor;
  mppServer: MPPServer;
}

/**
 * Creates and configures an RPCDispatcher instance with all standard Notch Agent RPC methods:
 * - agent.init
 * - agent.unlock
 * - agent.lock
 * - agent.getStatus
 * - agent.executePrompt
 * - agent.queryEcosystemDoc
 * - wallet.getAgentBalance
 * - wallet.registerERC8004Identity
 * - wallet.estimateSwapQuote
 * - wallet.buildSwapTx
 * - mpp.startServer
 * - mpp.stopServer
 * - mpp.getStatus
 * - mpp.getSalesHistory
 */
export function createAgentDispatcher(
  options?: AgentRuntimeOptions
): RPCDispatcher {
  const session = options?.session || new AgentSession();
  let sdk =
    options?.sdk ||
    new BnbAgentSdk(session, {
      chainId: options?.config?.chainId,
      rpcUrl: options?.config?.rpcUrl,
    });

  let currentConfig: AgentConfig = {
    chainId: options?.config?.chainId ?? 97,
    rpcUrl: options?.config?.rpcUrl ?? 'https://data-seed-prebsc-1-s1.binance.org:8545',
    openaiApiKey: options?.config?.openaiApiKey,
    openaiBaseUrl: options?.config?.openaiBaseUrl,
    openaiModel: options?.config?.openaiModel,
    agentName: options?.config?.agentName,
    customPrompt: options?.config?.customPrompt,
  };

  const executor =
    options?.executor ||
    new AgentExecutor({
      apiKey: currentConfig.openaiApiKey,
      baseUrl: currentConfig.openaiBaseUrl,
      model: currentConfig.openaiModel,
      customPrompt: currentConfig.customPrompt,
      session,
      sdk,
    });

  const mppServer =
    options?.mppServer ||
    new MPPServer({
      chainId: currentConfig.chainId,
      recipient: session.isUnlocked() ? session.getAddress() : undefined,
      provider: sdk.provider,
    });

  const dispatcher = new RPCDispatcher();

  // 1. agent.init
  dispatcher.registerMethod(
    'agent.init',
    async (params: Partial<AgentConfig> = {}) => {
      if (typeof params !== 'object' || params === null) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for agent.init'
        );
      }

      currentConfig = {
        ...currentConfig,
        ...params,
      };

      if (params.openaiApiKey) {
        executor.apiKey = params.openaiApiKey;
      }
      if (params.openaiBaseUrl) {
        executor.baseUrl = params.openaiBaseUrl;
      }
      if (params.openaiModel) {
        executor.model = params.openaiModel;
      }
      if (params.customPrompt) {
        executor.systemPrompt = params.customPrompt;
      }

      if (params.rpcUrl || params.chainId) {
        sdk = new BnbAgentSdk(session, {
          chainId: currentConfig.chainId,
          rpcUrl: currentConfig.rpcUrl,
        });

        // Refresh tools
        const updatedTools = createDefaultTools({ session, sdk });
        for (const tool of updatedTools) {
          executor.registerTool(
            tool.definition.function.name,
            tool.handler,
            tool.definition
          );
        }
      }

      return {
        initialized: true,
        config: currentConfig,
      };
    }
  );

  // 2. agent.unlock
  dispatcher.registerMethod('agent.unlock', async (params: any) => {
    let keystoreJson: string | undefined;
    let passphrase: string | undefined;

    if (Array.isArray(params)) {
      keystoreJson = params[0];
      passphrase = params[1];
    } else if (typeof params === 'object' && params !== null) {
      keystoreJson = params.keystoreJson || params.keystore;
      passphrase = params.passphrase || params.password;
    }

    if (!keystoreJson || !passphrase) {
      throw new RPCError(
        JSONRPC_ERROR_CODES.INVALID_PARAMS,
        'Both keystoreJson and passphrase are required to unlock the agent'
      );
    }

    try {
      const address = await session.unlock(keystoreJson, passphrase);
      mppServer.setRecipient(address);
      return {
        address,
        unlocked: true,
      };
    } catch (err: any) {
      throw new RPCError(
        JSONRPC_ERROR_CODES.UNAUTHORIZED,
        `Failed to unlock agent wallet: ${err?.message || String(err)}`
      );
    }
  });

  // 3. agent.lock
  dispatcher.registerMethod('agent.lock', async () => {
    session.lock();
    return { locked: true };
  });

  // 4. agent.getStatus
  dispatcher.registerMethod('agent.getStatus', async (): Promise<AgentStatus> => {
    const isUnlocked = session.isUnlocked();
    const lockState = isUnlocked ? 'unlocked' : 'locked';
    const state = isUnlocked ? 'active' : 'locked';

    let address: string | undefined;
    let balance: string | undefined;

    if (isUnlocked) {
      try {
        address = session.getAddress();
        const bal = await sdk.getBalance();
        balance = bal.uiBalance;
      } catch {
        // Suppress balance error if network unreachable
      }
    }

    return {
      state,
      lockState,
      address,
      balance,
      activeTasks: 0,
      lastActivity: Date.now(),
    };
  });

  // 5. agent.executePrompt
  dispatcher.registerMethod(
    'agent.executePrompt',
    async (params: any): Promise<AgentExecutionResult> => {
      let prompt: string;
      if (typeof params === 'string') {
        prompt = params;
      } else if (typeof params === 'object' && params !== null) {
        prompt = params.prompt || '';
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Prompt must be a string or object containing { prompt }'
        );
      }

      if (!prompt.trim()) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Prompt cannot be empty'
        );
      }

      return executor.executePrompt(prompt);
    }
  );

  // 6. agent.queryEcosystemDoc
  dispatcher.registerMethod(
    'agent.queryEcosystemDoc',
    async (params: any): Promise<BNBDocResponse> => {
      let query: string;
      if (typeof params === 'string') {
        query = params;
      } else if (typeof params === 'object' && params !== null) {
        query = params.query || '';
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Query must be a string or object containing { query }'
        );
      }

      return queryBNBDocumentation(query);
    }
  );

  // 7. wallet.getAgentBalance
  dispatcher.registerMethod(
    'wallet.getAgentBalance',
    async (params: any = {}): Promise<TokenBalance> => {
      if (!session.isUnlocked()) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.WALLET_LOCKED,
          'Agent wallet is locked. Please unlock before querying balance.'
        );
      }

      const tokenAddress =
        typeof params === 'string'
          ? params
          : params?.tokenAddress || undefined;

      return sdk.getBalance(tokenAddress);
    }
  );

  // 8. wallet.registerERC8004Identity
  dispatcher.registerMethod(
    'wallet.registerERC8004Identity',
    async (params: any = {}) => {
      if (!session.isUnlocked()) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.WALLET_LOCKED,
          'Agent wallet is locked. Please unlock before registering ERC-8004 identity.'
        );
      }

      const metadata = params.metadata || params;
      const options = params.options;

      const agentId = await sdk.registerIdentity(metadata, options);
      return { agentId };
    }
  );

  // 9. wallet.estimateSwapQuote
  dispatcher.registerMethod(
    'wallet.estimateSwapQuote',
    async (params: any): Promise<SwapQuoteResult> => {
      let quoteParams: SwapQuoteParams;
      if (Array.isArray(params)) {
        quoteParams = {
          tokenIn: params[0],
          tokenOut: params[1],
          amountIn: params[2],
          slippageTolerancePercent: params[3],
        };
      } else if (typeof params === 'object' && params !== null) {
        quoteParams = params as SwapQuoteParams;
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for wallet.estimateSwapQuote: expected object or array'
        );
      }

      if (!quoteParams.tokenIn || !quoteParams.tokenOut || !quoteParams.amountIn) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Missing required parameters: tokenIn, tokenOut, and amountIn are required'
        );
      }

      try {
        return await sdk.estimateSwapQuote(quoteParams);
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to estimate swap quote: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 10. wallet.buildSwapTx
  dispatcher.registerMethod(
    'wallet.buildSwapTx',
    async (params: any): Promise<UnsignedTransactionPayload> => {
      let buildParams: BuildSwapParams;
      if (Array.isArray(params)) {
        buildParams = {
          tokenIn: params[0],
          tokenOut: params[1],
          amountIn: params[2],
          amountOutMin: params[3],
          recipient: params[4],
          deadline: params[5],
          slippageTolerancePercent: params[6],
        };
      } else if (typeof params === 'object' && params !== null) {
        buildParams = params as BuildSwapParams;
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for wallet.buildSwapTx: expected object or array'
        );
      }

      if (
        !buildParams.tokenIn ||
        !buildParams.tokenOut ||
        !buildParams.amountIn ||
        !buildParams.amountOutMin ||
        !buildParams.recipient
      ) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Missing required parameters: tokenIn, tokenOut, amountIn, amountOutMin, and recipient are required'
        );
      }

      try {
        return await sdk.buildSwapTransaction(buildParams);
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to build swap transaction: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 11. mpp.startServer
  dispatcher.registerMethod(
    'mpp.startServer',
    async (params?: any): Promise<{ port: number; host: string; status: string; running: boolean }> => {
      let port: number | undefined;

      if (Array.isArray(params)) {
        port = typeof params[0] === 'number' ? params[0] : undefined;
      } else if (typeof params === 'number') {
        port = params;
      } else if (typeof params === 'object' && params !== null) {
        if (typeof params.port === 'number') {
          port = params.port;
        }
        if (typeof params.recipient === 'string') {
          mppServer.setRecipient(params.recipient);
        }
      }

      if (
        session.isUnlocked() &&
        (!mppServer.getStatus().recipient ||
          mppServer.getStatus().recipient === '0x0000000000000000000000000000000000000000')
      ) {
        mppServer.setRecipient(session.getAddress());
      }

      try {
        const startResult = await mppServer.start(port);
        return {
          port: startResult.port,
          host: startResult.host,
          status: 'running',
          running: true,
        };
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to start MPP server: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 12. mpp.stopServer
  dispatcher.registerMethod(
    'mpp.stopServer',
    async (): Promise<{ stopped: boolean }> => {
      try {
        return await mppServer.stop();
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to stop MPP server: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 13. mpp.getStatus
  dispatcher.registerMethod(
    'mpp.getStatus',
    async (): Promise<MPPServerStatus> => {
      if (
        session.isUnlocked() &&
        (!mppServer.getStatus().recipient ||
          mppServer.getStatus().recipient === '0x0000000000000000000000000000000000000000')
      ) {
        mppServer.setRecipient(session.getAddress());
      }
      return mppServer.getStatus();
    }
  );

  // 14. mpp.getSalesHistory
  dispatcher.registerMethod(
    'mpp.getSalesHistory',
    async (): Promise<MPPSaleReceipt[]> => {
      return mppServer.getSalesHistory();
    }
  );

  return dispatcher;
}
