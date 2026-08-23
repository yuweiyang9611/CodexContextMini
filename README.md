# Context Mini

[![CI](https://github.com/yuweiyang9611/CodexContextMini/actions/workflows/ci-release.yml/badge.svg)](https://github.com/yuweiyang9611/CodexContextMini/actions/workflows/ci-release.yml)

Context Mini is an independent Windows WPF application for managing project-scoped Codex context-window and automatic-compaction requests. It is not a Codex plugin and contains no MCP server, skill, marketplace package, HTML widget, or plugin runtime.

> [!IMPORTANT]
> Context Mini cannot unlock or increase a model, account, or server-side context limit. It writes project-level client configuration requests. The effective host limit always wins, and changes normally require a new Codex task or app restart.

## Download and requirements

- Windows x64.
- [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0) for release ZIPs.
- The target project must be trusted by Codex before project-level `.codex/config.toml` is loaded.

Release downloads are published at [GitHub Releases](https://github.com/yuweiyang9611/CodexContextMini/releases) only after the version is changed manually.

## Build and run

The source build is pinned to `.NET SDK 10.0.400` and has no third-party NuGet packages.

```powershell
# Restore and build the WPF app, Core library, and tests.
.\build.cmd

# Run the Core regression suite.
.\test.cmd -NoBuild

# Publish a small framework-dependent win-x64 bundle.
.\publish.cmd

# Launch the published app against the current directory.
.\START-MINI.cmd
```

You can also pass a project explicitly:

```powershell
.\.artifacts\publish\win-x64\ContextMini.exe "D:\path\to\trusted-project"
```

The window includes a **切换…** button for selecting another local project.

## Appearance

The header offers three color schemes: **跟随系统**, **白色**, and **黑色**. System mode follows the current Windows app theme while the program is running. The selected preference is stored in `%LOCALAPPDATA%\ContextMini\appearance.txt`; it is never written into the selected project. Windows high-contrast mode temporarily takes priority and uses system colors.

## Profiles

| Profile | Context request | Auto-compact threshold |
| --- | ---: | ---: |
| Auto | Remove the Mini-managed override | Inherit remaining Codex configuration |
| 128K | 128,000 | 96,000 |
| 400K | 400,000 | 320,000 |
| 1.05M | 1,050,000 | 850,000 |
| Custom | 8,192–1,050,000 | Approximately 80% |

Preset and slider changes remain an in-memory draft. Nothing is written until **确认并应用** is clicked and the target is confirmed.

## Configuration boundary

Context Mini manages only this block at the beginning of the selected project's `.codex/config.toml`:

```toml
# >>> codex-context-mini:v1
model_context_window = 400000
model_auto_compact_token_limit = 320000
model_auto_compact_token_limit_scope = "total"
# <<< codex-context-mini:v1
```

Auto removes only the managed block. Content outside it is preserved. A valid legacy `context-window-manager` block can be read and is migrated to the Mini format on the next apply; malformed, duplicated, mixed, or conflicting keys remain read-only.

## Safety

- Rejects missing, network, filesystem-root, and reparse-point project paths.
- Browsing and monitoring are read-only; `.codex` is created only when an actual write is needed.
- Enforces strict UTF-8 and a 2 MiB `config.toml` safety limit.
- Preserves UTF-8 BOM, CRLF/LF, comments, tables, and all bytes outside the managed block.
- Uses a project lock, SHA-256 baseline, same-directory temporary file, atomic replace/move, rollback, and post-write byte verification.
- Refuses to overwrite external changes, malformed markers, unknown managed content, or manually defined context keys.
- Monitors the selected configuration every 1.5 seconds. External changes refresh a clean view or lock a dirty draft until reload.

## Tests

```powershell
# Context configuration Core and appearance settings: 24 regression cases
dotnet run --project .\tests\ContextMini.Tests\ContextMini.Tests.csproj -c Release

# WPF theme switching, persistence retry, high contrast, and minimum layout: 4 cases
dotnet run --project .\tests\ContextMini.WpfTests\ContextMini.WpfTests.csproj -c Release

# Light/Dark resource symmetry, dynamic references, and contrast thresholds
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\appearance-xaml.tests.ps1

# Repository email privacy hooks
node --test .\tests\email-policy.tests.mjs

# Manual release version gate
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\release-automation.tests.ps1
```

CI builds the WPF XAML on Windows, runs all tests, and smoke-tests the release ZIP on every push and pull request.

## Versioning and releases

`VERSION` is the single public version source. Ordinary code changes do not create Releases.

```powershell
# Example: the next intentional release
.\scripts\set-version.ps1 0.2.1
```

After the VERSION change reaches `main` and CI passes, automation publishes exactly:

- `ContextMini-vX.Y.Z-win-x64.zip`
- `SHA256SUMS.txt`

The first commit that introduces `VERSION` establishes a baseline and does not publish automatically.

## Email privacy hooks

Enable the committed hooks once after cloning:

```powershell
.\.githubhooks\install.ps1
```

They block non-approved email addresses in Git identity, commit messages, staged raw blobs and paths, tags/refs, and commits before push. CI performs the same full-history audit. See [`.githubhooks/README.md`](.githubhooks/README.md).

## Repository layout

```text
src/ContextMini.Core/       Safe config parser and atomic store
src/ContextMini/            WPF desktop application
tests/ContextMini.Tests/    Zero-dependency Core regression runner
tests/email-policy.tests.mjs
scripts/                    Build, test, publish, version, release
.githubhooks/               Email privacy policy and local Git hooks
.github/workflows/          Windows CI and version-gated Release
```

## License

[MIT](LICENSE)

This independent project is not affiliated with or endorsed by OpenAI. Codex, ChatGPT, and OpenAI are trademarks of OpenAI.