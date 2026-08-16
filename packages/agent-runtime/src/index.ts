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
import { generateAgentKeystore } from './wallet/keystore.js';
import { BnbAgentSdk } from './bnb/bnb-sdk.js';
import { getPancakeSwapDeployment } from './bnb/pancakeswap.js';
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
 * - agent.createWallet
 * - wallet.getAgentBalance
 * - wallet.registerERC8004Identity
 * - wallet.estimateSwapQuote
 * - wallet.buildSwapTx
 * - wallet.sendRawTransaction
 * - wallet.getAllowance
 * - wallet.buildApproveTx
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
      // Durable replay protection survives subprocess restarts.
      // In-memory only under Vitest so tests never touch the user's home dir.
      replayStorePath: process.env.VITEST
        ? undefined
        : process.env.NOTCH_REPLAY_STORE_PATH ||
          `${process.env.HOME ?? '.'}/Library/Application Support/notch-agent/replay-store.json`,
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
        mppServer.setProvider(sdk.provider);
        if (currentConfig.chainId !== undefined) {
          mppServer.setChainId(currentConfig.chainId);
        }

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

  // 21. network.getNetworks
  dispatcher.registerMethod(
    'network.getNetworks',
    async (): Promise<NetworkConfig[]> => {
      return sdk.getNetworks();
    }
  );

  // 22. network.getCurrentNetwork
  dispatcher.registerMethod(
    'network.getCurrentNetwork',
    async (): Promise<NetworkConfig> => {
      return sdk.getCurrentNetwork();
    }
  );

  // 23. network.switchNetwork
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
          // Keep the maker-mode payment verifier on the active network.
          mppServer.setProvider(sdk.provider);
          mppServer.setChainId(switchResult.activeNetwork.chainId);
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

  // 24. agent.createWallet
  dispatcher.registerMethod(
    'agent.createWallet',
    async (params: any): Promise<{ address: string; keystoreJson: string }> => {
      let passphrase: string | undefined;
      if (typeof params === 'string') {
        passphrase = params;
      } else if (Array.isArray(params)) {
        passphrase = typeof params[0] === 'string' ? params[0] : undefined;
      } else if (typeof params === 'object' && params !== null) {
        passphrase = params.passphrase || params.password;
      }

      if (!passphrase || typeof passphrase !== 'string' || !passphrase.trim()) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'A non-empty passphrase is required to create an agent wallet'
        );
      }

      try {
        return await generateAgentKeystore(passphrase);
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to create agent wallet: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 25. wallet.sendRawTransaction
  dispatcher.registerMethod(
    'wallet.sendRawTransaction',
    async (params: any): Promise<{ txHash: string }> => {
      let signedTx: string | undefined;
      if (typeof params === 'string') {
        signedTx = params;
      } else if (Array.isArray(params) && typeof params[0] === 'string') {
        signedTx = params[0];
      } else if (typeof params === 'object' && params !== null) {
        signedTx = params.signedTx || params.rawTransaction || params.transaction;
      }

      if (
        !signedTx ||
        typeof signedTx !== 'string' ||
        !/^0x[0-9a-fA-F]+$/.test(signedTx.trim())
      ) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for wallet.sendRawTransaction: signedTx must be a 0x-prefixed hex string'
        );
      }

      try {
        const response = await sdk.provider.broadcastTransaction(signedTx.trim());
        const txHash = typeof response === 'string' ? response : response.hash;
        return { txHash };
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to broadcast transaction: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 26. wallet.getTxContext
  dispatcher.registerMethod(
    'wallet.getTxContext',
    async (params: any): Promise<{ nonce: number; gasPriceWei: string; chainId: number }> => {
      let address: string | undefined;
      if (typeof params === 'string') {
        address = params;
      } else if (Array.isArray(params) && typeof params[0] === 'string') {
        address = params[0];
      } else if (typeof params === 'object' && params !== null) {
        address = params.address || params.walletAddress;
      }

      if (!address || typeof address !== 'string' || !address.trim()) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for wallet.getTxContext: address is required'
        );
      }

      try {
        const provider = sdk.provider;
        const [nonce, feeData] = await Promise.all([
          provider.getTransactionCount(address, 'pending'),
          provider.getFeeData(),
        ]);
        const gasPrice = feeData.gasPrice ?? 5_000_000_000n; // 5 gwei fallback
        return {
          nonce,
          gasPriceWei: gasPrice.toString(),
          chainId: currentConfig.chainId,
        };
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to fetch transaction context: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 27. wallet.getAllowance
  dispatcher.registerMethod(
    'wallet.getAllowance',
    async (params: any): Promise<{ allowanceWei: string; token: string; owner: string; spender: string }> => {
      let token: string | undefined;
      let owner: string | undefined;
      let spender: string | undefined;

      if (Array.isArray(params)) {
        token = params[0];
        owner = params[1];
        spender = params[2];
      } else if (typeof params === 'object' && params !== null) {
        token = params.token || params.tokenAddress;
        owner = params.owner || params.ownerAddress;
        spender = params.spender || params.spenderAddress;
      }

      if (!token || !owner) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for wallet.getAllowance: token and owner are required'
        );
      }

      try {
        const resolvedSpender =
          spender || getPancakeSwapDeployment(currentConfig.chainId ?? 97).router;
        const allowanceWei = await sdk.getTokenAllowance(token, owner, resolvedSpender);
        return { allowanceWei, token, owner, spender: resolvedSpender };
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to fetch allowance: ${err?.message || String(err)}`
        );
      }
    }
  );

  // 28. wallet.buildApproveTx
  dispatcher.registerMethod(
    'wallet.buildApproveTx',
    async (params: any): Promise<UnsignedTransactionPayload> => {
      let token: string | undefined;
      let spender: string | undefined;
      let amountWei: string | undefined;
      let chainId: number | undefined;

      if (Array.isArray(params)) {
        token = params[0];
        spender = params[1];
        amountWei = params[2];
        chainId = params[3];
      } else if (typeof params === 'object' && params !== null) {
        token = params.token || params.tokenAddress;
        spender = params.spender || params.spenderAddress;
        amountWei = params.amountWei;
        chainId = params.chainId;
      }

      if (!token) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INVALID_PARAMS,
          'Invalid parameters for wallet.buildApproveTx: token is required'
        );
      }

      try {
        return await sdk.buildApproveTransaction({
          tokenAddress: token,
          spender,
          amountWei,
          chainId: chainId ?? currentConfig.chainId,
        });
      } catch (err: any) {
        throw new RPCError(
          JSONRPC_ERROR_CODES.INTERNAL_ERROR,
          `Failed to build approve transaction: ${err?.message || String(err)}`
        );
      }
    }
  );

  return dispatcher;
}
