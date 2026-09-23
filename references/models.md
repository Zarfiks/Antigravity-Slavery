# Models and tiers

Verified against `agy models` on 2026-09-23, CLI v1.2.7.

## Tier mapping

| Tier | Model | Model ID | Fallbacks when out of capacity |
|---|---|---|---|
| `gemini-high`   | Gemini 3.8 Flash (High)      | `gemini-3.8-flash-high`    | `gemini-3.7-flash-high`, `gemini-3.1-pro-high` |
| `gemini-medium` | Gemini 3.8 Flash (Medium)    | `gemini-3.8-flash-medium`  | `gemini-3.7-flash-medium`, `gemini-3.6-flash-medium` |
| `gemini-low`    | Gemini 3.8 Flash (Low)       | `gemini-3.8-flash-low`     | `gemini-3.7-flash-low`, `gemini-3.6-flash-low` |
| `opus`          | Claude Opus 4.6 (Thinking)   | `claude-opus-4-6-thinking` | `claude-sonnet-4-6` |
| `sonnet`        | Claude Sonnet 4.6 (Thinking) | `claude-sonnet-4-6`        | `claude-opus-4-6-thinking` |
| `gpt-oss`       | GPT-OSS 120B (Medium)        | `gpt-oss-120b-medium`      | `gemini-3.6-flash-low` |

Tier names from v0.1 still work as aliases: `supreme` = `gemini-high`,
`smart` = `gemini-medium`, `basic` = `gemini-low`, `claudeman` = `opus`,
`mini-claudeman` = `sonnet`, `dumbest` = `gpt-oss`.

## Discovery

`scripts/agy-models.sh` builds every tier from the live list:

| Tier | Pattern, newest version first |
|---|---|
| `gemini-high` | `gemini-*-flash-high`, then `gemini-*-pro-high` |
| `gemini-medium` | `gemini-*-flash-medium`, then `gemini-*-pro-low` |
| `gemini-low` | `gemini-*-flash-low` |
| `opus` | `claude-opus-*`, then `claude-sonnet-*` |
| `sonnet` | `claude-sonnet-*`, then `claude-opus-*` |
| `gpt-oss` | `gpt-oss-*`, then the oldest `gemini-*-flash-low` |

The list is cached for `AGY_MODELS_TTL` seconds (default 86400);
`--refresh` re-reads it. The "Tier mapping" table above is the fallback used
only when discovery fails.

## When the list changes

Model ids rotate. Do not edit the script to follow them. Override a tier's
chain with an environment variable named `AGY_CHAIN_<TIER>` (upper case,
`-` becomes `_`):

```bash
export AGY_CHAIN_GEMINI_HIGH="gemini-3.9-flash-high gemini-3.8-flash-high"
export AGY_CHAIN_OPUS="claude-opus-5-thinking claude-opus-4-6-thinking"
```

Or pass a raw model id instead of a tier name:

```bash
scripts/agy-slave.sh gemini-3.1-pro-high "..." ./repo
```

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

Your account may see a different list. Run `agy models` to check.

## On effort

The `-high` / `-medium` / `-low` suffix **is** the effort setting. There is no
separate knob:

- `--model gemini-3.8-flash-high --effort medium`
  fails: `invalid model selection ... conflicts with --effort=medium`
- `--model claude-sonnet-4-6 --effort low`
  fails: `--effort is not supported for model "claude-sonnet-4-6"`
- `--model gemini-3.1-pro-high --effort high` is accepted only because it
  agrees with the suffix, so it does nothing.

Rule: pass `--model`, never `--effort`.

## Useful agy flags (v1.2.7)

| Flag | Meaning |
|---|---|
| `-p "<prompt>"` | print mode: one prompt, then exit |
| `--model <id>` | model; includes the effort level |
| `--add-dir <path>` | give the worker a folder; repeatable; absolute path |
| `--output-format json` | one JSON result line with `status`, `response`, `usage`, `conversation_id` |
| `--json-schema <file or string>` | adds a parsed `structured_output` field |
| `--conversation <id>` / `-c` | resume a worker / the most recent one |
| `--print-timeout 300s` | hard limit; `0s` waits until the turn completes |
| `--dangerously-skip-permissions` | allow shell commands without prompting |
| `--mode plan` | planning mode; does **not** block file edits |
| `--sandbox` | terminal restrictions (not covered by this skill) |

Other subcommands: `agy models`, `agy agents`, `agy mcp`, `agy plugin`,
`agy changelog`, `agy update`.
