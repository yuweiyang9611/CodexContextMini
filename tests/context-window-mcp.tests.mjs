import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE_ROOT = path.resolve(__dirname, "..");
const PLUGIN_ROOT = path.join(WORKSPACE_ROOT, "plugins", "context-window-manager");
const SERVER_PATH = path.join(PLUGIN_ROOT, "mcp", "server.mjs");
const TEMP_PREFIX = path.join(__dirname, ".tmp-context-window-mcp-");
const MCP_CONFIG = JSON.parse(readFileSync(path.join(PLUGIN_ROOT, ".mcp.json"), "utf8"));
const MCP_LAUNCH = MCP_CONFIG.mcpServers.context_window_manager;

class McpHarness {
  constructor(rootProvider) {
    this.rootProvider = rootProvider;
    this.nextId = 1;
    this.pending = new Map();
    this.messages = [];
    this.stderr = "";
    this.child = spawn(MCP_LAUNCH.command, MCP_LAUNCH.args, {
      cwd: PLUGIN_ROOT,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => { this.stderr += chunk; });
    this.lines = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    this.lines.on("line", (line) => this.onLine(line));
  }

  onLine(line) {
    const message = JSON.parse(line);
    this.messages.push(message);

    if (message.method === "roots/list" && message.id !== undefined) {
      const roots = this.rootProvider();
      this.send({ jsonrpc: "2.0", id: message.id, result: { roots } });
      return;
    }

    if (message.id !== undefined && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      pending.resolve(message);
    }
  }

  send(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  sendRaw(line) {
    this.child.stdin.write(`${line}\n`);
  }

  request(method, params = {}, id = this.nextId++) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for ${method}`));
      }, 10_000);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  async initialize({ roots = true } = {}) {
    const response = await this.request("initialize", {
      protocolVersion: "2025-11-25",
      capabilities: roots ? { roots: { listChanged: true } } : {},
      clientInfo: { name: "context-window-manager-tests", version: "1.0.0" },
    }, "initialize-id");
    assert.equal(response.result.serverInfo.name, "Context Window Manager");
    assert.equal(response.result.protocolVersion, "2025-11-25");
    this.send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    return response;
  }

  async close() {
    this.child.stdin.end();
    const exitCode = await new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.child.kill();
        resolve("timeout");
      }, 5_000);
      this.child.once("exit", (code) => {
        clearTimeout(timer);
        resolve(code);
      });
    });
    assert.notEqual(exitCode, "timeout", "MCP server should exit on stdin EOF");
  }
}

test("Context Window Manager MCP protocol and safe write round trip", async (t) => {
  const projectRoot = mkdtempSync(TEMP_PREFIX);
  assert.ok(projectRoot.startsWith(__dirname + path.sep), "temporary project must stay under tests/");
  let roots = [{ uri: pathToFileURL(projectRoot).href, name: "test-project" }];
  const harness = new McpHarness(() => roots);

  t.after(async () => {
    await harness.close();
    assert.equal(harness.stderr, "", `MCP stderr should be empty, got: ${harness.stderr}`);
    assert.ok(projectRoot.startsWith(__dirname + path.sep));
    rmSync(projectRoot, { recursive: true, force: true });
  });

  await t.test("initialize, list tools, and read the versioned UI resource", async () => {
    const manifest = JSON.parse(readFileSync(path.join(PLUGIN_ROOT, ".codex-plugin", "plugin.json"), "utf8"));
    const mcpConfig = MCP_CONFIG;
    assert.equal(manifest.mcpServers, "./.mcp.json");
    assert.equal(manifest.apps, undefined);
    assert.equal(existsSync(path.join(PLUGIN_ROOT, ".app.json")), false);
    assert.equal(mcpConfig.mcpServers.context_window_manager.command, "cmd.exe");
    assert.deepEqual(mcpConfig.mcpServers.context_window_manager.args.slice(-2), ["./scripts/launch-context-window-mcp.cmd", "./mcp/server.mjs"]);
    assert.ok(mcpConfig.mcpServers.context_window_manager.env_vars.includes("CODEX_MCP_NODE_PATH"));
    assert.equal(existsSync(path.join(PLUGIN_ROOT, "scripts", "launch-context-window-mcp.cmd")), true);
    assert.equal(existsSync(SERVER_PATH), true);

    const fallbackVersion = await harness.request("initialize", {
      protocolVersion: "2099-01-01",
      capabilities: { roots: { listChanged: true } },
      clientInfo: { name: "future-client", version: "1.0.0" },
    }, "future-version");
    assert.equal(fallbackVersion.result.protocolVersion, "2025-11-25");

    const initialized = await harness.initialize();
    assert.equal(initialized.result.capabilities.resources.subscribe, false);

    const listed = await harness.request("tools/list", {}, 2);
    const names = listed.result.tools.map((tool) => tool.name);
    assert.deepEqual(names, [
      "get_context_window_status",
      "apply_context_window_profile",
      "reset_context_window_profile",
      "show_context_window_slider",
    ]);
    const renderTool = listed.result.tools.find((tool) => tool.name === "show_context_window_slider");
    assert.equal(renderTool._meta.ui.resourceUri, "ui://context-window-manager/control-v1.html");
    assert.equal(renderTool.annotations.readOnlyHint, true);

    const resources = await harness.request("resources/list", {}, "resources-list");
    assert.equal(resources.result.resources[0].mimeType, "text/html;profile=mcp-app");
    const resource = await harness.request("resources/read", { uri: resources.result.resources[0].uri }, 4);
    const content = resource.result.contents[0];
    assert.equal(content.mimeType, "text/html;profile=mcp-app");
    assert.match(content.text, /id="window-range"/u);
    assert.match(content.text, /ui\/initialize/u);
    assert.match(content.text, /apply_context_window_profile/u);
    assert.deepEqual(content._meta.ui.csp.connectDomains, []);
    assert.doesNotMatch(content.text, /<script[^>]+src=/iu);
    assert.doesNotMatch(content.text, /<link[^>]+href=/iu);
  });

  await t.test("render tool binds to roots/list and remains read-only", async () => {
    const response = await harness.request("tools/call", {
      name: "show_context_window_slider",
      arguments: { projectRoot, model: "gpt-5.6-sol" },
    }, 5);
    assert.equal(response.result.isError, undefined);
    assert.equal(response.result.structuredContent.kind, "context-window-control");
    assert.equal(response.result.structuredContent.status.projectRoot, projectRoot);
    assert.equal(response.result.structuredContent.status.modelKnown, true);
    assert.equal(response.result._meta["openai/outputTemplate"], "ui://context-window-manager/control-v1.html");
    assert.equal(existsSync(path.join(projectRoot, ".codex")), false);
  });

  await t.test("custom apply writes only the host root and returns authoritative status", async () => {
    const response = await harness.request("tools/call", {
      name: "apply_context_window_profile",
      arguments: {
        projectRoot,
        profile: "custom",
        model: "gpt-5.6-sol",
        tokens: 600000,
        compactAt: 480000,
        scope: "body_after_prefix",
      },
    }, "apply-custom");
    assert.equal(response.result.isError, undefined);
    const output = response.result.structuredContent;
    assert.equal(output.status.profile, "custom");
    assert.equal(output.status.configuredWindowTokens, 600000);
    assert.equal(output.status.configuredCompactAtTokens, 480000);
    assert.equal(output.status.configuredCompactScope, "body_after_prefix");
    assert.equal(output.action.restartRequired, true);

    const configPath = path.join(projectRoot, ".codex", "config.toml");
    const config = readFileSync(configPath, "utf8");
    assert.match(config, /model_context_window = 600000/u);
    assert.match(config, /model_auto_compact_token_limit = 480000/u);
    assert.match(config, /model_auto_compact_token_limit_scope = "body_after_prefix"/u);
  });

  await t.test("unknown model and mismatched roots are rejected without changing config", async () => {
    const configPath = path.join(projectRoot, ".codex", "config.toml");
    const before = readFileSync(configPath, "utf8");

    const unknown = await harness.request("tools/call", {
      name: "apply_context_window_profile",
      arguments: { projectRoot, profile: "1m", model: "not-in-catalog" },
    }, 7);
    assert.equal(unknown.result.isError, true);
    assert.match(unknown.result.structuredContent.error, /Refusing the 1m profile/u);
    assert.equal(readFileSync(configPath, "utf8"), before);

    const extraArgument = await harness.request("tools/call", {
      name: "apply_context_window_profile",
      arguments: { projectRoot, profile: "1m", model: "gpt-5.6-sol", force: true },
    }, "extra-argument");
    assert.equal(extraArgument.result.isError, true);
    assert.match(extraArgument.result.structuredContent.error, /Unsupported argument: force/u);
    assert.equal(readFileSync(configPath, "utf8"), before);

    const injectedModel = await harness.request("tools/call", {
      name: "get_context_window_status",
      arguments: { projectRoot, model: "good-model\nprofile = '1m'" },
    }, "injected-model");
    assert.equal(injectedModel.result.isError, true);
    assert.match(injectedModel.result.structuredContent.error, /control characters/u);
    assert.equal(readFileSync(configPath, "utf8"), before);

    const differentRoot = path.join(projectRoot, "nested");
    const mismatch = await harness.request("tools/call", {
      name: "get_context_window_status",
      arguments: { projectRoot: differentRoot, model: "gpt-5.6-sol" },
    }, 8);
    assert.equal(mismatch.result.isError, true);
    assert.match(mismatch.result.structuredContent.error, /does not exist|does not match/u);
    assert.equal(readFileSync(configPath, "utf8"), before);
  });

  await t.test("reset preserves protocol behavior and removes only plugin state", async () => {
    const response = await harness.request("tools/call", {
      name: "reset_context_window_profile",
      arguments: { projectRoot, model: "gpt-5.6-sol" },
    }, 9);
    assert.equal(response.result.isError, undefined);
    assert.equal(response.result.structuredContent.status.managedBlockPresent, false);
    assert.equal(response.result.structuredContent.status.profile, "not configured");
    assert.equal(existsSync(path.join(projectRoot, ".codex", "context-window-manager.json")), false);
  });

  await t.test("host roots bind directly and rootless hosts require a widget-only write grant", async () => {
    roots = [
      { uri: pathToFileURL(projectRoot).href },
      { uri: pathToFileURL(WORKSPACE_ROOT).href },
    ];
    const ambiguous = await harness.request("tools/call", {
      name: "get_context_window_status",
      arguments: { model: "gpt-5.6-sol" },
    }, 10);
    assert.equal(ambiguous.result.isError, true);
    assert.match(ambiguous.result.structuredContent.error, /Exactly one/u);

    const selectedFromMany = await harness.request("tools/call", {
      name: "get_context_window_status",
      arguments: { projectRoot, model: "gpt-5.6-sol" },
    }, "selected-from-many");
    assert.equal(selectedFromMany.result.isError, undefined);
    assert.equal(selectedFromMany.result.structuredContent.status.projectRoot, projectRoot);

    roots = [{ uri: pathToFileURL(projectRoot).href }];
    await harness.initialize({ roots: false });
    const explicitRead = await harness.request("tools/call", {
      name: "get_context_window_status",
      arguments: { projectRoot },
    }, 11);
    assert.equal(explicitRead.result.isError, undefined);
    assert.equal(explicitRead.result.structuredContent.accessBinding, "explicit-readonly");

    const missingGrant = await harness.request("tools/call", {
      name: "apply_context_window_profile",
      arguments: { projectRoot, profile: "auto" },
    }, "missing-grant");
    assert.equal(missingGrant.result.isError, true);
    assert.match(missingGrant.result.structuredContent.error, /Open the graphical slider first/u);

    const rendered = await harness.request("tools/call", {
      name: "show_context_window_slider",
      arguments: { projectRoot, model: "gpt-5.6-sol" },
    }, "rootless-render");
    assert.equal(rendered.result.isError, undefined);
    const grant = rendered.result._meta["context-window-manager/authorization"];
    assert.match(grant.token, /^[a-f0-9]{64}$/u);
    assert.equal(grant.projectRoot, projectRoot);
    assert.doesNotMatch(JSON.stringify(rendered.result.structuredContent), new RegExp(grant.token, "u"));

    const wrongProjectGrant = await harness.request("tools/call", {
      name: "apply_context_window_profile",
      arguments: { projectRoot: WORKSPACE_ROOT, profile: "auto", authorizationToken: grant.token },
    }, "wrong-project-grant");
    assert.equal(wrongProjectGrant.result.isError, true);
    assert.match(wrongProjectGrant.result.structuredContent.error, /bound to a different project/u);

    const authorizedWrite = await harness.request("tools/call", {
      name: "apply_context_window_profile",
      arguments: { projectRoot, profile: "auto", authorizationToken: grant.token },
    }, "authorized-rootless-write");
    assert.equal(authorizedWrite.result.isError, undefined);
    assert.equal(authorizedWrite.result.structuredContent.accessBinding, "widget-authorization");

    const authorizedReset = await harness.request("tools/call", {
      name: "reset_context_window_profile",
      arguments: { projectRoot, authorizationToken: grant.token },
    }, "authorized-rootless-reset");
    assert.equal(authorizedReset.result.isError, undefined);

    const noExplicitRoot = await harness.request("tools/call", {
      name: "show_context_window_slider",
      arguments: { model: "gpt-5.6-sol" },
    }, "rootless-no-path");
    assert.equal(noExplicitRoot.result.isError, true);
    assert.match(noExplicitRoot.result.structuredContent.error, /explicit absolute projectRoot is required/u);
    await harness.initialize({ roots: true });
  });

  await t.test("JSON-RPC errors use clean stdout and accept string IDs", async () => {
    const missing = await harness.request("not/a/method", {}, "string-id");
    assert.equal(missing.error.code, -32601);

    const messageCount = harness.messages.length;
    harness.send({ jsonrpc: "2.0", id: "unknown-server-response", result: {} });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(harness.messages.length, messageCount, "An unknown JSON-RPC response must be ignored without a reply");

    const parsePromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Timed out waiting for parse error")), 3000);
      const check = (message) => {
        if (message.id === null && message.error?.code === -32700) {
          clearTimeout(timeout);
          resolve(message);
        } else {
          setTimeout(() => {
            const found = harness.messages.find((item) => item.id === null && item.error?.code === -32700);
            if (found) { clearTimeout(timeout); resolve(found); }
          }, 10);
        }
      };
      harness.messages.forEach(check);
      harness.lines.once("line", () => {
        const found = harness.messages.find((item) => item.id === null && item.error?.code === -32700);
        if (found) { clearTimeout(timeout); resolve(found); }
      });
    });
    harness.sendRaw("{not-json");
    const parseError = await parsePromise;
    assert.equal(parseError.error.message, "Invalid JSON.");
  });
});
