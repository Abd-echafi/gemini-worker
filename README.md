# gemini-worker

Claude plans and reviews. Gemini 3.8 Flash — through the Antigravity CLI — does
the typing. A shell script decides whether each attempt passed.

The expensive part of delegation is the reviewer reading everything. So the
worker returns a compressed report, the gate is deterministic, and the reviewer
reads one small file per iteration.

- Gemini reads the code. Claude reads ~300–800 tokens per review.
- `verify.sh` costs zero model tokens and runs after every iteration.
- The source tree is untouched until you merge.

Works with Claude Code (as a skill) or by hand from any terminal.

---

## Requirements

| Need | Why |
|---|---|
| **Antigravity CLI (`agy`)** | Runs Gemini. Install below, then `agy` once to authenticate with Google OAuth. |
| **A Gemini plan / API key** | The worker's token spend comes out of *your* Gemini subscription, not Claude's. |
| **Python 3.9+** | The harness is a single stdlib-only script. No pip packages. |
| **git** | Sandboxes are `git worktree`s. `rsync` is used only when the source is not a repo. |
| **bash** | Runs your `verify.sh`. |

Install the Antigravity CLI:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy --version          # tested against 1.4.12
```

Headless setup (CI, no browser): set `"modelProvider": "gemini"` in
`~/.gemini/antigravity-cli/settings.json` and export `GEMINI_API_KEY`.

## Install

```bash
git clone https://github.com/Abd-echafi/gemini-worker.git
cd gemini-worker
./install.sh
```

That symlinks `bin/agy-loop` into `~/.local/bin`, and creates
`~/.claude/skills/gemini-worker/` with `SKILL.md` symlinked from the checkout.
Re-run it after `git pull` — both entries point into the repo, so updates land
automatically. Existing files are only replaced with `--force`, and are backed
up first.

Manual install:

```bash
cp bin/agy-loop ~/.local/bin/agy-loop && chmod +x ~/.local/bin/agy-loop
cp -r skills/gemini-worker ~/.claude/skills/
```

## Quickstart

```bash
agy-loop new my-task --source ~/code/my-repo
$EDITOR ~/.agy-loop/tasks/my-task/brief.md
$EDITOR ~/.agy-loop/tasks/my-task/verify.sh     # optional but strongly preferred
agy-loop step my-task                            # -> review-01.md
agy-loop feedback my-task "the failing assertion is X"
agy-loop step my-task
agy-loop accept my-task -m "feat: thing"         # commits in the sandbox
git -C ~/code/my-repo merge agy/my-task          # only when you are happy
agy-loop clean my-task --force
```

## Commands

| Command | Purpose |
|---|---|
| `new <slug> --source DIR` | Task + isolated worktree on branch `agy/<slug>` |
| `step <slug>` | One Gemini iteration, writes `review-NN.md` |
| `run <slug...> [--jobs N]` | Step several independent tasks concurrently |
| `feedback <slug> "text"` | Queue a note for the next iteration |
| `show <slug> <path> [--diff]` | One file, capped, for targeted review |
| `accept <slug> -m msg` | Commit in the sandbox, print merge command |
| `clean <slug> --force` | Remove the sandbox |
| `status <slug>` / `list` | State and token spend |
| `recon <dir>` | Compact repo map, so Claude never reads the codebase |
| `config <slug> --max-iter N` | Raise the iteration cap |

Useful flags: `new --include-dirty` (copy uncommitted work), `new --force-copy`
(plain copy instead of a worktree), `step --no-sandbox` (allow network),
`step --model gemini-3.8-flash-medium` (cheaper on mechanical work),
`step --skip-verify`.

## How a step works

1. Build a prompt from `brief.md` + `rubric.md` + unconsumed feedback + the
   previous gate output.
2. Call `agy --print=… --output-format json --json-schema …` so Gemini must
   answer with a fixed object: `status`, `summary`, `files_changed`,
   `commands_run`, `self_check`, `questions`, `decisions`.
3. Run `verify.sh` inside the sandbox (deterministic, no model tokens).
4. Diff the sandbox and write `review-NN.md`: gate verdict, Gemini's report,
   verify tail, diff stat, diff capped at 300 lines, and token spend.
5. Append the run to `ledger.jsonl`.

Exit codes from `step`:

| Code | Meaning |
|---|---|
| `0` | Gemini reported done, gate passed |
| `2` | Gate failed |
| `3` | Gemini reported blocked/partial, or the iteration cap is hit |
| `4` | Harness or CLI error |

## Parallel workers

Several independent tasks can run at once:

```bash
agy-loop run auth-refactor add-tests docs-pass --jobs 3
```

Each task is a child process in its own sandbox, so state, locks and token
ledgers stay independent. The parent starts at most `--jobs` at a time and ends
with a summary:

```
task                         result      iter         tokens  packet
--------------------------------------------------------------------------------------------
auth-refactor                PASS        1/3          385,151  .../tasks/auth-refactor/review-01.md
add-tests                    PASS        2/3          120,004  .../tasks/add-tests/review-02.md
docs-pass                    FAIL        1/3           61,442  .../tasks/docs-pass/review-01.md

