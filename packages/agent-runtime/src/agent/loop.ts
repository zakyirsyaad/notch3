/**
 * OpenAI-Compatible AI Chat Completion & Tool Loop Executor
 *
 * Dispatches autonomous tools, executes iterative tool call reasoning loops,
 * aggregates x402 payment receipts, and ensures strict redaction of sensitive data.
 */

import type {
  AgentExecutionResult,
  ToolCallExecution,
  X402PaymentReceipt,
} from '@notch/shared-types';
import { isX402PaymentReceipt } from '@notch/shared-types';
import { redactSecrets } from '../utils/redact.js';
import type { AgentSession } from '../wallet/session.js';
import type { BnbAgentSdk } from '../bnb/bnb-sdk.js';
import {
  createDefaultTools,
  type ToolDefinition,
  type ToolHandler,
  type RegisteredTool,
} from './tools.js';

export const DEFAULT_SYSTEM_PROMPT =
  'You are Notch3, an intelligent Web3 assistant running on macOS. ' +
  'You have access to autonomous tools for querying BNB Chain balances, discovering ERC-8004 registered agent identities, ' +
  'settling x402 HTTP 402 payment challenges on BSC Testnet, and consulting BNB Chain documentation. ' +
  'Execute tools whenever needed to fulfill user requests accurately and autonomously.';

export interface AgentExecutorOptions {
  apiKey?: string;
  openaiApiKey?: string;
  baseUrl?: string;
  openaiBaseUrl?: string;
  model?: string;
  openaiModel?: string;
  systemPrompt?: string;
  customPrompt?: string;
  session?: AgentSession;
  sdk?: BnbAgentSdk;
  tools?: RegisteredTool[];
  maxIterations?: number;
  fetch?: typeof fetch;
}

export class AgentExecutor {
  public apiKey: string;
  public baseUrl: string;
  public model: string;
  public systemPrompt: string;
  public maxIterations: number;

  private _session?: AgentSession;
  private _sdk?: BnbAgentSdk;
  private _fetch: typeof fetch;
  private readonly _handlers = new Map<string, ToolHandler>();
  private readonly _definitions = new Map<string, ToolDefinition>();

  constructor(options?: AgentExecutorOptions) {
    const configuredApiKey =
      options && 'openaiApiKey' in options ? options.openaiApiKey : options?.apiKey;
    const configuredBaseUrl =
      options && 'openaiBaseUrl' in options ? options.openaiBaseUrl : options?.baseUrl;
    const configuredModel =
      options && 'openaiModel' in options ? options.openaiModel : options?.model;

    // Provider credentials are explicit runtime input. Never inherit a process
    // environment key: a keyless local provider must stay keyless, and the
    // Swift shell is the only component allowed to retrieve the Keychain key.
    this.apiKey = configuredApiKey ?? '';
    this.baseUrl = configuredBaseUrl ?? 'https://api.openai.com/v1';
    this.model = configuredModel ?? 'gpt-4o';
    this.systemPrompt =
      options?.systemPrompt ||
      options?.customPrompt ||
      DEFAULT_SYSTEM_PROMPT;
    this.maxIterations = options?.maxIterations ?? 5;
    this._session = options?.session;
    this._sdk = options?.sdk;
    this._fetch = options?.fetch || (typeof fetch !== 'undefined' ? fetch : (null as any));

    // Register initial default tools
    const initialTools = options?.tools || createDefaultTools({
      session: this._session,
      sdk: this._sdk,
    });

    for (const tool of initialTools) {
      this.registerTool(tool.definition.function.name, tool.handler, tool.definition);
    }
  }

  /**
   * Registers a tool handler and its OpenAI function definition.
   */
  public registerTool(
    name: string,
    handler: ToolHandler,
    definition?: ToolDefinition
  ): void {
    if (!name || typeof name !== 'string') {
      throw new Error('Tool name must be a non-empty string');
    }
    this._handlers.set(name, handler);

    if (definition) {
      this._definitions.set(name, definition);
    } else if (!this._definitions.has(name)) {
      // Auto-generate generic definition if none provided
      this._definitions.set(name, {
        type: 'function',
        function: {
          name,
          description: `Custom tool handler for ${name}`,
          parameters: {
            type: 'object',
            properties: {},
          },
        },
      });
    }
  }

  /**
   * Unregisters a tool by name.
   */
  public unregisterTool(name: string): void {
    this._handlers.delete(name);
    this._definitions.delete(name);
  }

  /**
   * Checks if a tool is registered.
   */
  public hasTool(name: string): boolean {
    return this._handlers.has(name);
  }

