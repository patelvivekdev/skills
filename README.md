# Skills

Agent skills for Claude Code, Codex, Cursor and other agents that read
`SKILL.md` files.

## Install

```bash
npx skills add patelvivekdev/skills --skill create-worktree
```

Project installs go to `.agents/skills/` (Codex, Cursor) and `.claude/skills/`
(Claude Code). Commit them so everyone on the repository gets the same skill.
Add `-g` to install for every project on your machine.

## create-worktree

Creates Git worktrees under `<repo>/.worktrees/` for a new branch, an existing
branch or a GitHub pull request, and copies gitignored local files such as `.env`
into them.

```bash
worktree.sh init                       # ignore /.worktrees/, create .worktreeinclude
worktree.sh new feat/login             # branch from origin's default branch
worktree.sh new fix/typo --base head   # branch from the current HEAD
worktree.sh open feat/login            # existing local or remote branch
worktree.sh pr 123                     # pull request via gh pr checkout
worktree.sh sync-env feat-login        # copy local files again
worktree.sh remove feat-login --delete-branch
```

### Per-repository files

| File                 | Purpose                                                                                                                                                                       |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.worktreeinclude`   | Gitignored files to copy, in gitignore syntax. Replaces the default `.env`, `.env.*`, `*.env`, `.envrc` patterns. Claude Code and Conductor read the same file.               |
| `.worktree-setup.sh` | Optional. Runs from the main checkout inside each new worktree, with `WORKTREE_PRIMARY_ROOT` and `WORKTREE_PATH` set. Use it for installs, code generation or database setup. |
| `.gitignore`         | Must ignore `/.worktrees/`. `init` adds it.                                                                                                                                   |

Files are copied, not symlinked, so each worktree can change its own
configuration. Existing files are never overwritten unless `sync-env --force` is
used. Dependencies, virtual environments and worktree folders are never copied.

## Development

```bash
bash tests/create-worktree-smoke.sh
```

The smoke test builds throwaway repositories and runs every command. Scripts
must keep working with the Bash 3.2 that ships with macOS.
