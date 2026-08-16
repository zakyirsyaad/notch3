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
  type GreenfieldUploadResult,
  type GreenfieldObjectResult,
  type GreenfieldObjectMetadata,
  type GreenfieldBackupResult,
  type NetworkConfig,
  type NetworkSwitchResult,
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
 * - greenfield.uploadObject
 * - greenfield.getObject
 * - greenfield.listObjects
 * - greenfield.backupChatHistory
 * - network.getNetworks
 * - network.getCurrentNetwork
 * - network.switchNetwork
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

  // 15. greenfield.uploadObject
  dispatcher.registerMethod(
    'greenfield.uploadObject',
    async (params: any): Promise<GreenfieldUploadResult> => {
      let uploadParams: {
        bucket?: string;
        objectName: string;
        content: string | Buffer;
        contentType?: string;
        isPrivate?: boolean;
      };

      if (Array.isArray(params)) {
        uploadParams = {
          bucket: typeof params[0] === 'string' ? params[0] : undefined,
          objectName: params[1],
          content: params[2],
          contentType: params[3],
          isPrivate: typeof params[4] === 'boolean' ? params[4] : undefined,
        };
      } else if (typeof params === 'object' && params !== null) {
        uploadParams = {
          bucket: params.bucket,
          objectName: params.objectName,
          content: params.content,
          contentType: params.contentType,
          isPrivate: params.isPrivate,
        };
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for greenfield.uploadObject: expected object or array'
        );
      }

      if (
        !uploadParams.objectName ||
        typeof uploadParams.objectName !== 'string' ||
        !uploadParams.objectName.trim()
      ) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Missing or invalid parameter: objectName is required'
        );
      }

      if (uploadParams.content === undefined || uploadParams.content === null) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Missing or invalid parameter: content is required'
        );
      }

      try {
        return await sdk.greenfield.uploadObject({
          bucket: uploadParams.bucket,
          objectName: uploadParams.objectName,
          content: uploadParams.content,
          contentType: uploadParams.contentType,
          isPrivate: uploadParams.isPrivate,
        });
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to upload object to Greenfield: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 16. greenfield.getObject
  dispatcher.registerMethod(
    'greenfield.getObject',
    async (params: any): Promise<GreenfieldObjectResult> => {
      let bucket: string | undefined;
      let objectName: string;

      if (Array.isArray(params)) {
        if (params.length === 1) {
          bucket = undefined;
          objectName = params[0];
        } else {
          bucket = params[0];
          objectName = params[1];
        }
      } else if (typeof params === 'object' && params !== null) {
        bucket = params.bucket;
        objectName = params.objectName;
      } else if (typeof params === 'string') {
        bucket = undefined;
        objectName = params;
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for greenfield.getObject: expected object or array'
        );
      }

      if (!objectName || typeof objectName !== 'string' || !objectName.trim()) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Missing or invalid parameter: objectName is required'
        );
      }

      const targetBucket = bucket || sdk.greenfield.defaultBucket;

      try {
        return await sdk.greenfield.getObject(targetBucket, objectName);
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to get object from Greenfield: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 17. greenfield.listObjects
  dispatcher.registerMethod(
    'greenfield.listObjects',
    async (params?: any): Promise<GreenfieldObjectMetadata[]> => {
      let bucket: string | undefined;
      let prefix: string | undefined;

      if (Array.isArray(params)) {
        bucket = typeof params[0] === 'string' ? params[0] : undefined;
        prefix = typeof params[1] === 'string' ? params[1] : undefined;
      } else if (typeof params === 'object' && params !== null) {
        bucket = typeof params.bucket === 'string' ? params.bucket : undefined;
        prefix = typeof params.prefix === 'string' ? params.prefix : undefined;
      } else if (typeof params === 'string') {
        bucket = params;
      }

      const targetBucket = bucket || sdk.greenfield.defaultBucket;

      try {
        return await sdk.greenfield.listObjects(targetBucket, prefix);
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to list Greenfield objects: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 18. greenfield.backupChatHistory
  dispatcher.registerMethod(
    'greenfield.backupChatHistory',
    async (params: any): Promise<GreenfieldBackupResult> => {
      let backupParams: any;

      if (Array.isArray(params)) {
        backupParams = {
          sessionId: params[0],
          encryptedData: params[1],
          bucket: params[2],
        };
      } else if (typeof params === 'object' && params !== null) {
        backupParams = params;
      } else {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for greenfield.backupChatHistory: expected object or array'
        );
      }

      if (
        !backupParams.sessionId ||
        typeof backupParams.sessionId !== 'string' ||
        !backupParams.sessionId.trim()
      ) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Missing or invalid parameter: sessionId is required'
        );
      }

      if (
        backupParams.encryptedData === undefined &&
        backupParams.rawHistory === undefined
      ) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Either encryptedData or rawHistory is required for backupChatHistory'
        );
      }

      try {
        return await sdk.greenfield.backupChatHistory(backupParams);
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to backup chat history to Greenfield: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 19. network.getNetworks
  dispatcher.registerMethod(
    'network.getNetworks',
    async (): Promise<NetworkConfig[]> => {
      return sdk.getNetworks();
    }
  );

  // 20. network.getCurrentNetwork
  dispatcher.registerMethod(
    'network.getCurrentNetwork',
    async (): Promise<NetworkConfig> => {
      return sdk.getCurrentNetwork();
    }
  );

  // 21. network.switchNetwork
  dispatcher.registerMethod(
    'network.switchNetwork',
    async (params: any): Promise<NetworkSwitchResult> => {
      let chainId: number | undefined;

      if (Array.isArray(params) && params.length > 0) {
        const first = params[0];
        if (typeof first === 'number' && !isNaN(first)) {
          chainId = first;
        } else if (typeof first === 'string' && !isNaN(Number(first))) {
          chainId = Number(first);
        }
      } else if (typeof params === 'object' && params !== null) {
        if (typeof params.chainId === 'number' && !isNaN(params.chainId)) {
          chainId = params.chainId;
        } else if (
          typeof params.chainId === 'string' &&
          !isNaN(Number(params.chainId)) &&
          params.chainId.trim() !== ''
        ) {
          chainId = Number(params.chainId);
        }
      } else if (typeof params === 'number' && !isNaN(params)) {
        chainId = params;
      }

      if (chainId === undefined) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for network.switchNetwork: chainId must be a valid number'
        );
      }

      try {
        const switchResult = sdk.switchNetwork(chainId);
        if (switchResult.success) {
          currentConfig.chainId = switchResult.activeNetwork.chainId;
          currentConfig.rpcUrl = switchResult.activeNetwork.rpcUrl;
        }
        return switchResult;
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to switch network: ${err?.message || String(err)}`
        );
      }
    }
  );

  return dispatcher;
}
