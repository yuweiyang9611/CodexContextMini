#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, lstatSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const SERVER_NAME = "Context Window Manager";
const SERVER_VERSION = "0.2.0";
const WIDGET_URI = "ui://context-window-manager/control-v1.html";
const RESOURCE_MIME_TYPE = "text/html;profile=mcp-app";
const CORE_PROTOCOL_VERSION = "2025-11-25";
const SUPPORTED_CORE_PROTOCOLS = new Set(["2024-11-05", "2025-03-26", "2025-06-18", CORE_PROTOCOL_VERSION]);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(__dirname, "..");
const MANAGER_PATH = path.join(PLUGIN_ROOT, "scripts", "context-window.ps1");
const CATALOG_PATH = path.join(PLUGIN_ROOT, "scripts", "model-capabilities.json");
const WIDGET_PATH = path.join(PLUGIN_ROOT, "ui", "context-window-control.html");

const JsonRpcError = Object.freeze({
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL_ERROR: -32603,
});

const PROFILE_NAMES = new Set(["auto", "compact", "balanced", "1m", "custom"]);
const SCOPES = new Set(["total", "body_after_prefix"]);
const MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]*$/;
let clientCapabilities = {};
let nextServerRequestId = 1;
const pendingRequests = new Map();
const cancelledClientRequests = new Set();
const authorizationGrants = new Map();
const AUTHORIZATION_TTL_MS = 15 * 60 * 1000;

function loadJson(filePath, label) {
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`Could not load ${label}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

if (!existsSync(MANAGER_PATH) || !existsSync(WIDGET_PATH) || !existsSync(CATALOG_PATH)) {
  process.stderr.write("Context Window Manager installation is incomplete.\n");
  process.exit(1);
}

const catalog = loadJson(CATALOG_PATH, "the model catalog");
const widgetHtml = readFileSync(WIDGET_PATH, "utf8");
const maxCatalogTokens = Math.max(
  1_050_000,
  ...catalog.models.map((entry) => Number(entry.maxContextTokens) || 0),
);

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function requestClient(method, params, timeoutMs = 10_000) {
  const id = `context-window-manager-${nextServerRequestId++}`;
  send({ jsonrpc: "2.0", id, method, params });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error(`The MCP host did not answer ${method}.`));
    }, timeoutMs);
    pendingRequests.set(id, {
      resolve: (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      },
    });
  });
}

function requireObject(value, name) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be an object.`);
  }
  return value;
}

function optionalString(value, name, maxLength = 4096) {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string") throw new Error(`${name} must be a string.`);
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength || /[\u0000-\u001f\u007f]/u.test(trimmed)) {
    throw new Error(`${name} is empty, too long, or contains control characters.`);
  }
  return trimmed;
}

function requireProjectRoot(value) {
  const raw = optionalString(value, "projectRoot", 32767);
  if (!raw) throw new Error("projectRoot is required.");
  if (!path.isAbsolute(raw)) throw new Error("projectRoot must be an absolute path.");

  const resolved = path.resolve(raw);
  let item;
  try {
    item = statSync(resolved);
  } catch {
    throw new Error("projectRoot does not exist.");
  }
  if (!item.isDirectory()) throw new Error("projectRoot must identify a directory.");
  if (resolved.startsWith("\\\\") || path.parse(resolved).root === resolved) {
    throw new Error("UNC paths and filesystem roots are not accepted as project roots.");
  }
  if (lstatSync(resolved).isSymbolicLink()) {
    throw new Error("A reparse-point or symbolic-link projectRoot is not accepted.");
  }
  return resolved;
}

function samePath(left, right) {
  const normalize = (value) => path.resolve(value).replace(/[\\/]+$/u, "");
  return process.platform === "win32"
    ? normalize(left).toLocaleLowerCase("en-US") === normalize(right).toLocaleLowerCase("en-US")
    : normalize(left) === normalize(right);
}

function pruneAuthorizationGrants() {
  const now = Date.now();
  for (const [token, grant] of authorizationGrants) {
    if (grant.expiresAtMs <= now) authorizationGrants.delete(token);
  }
}

