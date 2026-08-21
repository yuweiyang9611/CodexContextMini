---
name: dynamic-context
description: Inspect and manage project-scoped Codex context budgets, compaction thresholds, and long-context profiles. Use when the user asks about context limits, 1M context, token budgets, automatic compaction, context sizing, or switching context profiles. Never claim to enlarge a model beyond its documented hard limit.
---

# Dynamic Context

Treat the model's server-side context capacity as a hard ceiling. `model_context_window` tells Codex how much of that capacity is available; it does not unlock capacity the selected model lacks.

## Choose the surface

- In ordinary ChatGPT Chat, explain that a plugin cannot change the host model's hard window. Offer context planning only; do not edit Codex configuration.
- In ChatGPT Work, explain that a written Codex configuration affects only later Codex tasks and cannot expand the current Work conversation.
- In Codex on Windows, use the project-scoped manager below only for a trusted project. Its changes stay under the current project's `.codex/` directory. If the project is untrusted, say Codex will ignore project-scoped configuration and do not claim the profile is active.
- On mobile, web, non-Windows, or any surface without local Windows PowerShell, offer context planning only; do not claim the manager ran.

## Inspect or change a profile

When the user asks to open, show, or use a graphical slider in Codex, call the `show_context_window_slider` MCP tool first. The tool renders a project-scoped MCP Apps control with Auto, 128K, 400K, 1.05M, and custom choices. The slider changes only a draft; the user must click twice to confirm an apply or reset. The MCP server binds calls to `roots/list` whenever the host advertises roots. On older rootless clients, opening and status are read-only from an explicit absolute project root, while apply/reset require a short-lived opaque grant delivered only in widget metadata; never invent or request that token from the user.

If the current Codex client does not render MCP Apps UI, fall back to the command-line manager below and state that the graphical control was unavailable. Never represent this Codex-only local UI as a control for an ordinary ChatGPT Chat conversation.

Resolve the manager relative to this file at `../../scripts/context-window.ps1`, then invoke it with Windows PowerShell. Always run `status` before changing configuration when an existing project may already define context keys.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File <manager-path> status -Model <active-model-slug>
```

When the user asks to change a profile, read [profiles.md](references/profiles.md), choose the narrowest matching profile, and run `apply`. Pass the active model slug from session context when available.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File <manager-path> apply -Profile balanced -Model <active-model-slug>
```

For `1m`, proceed only when the active model has an exact entry of at least 1,050,000 tokens in the bundled dated API-model catalog, matching the preset it writes. This lookup is not live detection of the ChatGPT/Codex host or account limit. Do not use `-Force` for an unknown or smaller model unless the user explicitly confirms a custom provider/model whose capacity they control. After a successful change, say that the project must be trusted and a new task or app restart may be needed because model configuration is loaded at session start.

Use `reset` to remove only this plugin's marked config block and state file. Never rewrite unrelated TOML keys.

## Plan large inputs

Use `estimate -Path ...` before loading a large repository or file set. The estimate is heuristic, so reserve output and tool overhead. Prefer selective retrieval and stable anchors (requirements, decisions, interfaces, and test evidence) over placing every file in active context.

Native compaction remains authoritative. Before a risky compaction, preserve unresolved requirements and decisions in a concise checkpoint; after compaction, re-read those anchors rather than assuming every detail survived.

Report the configured budget and, when present, the dated documented API catalog value. Never call that catalog value a detected host hard limit; the effective ChatGPT/Codex account limit remains host-controlled and may be smaller. If the model ID is absent from the catalog, label it unknown instead of presenting a requested number as fact.
