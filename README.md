# Context Mini

[![CI](https://github.com/yuweiyang9611/CodexContextMini/actions/workflows/ci-release.yml/badge.svg)](https://github.com/yuweiyang9611/CodexContextMini/actions/workflows/ci-release.yml)

Context Mini is an independent Windows WPF application for managing global defaults and project-scoped Codex context-window and automatic-compaction requests. It is not a Codex plugin and contains no MCP server, skill, marketplace package, HTML widget, or plugin runtime.

> [!IMPORTANT]
> Context Mini cannot unlock or increase a model, account, or server-side context limit. It writes user-level or project-level client configuration requests. The effective host limit always wins, and changes normally require a new Codex task or app restart.

## Download and requirements

- Windows x64.
- For project overrides, the target project must be trusted by Codex before its `.codex/config.toml` is loaded. Global defaults do not depend on trusting an individual project.

Choose one ZIP from the GitHub Release:

- **Recommended:** `ContextMini-vX.Y.Z-win-x64-self-contained.zip` includes the required .NET runtime. It is the larger download, but does not require a separate .NET installation. Its root `THIRD-PARTY-NOTICES.txt` includes the complete notices for the runtime packs actually shipped in that ZIP; `RUNTIME-PACKS.json` and `runtime-notices/` preserve package source, version, license, notice path, and SHA-256 provenance.
- **Smaller:** `ContextMini-vX.Y.Z-win-x64.zip` is framework-dependent and requires the [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0).

Release downloads are published at [GitHub Releases](https://github.com/yuweiyang9611/CodexContextMini/releases) only after the version is changed manually.

Each Release also contains `SHA256SUMS.txt`. Download it beside the selected ZIP, substitute the real version in `$zip`, and verify the download in PowerShell:

```powershell
$zip = 'ContextMini-vX.Y.Z-win-x64-self-contained.zip'
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$entries = @(Get-Content -LiteralPath .\SHA256SUMS.txt | Where-Object {
    $_ -cmatch ('^[0-9a-f]{64}  ' + [regex]::Escape($zip) + '$')
})
if ($entries.Count -ne 1) { throw "Expected one checksum entry for $zip." }
$expected = $entries[0].Substring(0, 64)
if ($actual -cne $expected) { throw "SHA-256 verification failed for $zip." }
"SHA-256 verified: $actual"
```

The release executables are currently **not code-signed**. Windows Defender SmartScreen may therefore show an unknown-publisher warning, especially for a new release. Confirm that the ZIP came from this repository's GitHub Release and that its SHA-256 matches before running it; stop if either check fails.

## Build and run

The source build is pinned to `.NET SDK 10.0.400` and has no third-party NuGet packages.

```powershell
# Restore and build the WPF app, Core library, and tests.
.\build.cmd

# Run the Core, WPF, appearance, and maintenance regression suites.
.\test.cmd -NoBuild

# Publish a small framework-dependent win-x64 bundle.
.\publish.cmd

# Or publish a larger self-contained win-x64 bundle.
.\publish.cmd -SelfContained

# Launch the published app to edit global defaults.
.\START-MINI.cmd
```

The self-contained publish restores Microsoft's Windows runtime packs from `https://api.nuget.org/v3/index.json`; it may require network access when those packs are not cached. Packaging reads the final `ContextMini.deps.json`, so its license and notice inventory covers exactly the runtime packs present in the application dependency manifest, not every pack that happened to be restored. Notice bodies with identical content hashes are included once in the root notice file. The smaller framework-dependent ZIP intentionally has no bundled runtime-pack notices because it ships no .NET runtime. The application itself still has no third-party NuGet package dependencies.

You can also pass a project explicitly:

```powershell
.\.artifacts\publish\win-x64\ContextMini.exe "D:\path\to\trusted-project"
```

When launched without arguments (or with `--global`), Context Mini opens **全局默认**. `START-MINI.cmd` behaves the same way and forwards explicit arguments. Recent projects are still available from the list, but never replace global mode at startup. The window keeps up to eight recent projects and includes **全局默认** and **选择项目…** buttons. Switching scope or project asks before discarding an unapplied draft.

## Global defaults for new conversations

1. Open Context Mini without arguments, or click **全局默认**.
2. Select a preset or enter the context window and automatic-compaction threshold.
3. Click **确认并应用**, verify the displayed scope and exact file path, and confirm.
4. Restart Codex if it is already running, then create a new conversation.

Global mode writes `%USERPROFILE%\.codex\config.toml` by default. If `CODEX_HOME` is set in Context Mini's environment, it writes `%CODEX_HOME%\config.toml` instead (not a nested `.codex` directory). The override must be an absolute local path; when its final directory does not exist, its parent must already exist. Context Mini and the Codex client must use the same Codex home. Loading and monitoring do not create files or directories.

These settings provide defaults for new conversations in local Codex clients that read this user configuration. They do not rewrite existing conversations or configure remote hosts/cloud tasks. Project settings, selected profiles, CLI overrides, and organization requirements can still take precedence. To let a project inherit the global default, open that project and choose **Auto** to remove its Mini-managed override. Other manually defined overrides must be resolved separately. See the official [configuration precedence](https://learn.chatgpt.com/docs/config-file/config-basic).

**Auto in global mode** removes only the global Mini-managed block; **Auto in project mode** removes only that project's Mini-managed block. Neither action resets all Codex settings. Existing manual context keys, duplicate markers, and malformed blocks stay read-only; use **打开 config.toml** to inspect and resolve them before applying. The app never silently takes ownership of existing manual settings.

## Appearance

The header offers three color schemes: **跟随系统**, **白色**, and **黑色**. System mode follows the current Windows app theme while the program is running. The selected preference is stored in `%LOCALAPPDATA%\ContextMini\appearance.txt`; it is never written into the selected project. Windows high-contrast mode temporarily takes priority and uses system colors.

## Profiles

| Profile | Context request | Auto-compact threshold |
| --- | ---: | ---: |
| Auto | Remove the Mini-managed override | Inherit remaining Codex configuration |
| 128K | 128,000 | 96,000 |
| 400K | 400,000 | 320,000 |
| 1.05M | 1,050,000 | 850,000 |
| Custom | 8,192–1,050,000 | Independently editable below the window value |

Preset, slider, and exact-value changes remain an in-memory draft. Moving the slider proposes an approximately 80% compaction threshold; both values can then be edited independently. When an existing managed block uses `body_after_prefix`, size presets and custom edits preserve that scope. Nothing is written until **确认并应用** is clicked and the managed-block preview is confirmed.

If `config.toml` changes externally while a draft is dirty, Context Mini preserves the draft and offers three explicit choices: rebase it onto the latest disk snapshot, inspect the external change, or discard the draft. Reloading a dirty draft uses the same preserve/discard/cancel decision instead of silently replacing it.

## Configuration boundary

Context Mini manages only this block at the beginning of the selected global or project `config.toml`:

```toml
# >>> codex-context-mini:v1
model_context_window = 400000
model_auto_compact_token_limit = 320000
model_auto_compact_token_limit_scope = "total"
# <<< codex-context-mini:v1
```

Auto removes only the managed block. Content outside it is preserved. A valid legacy `context-window-manager` block can be read and is migrated to the Mini format on the next apply; its `total` or `body_after_prefix` compaction scope is preserved. Malformed, duplicated, mixed, or conflicting keys remain read-only.

## Safety

- Rejects missing, UNC, mapped-network-drive, filesystem-root, and reparse-point project paths.
- Browsing and monitoring are read-only; `.codex` is created only when an actual write is needed.
- Enforces strict UTF-8 and a 2 MiB `config.toml` safety limit.
- Preserves UTF-8 BOM, CRLF/LF, comments, tables, and all bytes outside the managed block.
- Uses a project lock, SHA-256 baseline, Windows volume/file identity checks, same-directory temporary file, metadata-preserving atomic replace/move, rollback, and post-write byte verification.
- Refuses to overwrite external changes, malformed markers, unknown managed content, or manually defined context keys.
- Monitors the selected configuration every 1.5 seconds with background I/O. External changes refresh a clean view or preserve and lock a dirty draft until the user explicitly resolves it.

## Tests

```powershell
# Context configuration Core, global targets, and appearance settings: 36 regression cases
dotnet run --project .\tests\ContextMini.Tests\ContextMini.Tests.csproj -c Release

# WPF themes, layout, exact input, session races, rebase, preview, startup, global scope, and recent projects: 19 cases
dotnet run --project .\tests\ContextMini.WpfTests\ContextMini.WpfTests.csproj -c Release

# Light/Dark resource symmetry, dynamic references, and contrast thresholds
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\appearance-xaml.tests.ps1

# Repository email privacy hooks
node --test .\tests\email-policy.tests.mjs

# Manual release, deterministic packaging, runtime-license, and GitHub-state behavior
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\release-automation.tests.ps1

# Dependabot GitHub Actions/.NET SDK policy and CodeQL least privilege: 3 cases
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\maintenance-automation.tests.ps1
```

CI builds the WPF XAML on Windows, runs all tests, validates every workflow with a fixed-version actionlint archive whose official SHA-256 is pinned, and inspects both release ZIP manifests on every push and pull request. Release ZIP entries use a stable ordinal order and fixed timestamp. A main-branch Release publishes the tested assets rather than rebuilding them, then downloads every remote asset and checks it against GitHub's recorded SHA-256 digest. Newly created or automatically recovered same-commit Releases are also compared byte-for-byte with the tested assets. Signed release-asset attestation verification runs only when GitHub reports that the Release is immutable; mutable Releases have digest verification but no attestation guarantee.

CodeQL performs a scheduled and push/pull-request C# analysis using the real Windows WPF build. Dependabot checks immutable GitHub Actions references and the exact `global.json` .NET SDK weekly, opening reviewable update pull requests for both.

## Versioning and releases

`VERSION` is the single public version source. Ordinary code changes do not create Releases.

```powershell
# Example: the next intentional release
.\scripts\set-version.ps1 0.2.1
```

CI independently rejects a direct `VERSION` edit unless it is strictly greater than the previous release SemVer.

After the VERSION change reaches `main` and CI passes, automation publishes exactly:

- `ContextMini-vX.Y.Z-win-x64.zip`
- `ContextMini-vX.Y.Z-win-x64-self-contained.zip`
- `SHA256SUMS.txt`

The first commit that introduces `VERSION` establishes a baseline and does not publish automatically.

## Email privacy hooks

Enable the committed hooks once after cloning:

```powershell
.\.githubhooks\install.ps1
```

They block non-approved email addresses in Git identity, commit messages, staged raw blobs and paths, tags/refs, and commits before push. CI audits the tested commit and its complete reachable history; unrelated fetched branches are checked in their own runs. See [`.githubhooks/README.md`](.githubhooks/README.md).

## Repository layout

```text
src/ContextMini.Core/       Global/project targets, safe config parser and atomic store
src/ContextMini/            WPF desktop application
tests/ContextMini.Tests/    Zero-dependency Core regression runner
tests/ContextMini.WpfTests/ WPF theme, layout, and workflow-state regression runner
tests/appearance-xaml.tests.ps1
tests/release-automation.tests.ps1
tests/maintenance-automation.tests.ps1
tests/email-policy.tests.mjs
scripts/                    Build, test, publish, version, reusable Release validation
.githubhooks/               Email privacy policy and local Git hooks
.github/workflows/          Windows CI, version-gated Release, and CodeQL
```

## License

[MIT](LICENSE)

This independent project is not affiliated with or endorsed by OpenAI. Codex, ChatGPT, and OpenAI are trademarks of OpenAI.