function issueAuthorizationGrant(projectRoot) {
  pruneAuthorizationGrants();
  const token = randomBytes(32).toString("hex");
  const expiresAtMs = Date.now() + AUTHORIZATION_TTL_MS;
  authorizationGrants.set(token, { projectRoot, expiresAtMs });
  return { token, projectRoot, expiresAt: new Date(expiresAtMs).toISOString() };
}

function validateAuthorizationGrant(tokenValue, projectRoot) {
  pruneAuthorizationGrants();
  const token = optionalString(tokenValue, "authorizationToken", 64);
  if (!token || !/^[a-f0-9]{64}$/u.test(token)) {
    throw new Error("This host did not provide MCP roots. Open the graphical slider first, then confirm the write from that widget.");
  }
  const grant = authorizationGrants.get(token);
  if (!grant || !samePath(grant.projectRoot, projectRoot)) {
    throw new Error("The widget authorization is missing, expired, or bound to a different project.");
  }
}

async function resolveHostProjectRoot(requestedValue, { write = false, authorizationToken } = {}) {
  const requestedRoot = requestedValue === undefined || requestedValue === null || requestedValue === ""
    ? undefined
    : requireProjectRoot(requestedValue);

  if (!clientCapabilities?.roots) {
    if (!requestedRoot) {
      throw new Error("This MCP host did not advertise workspace roots, so an explicit absolute projectRoot is required.");
    }
    if (write) validateAuthorizationGrant(authorizationToken, requestedRoot);
    return { projectRoot: requestedRoot, binding: write ? "widget-authorization" : "explicit-readonly" };
  }

  const result = await requestClient("roots/list", {});
  const roots = Array.isArray(result?.roots) ? result.roots : [];
  if (roots.length === 0) throw new Error("The MCP host returned no workspace roots.");

  const hostRoots = roots.map((root) => {
    const rootUri = optionalString(root?.uri, "root URI", 32767);
    if (!rootUri) throw new Error("An MCP workspace root has no URI.");
    let url;
    try {
      url = new URL(rootUri);
    } catch {
      throw new Error("An MCP workspace root URI is invalid.");
    }
    if (url.protocol !== "file:" || (url.hostname && url.hostname !== "localhost")) {
      throw new Error("Only local file: workspace roots are supported.");
    }

    let decodedRoot;
    try {
      decodedRoot = fileURLToPath(url);
    } catch {
      throw new Error("An MCP workspace root could not be converted to a local path.");
    }
    return requireProjectRoot(decodedRoot);
  });

  if (!requestedRoot && hostRoots.length !== 1) {
    throw new Error("Exactly one MCP workspace root is required when projectRoot is omitted.");
  }
  const matchingRoots = requestedRoot ? hostRoots.filter((root) => samePath(root, requestedRoot)) : hostRoots;
  if (matchingRoots.length !== 1) {
    throw new Error("projectRoot does not match the workspace root supplied by the MCP host.");
  }
  return { projectRoot: matchingRoots[0], binding: "roots" };
}

function assertNotCancelled(requestId) {
  if (cancelledClientRequests.has(requestId)) throw new Error("The tool request was cancelled before project access began.");
}

function optionalModel(value) {
  const model = optionalString(value, "model", 128);
  if (model && !MODEL_PATTERN.test(model)) {
    throw new Error("model must be a single-line model slug using letters, digits, dot, underscore, colon, slash, or hyphen.");
  }
  return model;
}

