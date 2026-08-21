# Context Window Manager for Codex

[![CI](https://github.com/yuweiyang9611/CodexContextPlugin/actions/workflows/ci-release.yml/badge.svg)](https://github.com/yuweiyang9611/CodexContextPlugin/actions/workflows/ci-release.yml)

An unofficial, Windows-first Codex plugin for managing project-scoped context-window and automatic-compaction settings. It provides an in-conversation graphical slider, safe presets, a PowerShell CLI, and a bundled skill that explains the limits before changing configuration.

> [!IMPORTANT]
> This plugin does not unlock or increase a model, account, or server-side context limit. It writes project-level Codex configuration requests; the effective host limit always wins. Changes do not resize the current task and normally require a new task or an app restart.

## Features

- Graphical presets for Auto, 128K, 400K, 1.05M, and custom values.
- Configurable automatic-compaction threshold and scope.
- Project-scoped writes to `.codex/config.toml`; no global Codex configuration changes.
- Exact-model lookup against a bundled, dated catalog before enabling the 1.05M preset.
- Conservative TOML conflict detection, project locks, atomic replacement, rollback, and hash-based concurrency checks.
- `roots/list` binding in supported MCP hosts so the graphical tool cannot silently target an unrelated workspace.
- A heuristic repository/file context estimator.
- No npm packages, telemetry, or runtime network requests.

## Requirements

- Windows 10 or Windows 11.
- Codex desktop with plugin and local MCP support.
- Windows PowerShell 5.1 or later.
- Node.js supplied by Codex, or an existing local Node.js installation for the MCP server.

The runtime uses only Node.js built-in modules and Windows PowerShell. No `npm install` is required.

## Install from GitHub

Clone the repository:

```powershell
git clone https://github.com/yuweiyang9611/CodexContextPlugin.git
cd CodexContextPlugin
```

Register the clone as a local marketplace, using its absolute path:

```powershell
codex plugin marketplace add "C:\absolute\path\to\CodexContextPlugin"
```

Open the Codex Plugins Directory, install **Context Window Manager** from the registered marketplace, and restart Codex if prompted. Trust the target project and start a new task before testing the plugin.

GitHub publication makes the source public; it does not by itself publish the plugin to the universal ChatGPT/Codex plugin directory.

## Use the graphical control

In a Codex task, ask:

```text
Open the context-window slider for this project.
```

Preset or slider changes remain a draft until the user confirms the write twice. Reset also requires confirmation and removes only this plugin's managed configuration block and state file.

When the MCP host advertises workspace roots, an explicit project path must exactly match one of those roots. A multi-root workspace may select any advertised root, but the plugin cannot arbitrarily write to an unrelated directory. Older rootless hosts allow explicit-path reads; writes require a short-lived authorization issued only to the graphical widget and bound to that project.

## Use the PowerShell manager

Check the current project first:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\plugins\context-window-manager\scripts\context-window.ps1 `
  status -Model <active-model-slug>
```

Apply a preset:

```powershell
# 128K window / 96K compaction threshold
.\plugins\context-window-manager\scripts\context-window.ps1 `
  apply -Profile compact -Model <active-model-slug>

# 400K window / 320K compaction threshold
.\plugins\context-window-manager\scripts\context-window.ps1 `
  apply -Profile balanced -Model <active-model-slug>

# 1,050,000 window / 850K compaction threshold
.\plugins\context-window-manager\scripts\context-window.ps1 `
  apply -Profile 1m -Model <active-model-slug>
```

The `1m` preset is accepted only when the exact model ID has at least 1,050,000 tokens in the bundled catalog. That catalog is not live detection of the user's Codex plan or host limit.

Target another trusted local project explicitly:

```powershell
.\plugins\context-window-manager\scripts\context-window.ps1 `
  status -ProjectRoot "D:\path\to\project" -Model <active-model-slug>
```

Remove only this plugin's project override:

```powershell
.\plugins\context-window-manager\scripts\context-window.ps1 reset
```

Estimate a set of files before loading them into context:

```powershell
.\plugins\context-window-manager\scripts\context-window.ps1 `
  estimate -Path .\src,.\docs -Json
```

## What it writes

For a non-Auto profile, the manager writes a marked block at the top of the target project's `.codex/config.toml`:

```toml
# >>> context-window-manager (managed; use the plugin to edit)
# requested_profile = "balanced"
# resolved_model = "<active-model-slug>"
model_context_window = 400000
model_auto_compact_token_limit = 320000
model_auto_compact_token_limit_scope = "total"
# <<< context-window-manager
```

It may also create these project-local files while operating:

- `.codex/context-window-manager.json` for validated manager state.
- `.codex/.context-window-manager.lock` for cross-process serialization.
- Same-directory temporary or backup files during an atomic update or recovery.

Content outside the managed block is preserved. If the existing TOML contains conflicting context keys, malformed markers, unexpected managed-block content, or unsafe reparse points, the manager refuses to overwrite it.

## Security and privacy

- The plugin modifies only the selected project's `.codex` files.
- It does not change `model = ...` or choose a model for the user.
- It does not send project contents, configuration, or telemetry over the network.
- The MCP server validates local roots and rejects relative paths, filesystem roots, UNC roots, missing directories, and direct symbolic-link project roots.
- Project trust is enforced by Codex. A successful file write does not prove that Codex loaded the setting.
- Review the source and the exact requested file changes before granting write access.

## Test

The regression suites use PowerShell and Node.js built-in tooling:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\context-window.tests.ps1

node --test .\tests\context-window-mcp.tests.mjs

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\release-automation.tests.ps1
```

## Versioning and automated releases

The release gate is the SemVer value in `plugins/context-window-manager/.codex-plugin/plugin.json`. Its build metadata is ignored for public releases:

```text
0.2.0+codex.local-build  ->  v0.2.0
```

Every push and pull request runs package validation plus the PowerShell and Node.js regression suites. On a push to `main`, automation compares the manifest's release version before and after that push. It creates a GitHub Release only when the SemVer release portion changed and the new tag is not already owned by another commit. Ordinary commits, including cachebuster-only changes after `+`, run CI but do not create a Release. The commit that first adds this automation establishes a baseline and does not publish the existing version.

Use the version helper when a public release is intended:

```powershell
# Accepts 0.2.1 or v0.2.1 and updates the manifest, MCP server, and widget together.
.\scripts\set-version.ps1 0.2.1
```

Commit those version changes and merge them into `main`. After CI succeeds, automation publishes:

- `context-window-manager-vX.Y.Z.zip` — the standalone plugin directory.
- `CodexContextPlugin-vX.Y.Z.zip` — the installable local-marketplace layout.
- `SHA256SUMS.txt` — SHA-256 checksums for both archives.

For example, six commits can remain on `0.2.0` without producing new releases. Running `set-version.ps1 0.2.1` and merging that change creates `v0.2.1` exactly once.

## Repository layout

```text
.github/workflows/ci-release.yml
.agents/plugins/marketplace.json
plugins/context-window-manager/
  .codex-plugin/plugin.json
  .mcp.json
  hooks/hooks.json
  mcp/server.mjs
  scripts/context-window.ps1
  scripts/launch-context-window-mcp.cmd
  scripts/model-capabilities.json
  skills/dynamic-context/
  ui/context-window-control.html
scripts/
  build-release.ps1
  resolve-version-change.ps1
  set-version.ps1
tests/
  validate-package.ps1
```

## 中文说明

这是一个面向 Windows Codex 桌面端的非官方项目级上下文配置插件。它可以通过图形滑块或 PowerShell 管理目标项目的上下文预算和自动压缩阈值，也可以用 `-ProjectRoot` 指定其他可信本地项目。

插件只写目标项目的 `.codex/config.toml` 和自身状态文件，不能扩大模型、账户或服务端的真实上下文硬上限，也不会改变当前任务。项目必须在 Codex 中受信任，修改后通常需要新建任务或重启应用。

## License

[MIT](LICENSE)

This is an independent project and is not affiliated with or endorsed by OpenAI. Codex, ChatGPT, and OpenAI are trademarks of OpenAI.