batch total: 566,597 Gemini tokens across 3 task(s)
```

`run` exits `0` only if every task passed, `1` if any failed, was blocked or was
not run, and `4` on a harness error.

Notes:

- **Independent work only.** Separate worktrees mean no on-disk contention, but
  two tasks editing the same files still have to be merged, and duplicate work
  is wasted tokens.
- **`--jobs` defaults to 3.** Every `agy` call costs ~10k tokens of fixed
  overhead before any real work, so an N-way fan-out multiplies that floor.
  Start at 2–3 and watch the ledger.
- **`--stop-on-fail`** stops starting new tasks after the first non-passing one;
  tasks already running still finish.
- **`step` holds an exclusive lock per task**, so a manual `agy-loop step`
  cannot collide with a batch run — it exits 4 instead of corrupting state.
- Flags (`--model`, `--skip-verify`, `--no-sandbox`, `--resume`, timeouts) are
  forwarded to every child. Full logs land in each task's `history/run-*.log`.

## Layout

```
~/.agy-loop/                      (override with AGY_LOOP_HOME)
  tasks/<slug>/
    brief.md          your spec
    rubric.md         optional judgment criteria (non-code work)
    verify.sh         deterministic gate, exit 0 = pass
    feedback.jsonl    reviewer notes, consumed per iteration
    ledger.jsonl      per-iteration token spend
    state.json        task state
    review-NN.md      the packet the reviewer reads
    history/          prompts, raw reports, diffs, verify logs
  sandboxes/<slug>/   isolated working copy
```

Environment overrides: `AGY_BIN`, `AGY_LOOP_HOME`, `AGY_LOOP_MODEL`.

## Using it from Claude Code

The skill at `skills/gemini-worker/SKILL.md` teaches Claude the loop: run
`recon`, write the brief and gate, then read **only** the review packet after
each `step`. Once installed, it triggers on "use gemini", "gemini worker",
"delegate this to gemini", or any large mechanical task.

The whole point is that Claude never reads the repo or the diff. If you find
yourself reading source mid-loop, the brief or the gate is too weak.

## Caveats

- **Sandbox blocks network.** `npm install`, `pip install` and API calls fail
  inside a step. Pre-install in the source (deps are symlinked) or pass
  `--no-sandbox`, and say that you did.
- **Worktrees start at HEAD.** Uncommitted edits are invisible to Gemini unless
  you pass `--include-dirty`. `new` warns with the number of skipped paths.
- **Gitignored files are absent.** `.env`, fixtures, generated assets. Copy what
  the task needs, or use `--force-copy`.
- **Gemini cannot ask questions in print mode.** The brief must be
  self-contained. Genuinely undecidable work comes back `blocked` with a
  question for the reviewer.
- **Never let the loop edit its own gate.** The prompt forbids touching
  `verify.sh`, `brief.md`, `rubric.md` or `.agy-loop`. If a packet shows the
  gate changed, discard that iteration.
- **Token spend is Gemini's internal tool turns.** 80k–250k per iteration is
  normal and comes out of the Gemini subscription.

## Troubleshooting

**`agy-loop: Antigravity CLI (agy) not found`** — install it (see Requirements),
or `export AGY_BIN=/path/to/agy`. The resolver checks `AGY_BIN`, then `PATH`,
then `~/.local/bin`, `~/.gemini/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.

**`agy failed (exit N)`** — usually auth. Run `agy` once interactively to sign
in, and check `agy --version` works from a fresh shell.

**Empty or missing review packet** — `brief.md` is still the template. Fill in
observable acceptance criteria and the out-of-scope section.

## License

MIT. See [LICENSE](LICENSE).
