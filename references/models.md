# Model roster

Verified against `agy models` on 2026-09-18, CLI v1.2.6.

## Tier mapping

| Tier | Model ID | Fallbacks when out of capacity |
|---|---|---|
| Supreme | `gemini-3.8-flash-high` | `gemini-3.7-flash-high`, `gemini-3.1-pro-high` |
| Smart | `gemini-3.8-flash-medium` | `gemini-3.7-flash-medium`, `gemini-3.6-flash-medium` |
| Basic | `gemini-3.8-flash-low` | `gemini-3.7-flash-low`, `gemini-3.6-flash-low` |
| Claudeman | `claude-opus-4-6-thinking` | `claude-sonnet-4-6` |
| Mini Claudeman | `claude-sonnet-4-6` | `claude-opus-4-6-thinking` |
| Dumbest | `gpt-oss-120b-medium` | `gemini-3.6-flash-low` |

## Full list as reported by the CLI

```
gemini-3.8-flash-high      Gemini 3.8 Flash (High)
gemini-3.8-flash-medium    Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low       Gemini 3.8 Flash (Low)
gemini-3.7-flash-high      Gemini 3.7 Flash (High)
gemini-3.7-flash-medium    Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low       Gemini 3.7 Flash (Low)
gemini-3.6-flash-high      Gemini 3.6 Flash (High)
gemini-3.6-flash-medium    Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low       Gemini 3.6 Flash (Low)
gemini-3.1-pro-high        Gemini 3.1 Pro (High)
gemini-3.1-pro-low         Gemini 3.1 Pro (Low)
claude-sonnet-4-6          Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking   Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium        GPT-OSS 120B (Medium)
```

Refresh with `agy models`. If a call fails with an unknown-model error, this
file is stale — re-read the live list before guessing.

## On effort

The `-high` / `-medium` / `-low` suffix **is** the effort setting. There is no
separate knob to turn:

- `--model gemini-3.8-flash-high --effort medium`
  → `error: invalid model selection ... conflicts with --effort=medium`
- `--model claude-sonnet-4-6 --effort low`
  → `error: --effort is not supported for model "claude-sonnet-4-6"`
- `--model gemini-3.1-pro-high --effort high` happens to be accepted, because it
  agrees with the suffix — which makes it pointless.

Rule: pass `--model`, never `--effort`.

## Other subcommands

- `agy models` — list models
- `agy agents` — list agent presets (empty on this machine)
- `agy mcp` — manage MCP servers
- `agy plugin` — manage plugins
- `agy update` — update the CLI
