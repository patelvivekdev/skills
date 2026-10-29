#!/usr/bin/env bash

set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/skills/create-worktree/scripts/worktree.sh"
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
failures=0

pass() {
  printf 'ok   %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

check_not() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

worktree() {
  bash "$script" "$@"
}

export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.com
export GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.com

cd "$workspace"
git init -q --bare -b main remote.git
git init -q -b main repo
cd repo
printf '.env\n.env.*\n!.env.example\n*.env\nnode_modules/\nlocal.mk\n.cache/\n' >.gitignore
echo 'EXAMPLE=1' >.env.example
mkdir -p app/web
printf '{"name":"web","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"web","version":"1.0.0"}}}' >app/web/package-lock.json
printf '{"name":"web","version":"1.0.0"}' >app/web/package.json
git add -A
git commit -qm init
git remote add origin ../remote.git
git push -q -u origin main
git remote set-head origin main

echo 'SECRET=1' >.env
chmod 600 .env
echo 'WEB=1' >app/web/.env.local
echo 'INFRA=1' >app/infra.env
mkdir -p node_modules/pkg && echo 'NO=1' >node_modules/pkg/.env
echo 'PORT=1' >local.mk
echo 'untracked' >notes.txt

# Advance the remote so the default base differs from local HEAD.
git clone -q ../remote.git "$workspace/other"
(cd "$workspace/other" && git commit -q --allow-empty -m remote-advance && git push -q origin main)
remote_tip=$(git -C "$workspace/other" rev-parse HEAD)

echo "--- new (default base, default patterns)"
worktree new feat/one
wt=.worktrees/feat-one
check "worktree created on branch" test "$(git -C $wt branch --show-current)" = feat/one
check "branched from fetched remote default" test "$(git -C $wt rev-parse HEAD)" = "$remote_tip"
check "new branch has no upstream" test -z "$(git -C $wt for-each-ref --format='%(upstream)' refs/heads/feat/one)"
check "root .env copied" test -f $wt/.env
check "nested .env.local copied" test -f $wt/app/web/.env.local
check "*.env copied" test -f $wt/app/infra.env
check ".env permissions kept" test "$(stat -f %Lp $wt/.env 2>/dev/null || stat -c %a $wt/.env)" = 600
check_not "node_modules env skipped" test -e $wt/node_modules/pkg/.env
check_not "non-env ignored file skipped" test -e $wt/local.mk
check_not "untracked file skipped" test -e $wt/notes.txt
check "main checkout stays clean of .worktrees" test -z "$(git status --porcelain -- .worktrees)"

echo "--- new --base head"
worktree new feat/two --base head --no-setup
check "head base used" test "$(git -C .worktrees/feat-two rev-parse HEAD)" = "$(git rev-parse HEAD)"

echo "--- init"
worktree init
check ".gitignore ignores /.worktrees/" grep -qx '/.worktrees/' .gitignore
check ".worktreeinclude created" test -f .worktreeinclude
echo 'local.mk' >>.worktreeinclude

echo "--- sync-env"
echo 'SECRET=2' >.env
worktree sync-env feat/one
check "include file adds local.mk" test -f $wt/local.mk
check "existing .env kept" grep -qx 'SECRET=1' $wt/.env
worktree sync-env feat-one --force
check "--force overwrites .env" grep -qx 'SECRET=2' $wt/.env

echo "--- include file replaces defaults"
printf 'local.mk\n' >.worktreeinclude
worktree new feat/three --base head
check "listed file copied" test -f .worktrees/feat-three/local.mk
check_not "defaults not applied" test -e .worktrees/feat-three/.env
rm .worktreeinclude

echo "--- setup hook and install"
printf 'mkdir -p .cache && echo "$WORKTREE_PRIMARY_ROOT" >.cache/setup-ran\n' >.worktree-setup.sh
worktree new feat/four --base head --install-dir app/web >"$workspace/install.log" 2>&1
check "setup hook ran in worktree" test -f .worktrees/feat-four/.cache/setup-ran
check "install ran" grep -q 'ok     app/web: npm ci' "$workspace/install.log"
printf 'exit 3\n' >.worktree-setup.sh
check_not "failing hook exits non-zero" worktree new feat/five --base head
check "worktree kept after hook failure" test -d .worktrees/feat-five
rm .worktree-setup.sh

echo "--- open"
(cd "$workspace/other" && git checkout -qb feature/remote && git commit -q --allow-empty -m r && git push -q origin feature/remote)
worktree open feature/remote
check "remote branch tracked" test "$(git -C .worktrees/feature-remote rev-parse --abbrev-ref '@{u}')" = origin/feature/remote
check_not "missing branch fails" worktree open does/not/exist

echo "--- guards"
check_not "existing branch rejected by new" worktree new feat/one
check_not "invalid branch rejected" worktree new 'bad..name'
check_not "--force rejected for new" worktree new feat/x --force
check_not "--base rejected for open" worktree open feat/one --base head

echo "--- remove"
echo dirty >>.worktrees/feat-two/.env.example
check_not "dirty worktree refused" worktree remove feat-two
git -C .worktrees/feat-three checkout -q --detach
git -C .worktrees/feat-three commit -q --allow-empty -m orphan
check_not "detached commits refused" worktree remove feat-three
(cd .worktrees/feature-remote && worktree remove feat-one --delete-branch)
check "removed from another worktree" test ! -e $wt
check_not "branch on remote default deleted" git show-ref --verify --quiet refs/heads/feat/one
git -C .worktrees/feat-four commit -q --allow-empty -m unmerged
worktree remove feat-four --delete-branch
check "unmerged branch kept" git show-ref --verify --quiet refs/heads/feat/four
worktree remove feat-two --force
check "--force removes dirty worktree" test ! -e .worktrees/feat-two
check "branch kept without --delete-branch" git show-ref --verify --quiet refs/heads/feat/two

echo ""
if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
