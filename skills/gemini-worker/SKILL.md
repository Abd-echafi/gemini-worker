---
name: gemini-worker
description: Offload implementation work to Gemini 3.8 Flash through the Antigravity CLI while Claude plans and reviews each iteration. Use whenever the user says "use gemini", "let gemini do it", "delegate this to gemini", "gemini worker", "dual agent", "save claude tokens", "have gemini build X", or asks for a worker/reviewer loop. Also use for any large, mechanical, or long-running task where Claude should conserve tokens.
---

# Gemini worker loop

Claude plans and reviews. Gemini does the typing. Verification runs as a shell
script, so most of the work never costs Claude tokens.

## When this is worth it

Use it when the task is **bigger than a couple of edits**: a feature, a refactor
across files, a migration, a test suite, a document drafted from a long brief.
You would otherwise read a lot of code and write a lot of code.

Skip it for small things. A one-file fix, a config tweak, a question, a short
explanation: doing it yourself is cheaper than writing a brief, and the harness
adds a minute of latency per iteration.

## The economics you are protecting

- Claude reading the code = expensive. Gemini reading the code = cheap.
- So: **never read the repo yourself.** Run `agy-loop recon` once and read its
  ~20-line output instead.
- After each iteration, read exactly one file: the review packet. It is roughly
  300-800 tokens. Do not open the diff, do not open the source, unless the
  packet makes a specific doubt worth one targeted `agy-loop show`.
- Verification is a shell script. It costs zero Claude tokens. Put every
  mechanical criterion in it instead of checking it yourself.
- Parallel tasks multiply Gemini's fixed per-call overhead, not your review
  cost. Review stays one packet per task; spend does not stay flat.

## Protocol

### 0. Recon (only if you do not already know the repo)

```bash
agy-loop recon /path/to/repo
```

Returns stack, layout, entrypoints, a working test command, and risky areas.
Read that instead of the codebase. Budget is capped at ~20 files.

### 1. Create the task

```bash
agy-loop new <slug> --source /path/to/repo --max-iter 6
```

This creates an isolated sandbox (a git worktree on branch `agy/<slug>`, or a
copy with its own git history if the source is not a repo) plus a task folder at
`~/.agy-loop/tasks/<slug>/`. Your source working tree is never touched.

Dependencies (`node_modules`, `.venv`) are symlinked from the source so builds
work without a reinstall.

### 2. Write the brief. This is your only real token spend

Edit `~/.agy-loop/tasks/<slug>/brief.md` with the Write tool. Requirements:

- **Goal** in observable terms: what is true when this is done.
- **Acceptance criteria** as a checklist, each line checkable by a stranger.
  "Looks clean" is not a criterion. "`pnpm test` exits 0" is.
- **Constraints**: language, conventions, files not to touch.
- **Out of scope**: name the things Gemini should not wander into. This is the
  single biggest lever on iteration count.

Do not paste large source files into the brief. Gemini has the repo; it will read
what it needs. A brief that describes intent beats a brief that transcribes code.

### 3. Write the gate (optional but strongly preferred)

`~/.agy-loop/tasks/<slug>/verify.sh`, exit 0 = pass. It runs in the sandbox after
every iteration, with no Claude involvement.

```bash
#!/usr/bin/env bash
set -uo pipefail
npm test --silent        # or: pnpm typecheck && pnpm test
```

For tasks with no deterministic check (writing, design, research), skip it and
put the judgment in `rubric.md` instead. The loop then relies on your review.

### 4. Loop

```bash
agy-loop step <slug>            # one iteration, writes review-01.md, exits 0/2/3
```

Then read `~/.agy-loop/tasks/<slug>/review-NN.md`, and only this file. It gives
you the gate result, Gemini's summary and self-check, the diff stat, and a diff
capped at 300 lines.

Decide:

| Packet says | Do |
|---|---|
| Gate PASS, report coherent | Accept, or send one tightening note and let it polish |
| Gate FAIL | Read only the failing part; send precise feedback |
| Report contradicts the diff | `agy-loop show <slug> <path> --diff` on that one file |
| Blocked / genuinely ambiguous | Answer the question yourself, then `feedback` and `step` |

Send feedback and iterate:

```bash
agy-loop feedback <slug> "add(a,b) still returns a-b when b is negative; the gate output shows the failing assertion."
agy-loop step <slug>
```