  /**
   * Returns all registered OpenAI tool definitions.
   */
  public getTools(): ToolDefinition[] {
    return Array.from(this._definitions.values());
  }

  /**
   * Directly executes a registered tool by name with the given arguments.
   */
  public async runTool(
    name: string,
    args: Record<string, unknown>
  ): Promise<unknown> {
    const handler = this._handlers.get(name);
    if (!handler) {
      throw new Error(`Tool '${name}' is not registered`);
    }
    return handler(args);
  }

  /**
   * Runs the prompt against the OpenAI chat completions API with recursive tool calling.
   *
   * @param prompt User prompt text
   * @param streamCb Optional streaming callback invoked with text chunks
   * @returns Aggregated AgentExecutionResult
   */
  public async executePrompt(
    prompt: string,
    streamCb?: (chunk: string) => void
  ): Promise<AgentExecutionResult> {
    const cleanPrompt = redactSecrets(prompt);

    const messages: Array<{
      role: 'system' | 'user' | 'assistant' | 'tool';
      content: string | null;
      tool_calls?: any[];
      tool_call_id?: string;
    }> = [
      { role: 'system', content: this.systemPrompt },
      { role: 'user', content: cleanPrompt },
    ];

    const toolCallsExecuted: ToolCallExecution[] = [];
    const receipts: X402PaymentReceipt[] = [];
    const citations: string[] = [];

    for (let iteration = 0; iteration < this.maxIterations; iteration++) {
      const toolsPayload = this.getTools();
      const payload: Record<string, unknown> = {
        model: this.model,
        messages,
      };

      if (toolsPayload.length > 0) {
        payload.tools = toolsPayload;
        payload.tool_choice = 'auto';
      }

      const endpoint = `${this.baseUrl.replace(/\/$/, '')}/chat/completions`;
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
      };
      if (this.apiKey.trim()) {
        headers.Authorization = `Bearer ${this.apiKey}`;
      }

      const response = await this._fetch(endpoint, {
        method: 'POST',
        headers,
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        const errText = await response.text().catch(() => '');
        throw new Error(
          `OpenAI API request failed with status ${response.status}: ${errText}`
        );
      }

      const data = (await response.json()) as any;
      const choice = data.choices?.[0];
      const message = choice?.message;

      if (!message) {
        throw new Error('Received invalid or empty response from OpenAI completions API');
      }

      // Check if tool calls were requested
      if (Array.isArray(message.tool_calls) && message.tool_calls.length > 0) {
        messages.push({
          role: 'assistant',
          content: message.content || null,
          tool_calls: message.tool_calls,
        });

        for (const toolCall of message.tool_calls) {
          const toolName = toolCall.function?.name || '';
          let parsedArgs: Record<string, unknown> = {};

          if (typeof toolCall.function?.arguments === 'string') {
            try {
              parsedArgs = JSON.parse(toolCall.function.arguments);
            } catch {
              parsedArgs = {};
            }
          } else if (typeof toolCall.function?.arguments === 'object') {
            parsedArgs = toolCall.function.arguments;
          }

          let result: unknown;
          try {
            result = await this.runTool(toolName, parsedArgs);
          } catch (err: any) {
            result = {
              error: err?.message || String(err),
            };
          }

          toolCallsExecuted.push({
            name: toolName,
            args: parsedArgs,
            result,
          });

          // Extract receipts or citations
          if (isX402PaymentReceipt(result) || (result && typeof result === 'object' && 'txHash' in (result as any))) {
            receipts.push(result as X402PaymentReceipt);
          }
          if (result && typeof result === 'object' && Array.isArray((result as any).citations)) {
            citations.push(...(result as any).citations);
          }

          messages.push({
            role: 'tool',
            tool_call_id: toolCall.id,
            content: typeof result === 'string' ? result : JSON.stringify(result),
          });
        }
      } else {
        // Final text response
        let finalResponse = message.content || '';
        finalResponse = redactSecrets(finalResponse);

        if (streamCb && finalResponse) {
          streamCb(finalResponse);
        }

        return {
          response: finalResponse,
          toolCallsExecuted,
          receipts: receipts.length > 0 ? receipts : undefined,
          citations: citations.length > 0 ? Array.from(new Set(citations)) : undefined,
        };
      }
    }

    // Maximum iterations reached
    const fallbackMessage = 'Agent reached maximum execution steps.';
    if (streamCb) {
      streamCb(fallbackMessage);
    }

    return {
      response: fallbackMessage,
      toolCallsExecuted,
      receipts: receipts.length > 0 ? receipts : undefined,
      citations: citations.length > 0 ? Array.from(new Set(citations)) : undefined,
    };
  }
}
