---
name: create-worktree
description: Create, refresh, and remove Git worktrees under the repository's .worktrees folder for a new branch, an existing branch, or a GitHub pull request, copying the main checkout's gitignored local files such as .env. Use when the user asks to work on, review, or test something in a separate worktree, to set a repository up for worktrees, or to refresh or clean one up.
---

# Create Worktree

Use the bundled script for every worktree operation so location, branch setup and
local files stay consistent. `<skill-dir>` below is the directory containing this
`SKILL.md`; run the script from inside the target repository.

## Commands

```bash
bash <skill-dir>/scripts/worktree.sh init
bash <skill-dir>/scripts/worktree.sh new <branch> [--base <ref>|head]
bash <skill-dir>/scripts/worktree.sh open <branch>
bash <skill-dir>/scripts/worktree.sh pr <number>
bash <skill-dir>/scripts/worktree.sh sync-env <name> [--force]
bash <skill-dir>/scripts/worktree.sh remove <name> [--delete-branch]
bash <skill-dir>/scripts/worktree.sh list
```

- `init` adds `/.worktrees/` to `.gitignore`, creates `.worktreeinclude` with
  the default patterns, and lists which files will be copied plus other
  gitignored paths worth considering. Run it once per repository; the user
  reviews and commits both files.
- `new` fetches and branches from the remote's default branch (usually
  `origin/main`). `--base head` uses the current `HEAD`; `--base <ref>` any ref.
  The new branch does not track its base.
- `open` uses a local branch, or fetches and tracks `<remote>/<branch>`.
- `pr` uses `gh pr checkout` so the branch can be pushed; if that branch is
  checked out elsewhere, or `gh` is missing, the worktree is detached.
- `<name>` is the folder under `.worktrees`: the branch with `/` replaced by
  `-`, or `pr-<number>`.

Run the script with `--help` for every option.

## Local files

New worktrees receive **copies** of the main checkout's files that are
gitignored and match `.worktreeinclude` (gitignore syntax). Without that file
the defaults are `.env`, `.env.*`, `*.env` and `.envrc`. A `.worktreeinclude`
replaces the defaults, matching Claude Code and Conductor, which read the same
file. `node_modules`, `.venv`, `.terraform` and worktree folders are never
copied.

Existing files are never overwritten. Run `sync-env <name>` after the main
checkout's files change; add `--force` only when the user agrees to replace that
worktree's edits.

## Setup

After copying, the script runs `.worktree-setup.sh` **from the main checkout**
inside the new worktree, with `WORKTREE_PRIMARY_ROOT` and `WORKTREE_PATH` set.
Use it for installs, code generation or local database setup. `--no-setup`
skips it.

`--install` (or `--install-dir <path>`, repeatable) installs dependencies for
tracked lockfiles: pnpm, npm, yarn, uv and poetry. Install only when the user
wants to run or test code; installing a pull request runs its install scripts.

## Workflow

1. Confirm the command and its argument (branch, base, PR number).
2. Run the script. Never display or inspect copied file contents.
3. Treat a non-zero exit, including a failed setup hook or install, as a real
   failure and report it.
4. Report the path, branch, commit, local files, setup and install results.
5. Use the printed path as the working directory and read that worktree's
   `AGENTS.md` or `CLAUDE.md` before editing.

## Cautions

- Worktrees share Docker services, databases and default ports with the main
  checkout. Don't run two dev servers on the same ports; migrations apply to the
  shared database.
- `remove` refuses a worktree with uncommitted changes or detached commits.
  Never pass `--force` without the user's approval. Branches are kept unless
  `--delete-branch` is given, and only merged branches are deleted.
