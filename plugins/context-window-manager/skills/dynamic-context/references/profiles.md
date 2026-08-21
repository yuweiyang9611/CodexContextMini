# Context profiles

Read this file only when inspecting or changing a context profile.

| Profile | Project override | Intended use |
| --- | --- | --- |
| `auto` | Removes this plugin's project override; effective values fall through to remaining project entries, other Codex configuration layers, or built-in model defaults. | Recommended fallback for unknown models. |
| `compact` | Caps the working window at 128,000 and compacts at 96,000 (or uses a smaller bundled catalog value). | Fast, low-risk work or noisy tool output. |
| `balanced` | Caps the working window at 400,000 and compacts at 320,000 (or uses a smaller bundled catalog value). | Long coding and research tasks with room for output. |
| `1m` | Requests 1,050,000 tokens and compacts at 850,000. | Only an exact API-model catalog entry documented with at least a 1.05M window; the host limit may be smaller. |
| `custom` | Uses explicit `-Tokens` and optional `-CompactAt`. | Custom providers or deliberately constrained budgets. |

The bundled model table is a dated API-model safety allow-list, not live discovery of the ChatGPT/Codex host or account limit. The manager currently lists the GPT-5.6, GPT-5.5, and GPT-5.4 families at 1,050,000 tokens. It also includes several smaller official API model slugs so it can reject an unsafe `1m` request. Unknown models stay unknown, and the effective host limit may be smaller than a listed API value.

`-Force` bypasses the allow-list but cannot change server behavior. Use it only when the user explicitly controls a custom provider and confirms its real capacity.

The manager owns only this block in `.codex/config.toml`:

```toml
# >>> context-window-manager (managed; use the plugin to edit)
# requested_profile = "1m"
# resolved_model = "gpt-5.6-sol"
# resolved_capacity = "1050000"
model_context_window = 1050000
model_auto_compact_token_limit = 850000
model_auto_compact_token_limit_scope = "total"
# <<< context-window-manager
```

It conservatively refuses to add the block if potentially conflicting keys or tables, including quoted and dotted forms, exist outside it. This avoids duplicate TOML keys and preserves user-owned configuration.