function optionalInteger(value, name, { min = 1, max = 2_147_483_647 } = {}) {
  if (value === undefined || value === null) return undefined;
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

function runManager(projectRoot, command, managerArgs = []) {
  const args = [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    MANAGER_PATH,
    command,
    "-ProjectRoot",
    projectRoot,
    ...managerArgs,
    "-Json",
  ];

  const child = spawnSync("powershell.exe", args, {
    cwd: projectRoot,
    encoding: "utf8",
    windowsHide: true,
    timeout: 25_000,
    maxBuffer: 4 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (child.error) {
    throw new Error(`Could not start the project manager: ${child.error.message}`);
  }
  if (child.status !== 0) {
    const detail = String(child.stderr || child.stdout || "The project manager rejected the request.").trim();
    const error = new Error(detail || "The project manager rejected the request.");
    error.managerExitCode = child.status;
    throw error;
  }

  const output = String(child.stdout || "").trim();
  if (!output) throw new Error("The project manager returned no JSON result.");
  try {
    return JSON.parse(output);
  } catch {
    throw new Error("The project manager returned invalid JSON.");
  }
}

function readStatus(projectRoot, model) {
  const args = model ? ["-Model", model] : [];
  return runManager(projectRoot, "status", args);
}

function makeSnapshot(status, action = null, accessBinding = null) {
  return {
    schemaVersion: 1,
    kind: "context-window-control",
    status,
    action,
    accessBinding,
    limits: {
      minimumWindowTokens: 8_192,
      maximumSliderTokens: maxCatalogTokens,
    },
    presets: [
      { id: "auto", label: "Auto", windowTokens: null, compactAtTokens: null },
      { id: "compact", label: "128K", windowTokens: 128_000, compactAtTokens: 96_000 },
      { id: "balanced", label: "400K", windowTokens: 400_000, compactAtTokens: 320_000 },
      { id: "1m", label: "1.05M", windowTokens: 1_050_000, compactAtTokens: 850_000 },
    ],
    catalog: {
      updated: catalog.updated,
      models: catalog.models.map(({ id, maxContextTokens }) => ({ id, maxContextTokens })),
    },
    notices: [
      "The bundled API-model catalog is dated reference data, not live detection of the Codex host or account limit.",
      "Project-scoped settings require a trusted project and are reliably picked up only by a new Codex task or app restart.",
      "Changing this control cannot enlarge an ordinary ChatGPT conversation or a model's server-side capacity.",
    ],
  };
}

function textResult(text, structuredContent, extra = {}) {
  return {
    content: [{ type: "text", text }],
    structuredContent,
    ...extra,
  };
}

function errorToolResult(error) {
  const message = error instanceof Error ? error.message : String(error);
  return {
    isError: true,
    content: [{ type: "text", text: message }],
    structuredContent: {
      ok: false,
      error: message,
      managerExitCode: Number.isInteger(error?.managerExitCode) ? error.managerExitCode : null,
    },
  };
}

const commonProjectRootProperty = {
  type: "string",
  description: "Absolute current project root. It is matched against roots/list when supported; older rootless clients get read-only access until the graphical widget supplies a private write grant.",
};

const commonModelProperty = {
  type: "string",
  description: "Exact active model slug when known, for example gpt-5.6-sol. This is checked only against the bundled dated API catalog.",
  maxLength: 128,
  pattern: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$",
};

const authorizationTokenProperty = {
  type: "string",
  description: "Opaque widget-only authorization returned in tool-result metadata. Required for writes only when the MCP host does not expose roots.",
  minLength: 64,
  maxLength: 64,
  pattern: "^[a-f0-9]{64}$",
};

const tools = [
  {
    name: "get_context_window_status",
    title: "Get context window status",
    description: "Read the current project's plugin-managed context profile. This does not detect project trust or the effective host/account limit.",
    inputSchema: {
      type: "object",
      properties: { projectRoot: commonProjectRootProperty, model: commonModelProperty },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "apply_context_window_profile",
    title: "Apply context window profile",
    description: "After explicit user confirmation, apply a project-scoped Auto, 128K, 400K, 1.05M, or custom context/compaction profile through the safe manager. Never claim this raises the host limit.",
    inputSchema: {
      type: "object",
      properties: {
        projectRoot: commonProjectRootProperty,
        profile: { type: "string", enum: ["auto", "compact", "balanced", "1m", "custom"] },
        model: commonModelProperty,
        tokens: { type: "integer", minimum: 8192, maximum: 2147483647 },
        compactAt: { type: "integer", minimum: 1, maximum: 2147483646 },
        scope: { type: "string", enum: ["total", "body_after_prefix"], default: "total" },
        authorizationToken: authorizationTokenProperty,
      },
      required: ["profile"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "reset_context_window_profile",
    title: "Reset context window plugin state",
    description: "After explicit user confirmation, remove only this plugin's marked project block and state file while preserving unrelated Codex configuration.",
    inputSchema: {
      type: "object",
      properties: { projectRoot: commonProjectRootProperty, model: commonModelProperty, authorizationToken: authorizationTokenProperty },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "show_context_window_slider",
    title: "Open context window slider",
    description: "Render the graphical context-window control for the current Codex project. Call this when the user asks to open, show, or use the context-size slider. Supply the active workspace root and exact model slug when available.",
    inputSchema: {
      type: "object",
      properties: { projectRoot: commonProjectRootProperty, model: commonModelProperty },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    _meta: {
      ui: { resourceUri: WIDGET_URI },
      "openai/outputTemplate": WIDGET_URI,
      "openai/toolInvocation/invoking": "Opening context controls…",
      "openai/toolInvocation/invoked": "Context controls ready",
    },
  },
];

function getToolArguments(params) {
  const input = requireObject(params ?? {}, "params");
  if (typeof input.name !== "string") throw new Error("Tool name is required.");
  const args = input.arguments === undefined ? {} : requireObject(input.arguments, "arguments");
  return { name: input.name, args };
}

function rejectUnknownKeys(value, allowedKeys) {
  const unknown = Object.keys(value).filter((key) => !allowedKeys.has(key));
  if (unknown.length > 0) throw new Error(`Unsupported argument: ${unknown[0]}`);
}

async function handleToolCall(params, requestId) {
  const { name, args } = getToolArguments(params);
  const allowedByTool = {
    get_context_window_status: new Set(["projectRoot", "model"]),
    show_context_window_slider: new Set(["projectRoot", "model"]),
    apply_context_window_profile: new Set(["projectRoot", "profile", "model", "tokens", "compactAt", "scope", "authorizationToken"]),
    reset_context_window_profile: new Set(["projectRoot", "model", "authorizationToken"]),
  };
  if (!Object.hasOwn(allowedByTool, name)) throw new Error(`Unknown tool: ${name}`);
  rejectUnknownKeys(args, allowedByTool[name]);
  const isWrite = name === "apply_context_window_profile" || name === "reset_context_window_profile";
  const access = await resolveHostProjectRoot(args.projectRoot, { write: isWrite, authorizationToken: args.authorizationToken });
  const projectRoot = access.projectRoot;
  assertNotCancelled(requestId);
  const model = optionalModel(args.model);

  if (name === "get_context_window_status" || name === "show_context_window_slider") {
    const snapshot = makeSnapshot(readStatus(projectRoot, model), null, access.binding);
    const extra = name === "show_context_window_slider"
      ? { _meta: {
        "openai/outputTemplate": WIDGET_URI,
        "context-window-manager/authorization": issueAuthorizationGrant(projectRoot),
      } }
      : {};
    return textResult(
      `Context profile for ${projectRoot}: ${snapshot.status.profile}. The dated catalog is not a live host-limit check.`,
      snapshot,
      extra,
    );
  }

  if (name === "apply_context_window_profile") {
    const profile = optionalString(args.profile, "profile", 16);
    if (!profile || !PROFILE_NAMES.has(profile)) throw new Error("profile is invalid.");
    if (profile !== "auto" && !model) throw new Error("model is required for non-auto profiles.");

    const scope = optionalString(args.scope, "scope", 32) ?? "total";
    if (!SCOPES.has(scope)) throw new Error("scope is invalid.");
    const tokens = optionalInteger(args.tokens, "tokens", { min: 8192 });
    const compactAt = optionalInteger(args.compactAt, "compactAt");
    if (profile === "custom" && tokens === undefined) throw new Error("tokens is required for the custom profile.");
    if (tokens !== undefined && compactAt !== undefined && compactAt >= tokens) {
      throw new Error("compactAt must be smaller than tokens.");
    }

    const managerArgs = ["-Profile", profile];
    if (model && profile !== "auto") managerArgs.push("-Model", model);
    if (tokens !== undefined) managerArgs.push("-Tokens", String(tokens));
    if (compactAt !== undefined) managerArgs.push("-CompactAt", String(compactAt));
    if (profile !== "auto") managerArgs.push("-Scope", scope);

    const action = runManager(projectRoot, "apply", managerArgs);
    const snapshot = makeSnapshot(readStatus(projectRoot, model), action, access.binding);
    return textResult(
      `Applied project profile ${profile}. The project must be trusted; start a new Codex task or restart the app for reliable pickup.`,
      snapshot,
    );
  }

  if (name === "reset_context_window_profile") {
    const action = runManager(projectRoot, "reset");
    const snapshot = makeSnapshot(readStatus(projectRoot, model), action, access.binding);
    return textResult(
      "Removed only the Context Window Manager project override and state. Effective values now fall through to the remaining Codex configuration layers or built-in defaults.",
      snapshot,
    );
  }
}

async function handleRequest(message) {
  if (message === null || typeof message !== "object" || Array.isArray(message) || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    if (message?.id !== undefined) sendError(message.id, JsonRpcError.INVALID_REQUEST, "Invalid JSON-RPC request.");
    return;
  }

  const { id, method, params } = message;
  if (method === "initialize") {
    if (id === undefined) return;
    clientCapabilities = params?.capabilities && typeof params.capabilities === "object"
      ? params.capabilities
      : {};
    const requestedProtocol = typeof params?.protocolVersion === "string" ? params.protocolVersion : null;
    sendResult(id, {
      protocolVersion: requestedProtocol && SUPPORTED_CORE_PROTOCOLS.has(requestedProtocol) ? requestedProtocol : CORE_PROTOCOL_VERSION,
      capabilities: {
        tools: { listChanged: false },
        resources: { subscribe: false, listChanged: false },
      },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      instructions: "Use show_context_window_slider for the graphical control. The server binds to roots/list when available; on older rootless clients, writes require an opaque grant delivered only to the widget. Settings are project-scoped Codex hints, not a way to enlarge ChatGPT or server-side model capacity.",
    });
    return;
  }

  if (method === "ping") {
    if (id !== undefined) sendResult(id, {});
    return;
  }

  if (method === "tools/list") {
    if (id !== undefined) sendResult(id, { tools });
    return;
  }

  if (method === "resources/list") {
    if (id !== undefined) {
      sendResult(id, {
        resources: [{
          uri: WIDGET_URI,
          name: "Context window graphical control",
          title: "Context Window Slider",
          description: "Interactive project-scoped context and compaction controls.",
          mimeType: RESOURCE_MIME_TYPE,
        }],
      });
    }
    return;
  }

  if (method === "resources/templates/list") {
    if (id !== undefined) sendResult(id, { resourceTemplates: [] });
    return;
  }

  if (method === "resources/read") {
    if (id === undefined) return;
    if (params?.uri !== WIDGET_URI) {
      sendError(id, JsonRpcError.INVALID_PARAMS, "Unknown resource URI.");
      return;
    }
    sendResult(id, {
      contents: [{
        uri: WIDGET_URI,
        mimeType: RESOURCE_MIME_TYPE,
        text: widgetHtml,
        _meta: {
          ui: {
            prefersBorder: true,
            csp: { connectDomains: [], resourceDomains: [] },
          },
          "openai/widgetDescription": "A project-scoped Codex context-window and compaction slider. It cannot increase the host or model hard limit.",
        },
      }],
    });
    return;
  }

  if (method === "tools/call") {
    if (id === undefined) return;
    try {
      const result = await handleToolCall(params, id);
      if (!cancelledClientRequests.has(id)) sendResult(id, result);
    } catch (error) {
      if (!cancelledClientRequests.has(id)) sendResult(id, errorToolResult(error));
    } finally {
      cancelledClientRequests.delete(id);
    }
    return;
  }

  if (method === "notifications/cancelled") {
    const requestId = params?.requestId;
    if (typeof requestId === "string" || typeof requestId === "number") cancelledClientRequests.add(requestId);
    return;
  }
  if (method === "notifications/initialized" || method === "notifications/roots/list_changed") return;
  if (id !== undefined) sendError(id, JsonRpcError.METHOD_NOT_FOUND, `Method not found: ${method}`);
}

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

lines.on("line", (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    sendError(null, JsonRpcError.PARSE_ERROR, "Invalid JSON.");
    return;
  }

  if (message?.method === undefined && message?.id !== undefined) {
    if (pendingRequests.has(message.id)) {
      const pending = pendingRequests.get(message.id);
      pendingRequests.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message ?? "MCP host request failed."));
      else pending.resolve(message.result);
    }
    return;
  }

  void handleRequest(message).catch((error) => {
    if (message?.id !== undefined) {
      sendError(message.id, JsonRpcError.INTERNAL_ERROR, error instanceof Error ? error.message : String(error));
    }
  });
});
