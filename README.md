# Antigravity Slavery

A Claude Code skill for driving the Antigravity CLI (`agy`) as a pool of
disposable subagent workers, so the orchestrator never loads the files they read.

```
SKILL.md                        the skill itself
scripts/agy-slave.sh            tier-name wrapper: fallback + status checking
references/models.md            live model list and the six tiers
references/troubleshooting.md   every failure mode observed, with the fix
```

## Use it right now, without installing

```bash
./scripts/agy-slave.sh supreme "Explain the retry logic in io/command_sender.py" /path/to/repo
```

Tiers: `supreme` `smart` `basic` `claudeman` `mini-claudeman` `dumbest`.

## Install so Claude Code picks it up

A skill is only discovered inside `~/.claude/skills/`. Copy it there:

```bash
cp -r "/c/Users/rdor/Desktop/Antigravity-Slavery" "/c/Users/rdor/.claude/skills/antigravity-slavery"
```

Then `/antigravity-slavery` becomes available, and Claude will reach for it on
its own whenever delegation to `agy` is the right move.

## The one thing to remember

`agy` ignores your shell's current directory — it runs in its own scratch dir.
Without `--add-dir <absolute Windows path>` a worker hunts the disk for the
files you named and can confidently analyse **a different repository**. The
wrapper script handles this for you.