Keep feedback to the concrete defect and the evidence. Vague feedback ("make it
better") costs a whole iteration and usually makes it worse.

Stop when the gate passes and the diff matches the intent, or when the iteration
cap is hit. Never let it run past `--max-iter` silently: if you raise the cap,
say why.

### Review modes

- **review-each (default):** read `review-NN.md` after every step. Use it when the
  gate is weak, the task is ambiguous, or the user asked to see each round.
- **gate-only:** when the user says "gate only", "don't review each round", or
  "loop until it passes", drive `agy-loop step` on its exit code without reading
  packets, then read only the final one. Cheapest on Claude tokens. Stop early if
  exit 3 (blocked) appears twice, or if a gate failure repeats with an unchanged
  diff across two rounds.

### Parallel tasks

When the work splits into **independent** units, create one task per unit and
step them together instead of looping one at a time:

```bash
agy-loop run slug-a slug-b slug-c --jobs 3
```

Each task runs as its own process in its own sandbox, so state and token
ledgers stay independent. The parent prints one line per completion, then a
summary of result, spend and packet path. Read each `review-NN.md` after — the
same ~300-800 token budget per task.

Only parallelize work that does not touch the same files. Separate worktrees
prevent on-disk races, not merge conflicts or duplicated effort. Each concurrent
call carries ~10k Gemini tokens of fixed overhead, so `--jobs 2` or `3` is
usually the sweet spot. `--stop-on-fail` stops starting new tasks after the
first non-passing one.

### Fan-out: one feature, several workers

When one brief splits into independent parts, do not write N briefs by hand.
Let Gemini propose the split, then **review the split itself** — it is the plan,
and a bad one costs more than it saves.

```bash
agy-loop split <parent> --parts 3    # writes split.json and prints it
agy-loop fan <parent> --dry-run      # children + generated briefs, no spend
agy-loop fan <parent> --jobs 3       # build every part at once
```

Read `split.json` before `fan`:

- files must be disjoint across parts. `split` hard-errors on an exact overlap,
  and a part list that shares one file is a rewrite, not a review note;
- parts must build and test without each other. If two depend on each other,
  merge them into one part in `split.json`;
- never let parts share a router, schema, barrel export or lockfile. Those merge
  badly and the integration step swallows the task.

Each child gets a generated `verify.sh`: its own commands plus a scope guard that
fails if it touched a file outside its list. Send the packet back through
`feedback` like any other task.

Then accept what passed, and integrate:

```bash
agy-loop accept <parent>-<part> -m "..."
agy-loop merge <parent>              # merges children, defers conflicts
agy-loop step <parent>-integrate
```

`merge` merges clean children mechanically and aborts any conflicting one,
naming it in the integration brief. Gemini resolves those, then the union gate
(every part's checks plus `integration_gate`, and no leftover conflict markers)
must pass. Judge the integration packet, not the child diffs again.

### 5. Accept

```bash
agy-loop accept <slug> -m "feat: what it does"
```

Commits inside the sandbox and prints the merge command for your source repo.
Nothing reaches the user's branch until they run it.

Clean up when done:

```bash
agy-loop clean <slug> --force
```

## Model choice

```bash
agy-loop step <slug> --model gemini-3.8-flash-high     # default: implementation
agy-loop step <slug> --model gemini-3.8-flash-medium   # mechanical edits, renames
agy-loop step <slug> --model gemini-3.8-flash-low      # tiny checks, one-liners
```

Start at `high` for anything with ambiguity. Drop to `medium` only for
mechanical work where the brief is unambiguous. Escalate rather than repeat a
failed `low`.

`--resume` continues Gemini's previous conversation. It costs more per turn and
is only useful for a multi-step task where it needs to remember what it already
tried. Default to fresh turns.

## Caveats to state out loud

- **Sandbox blocks network.** If the task needs `npm install`, `pip install`, or
  an API call, either pre-install in the source (deps are symlinked) or rerun
  with `agy-loop step <slug> --no-sandbox` and say that you did.
- **Worktrees start at HEAD.** If the source tree is dirty, uncommitted edits are
  invisible to Gemini unless you pass `--include-dirty` to `new`. Always check the
  warning it prints and mention it to the user if paths were skipped.
- **Gitignored files are absent.** `.env`, fixtures, uploads, generated assets.
  Copy what the task needs into the sandbox, or use `--force-copy` on `new`
  (copies the whole working tree, excludes deps, and returns a patch on `accept`
  instead of a branch).
- **Gemini cannot ask questions in print mode.** The brief must be self-contained.
  Anything genuinely undecidable comes back as `blocked` with a question, and you
  answer it.
- **Never let the loop edit its own gate.** The prompt forbids touching
  `verify.sh`, `brief.md`, or `.agy-loop`. If a packet shows the gate changed,
  discard that iteration.
- **Token spend is Gemini's internal tool turns.** 80k-250k per iteration is
  normal and comes out of the Gemini subscription, not the Claude one. Report the
  number from the packet rather than re-deriving it.

## Reporting back to the user

After `accept`, tell them: what changed, which gate proved it, Gemini tokens
spent, and the merge command. If something is still unproven, say which specific
thing and why, rather than calling it done.
