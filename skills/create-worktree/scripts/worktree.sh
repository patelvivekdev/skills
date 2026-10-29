#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' \
    "Usage: worktree.sh <command> [argument] [options]" \
    "" \
    "Create and manage Git worktrees under <repo>/.worktrees. New worktrees receive" \
    "copies of the main checkout's gitignored local files selected by .worktreeinclude" \
    "(gitignore syntax), or by the default .env patterns when that file is absent." \
    "" \
    "Commands:" \
    "  init                              Ignore /.worktrees/ and create .worktreeinclude" \
    "  new <branch> [--base <ref>|head]  Create a branch in a new worktree (base: remote default branch)" \
    "  open <branch>                     Check out an existing local or remote branch" \
    "  pr <number>                       Check out a GitHub pull request" \
    "  sync-env <name> [--force]         Copy local files again (--force overwrites)" \
    "  remove <name> [--delete-branch]   Remove a worktree and optionally its merged branch" \
    "  list                              List worktrees" \
    "" \
    "<name> is the folder under .worktrees: the branch with '/' replaced by '-', or pr-<number>." \
    "" \
    "Options:" \
    "  --install                         new/open/pr: install dependencies for every tracked lockfile" \
    "  --install-dir <path>              new/open/pr: install only in this directory (repeatable)" \
    "  --no-setup                        new/open/pr: skip the main checkout's .worktree-setup.sh" \
    "  --remote <name>                   Remote for base, branches and PRs (default: origin)" \
    "  --force                           sync-env: overwrite files; remove: discard local changes" \
    "  -h, --help                        Show this help"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

command_name=${1:-}
[[ -n "$command_name" ]] || {
  usage >&2
  exit 1
}
shift
case "$command_name" in
  -h|--help)
    usage
    exit 0
    ;;
  init|new|open|pr|sync-env|remove|list) ;;
  *) die "unknown command: $command_name (see --help)" ;;
esac

target=""
base=""
remote="origin"
install_dependencies=false
install_dirs=""
run_setup=true
force=false
delete_branch=false

while (($# > 0)); do
  case "$1" in
    --base)
      (($# >= 2)) || die "--base requires a ref"
      base=$2
      shift 2
      ;;
    --remote)
      (($# >= 2)) || die "--remote requires a name"
      remote=$2
      shift 2
      ;;
    --install)
      install_dependencies=true
      shift
      ;;
    --install-dir)
      (($# >= 2)) || die "--install-dir requires a path"
      install_dir=${2#./}
      install_dir=${install_dir%/}
      install_dirs+="${install_dir:-.}"$'\n'
      install_dependencies=true
      shift 2
      ;;
    --no-setup)
      run_setup=false
      shift
      ;;
    --force)
      force=true
      shift
      ;;
    --delete-branch)
      delete_branch=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$target" ]] || die "only one argument is accepted"
      target=$1
      shift
      ;;
  esac
done

case "$command_name" in
  init|list) [[ -z "$target" ]] || die "$command_name takes no argument" ;;
  *) [[ -n "$target" ]] || die "$command_name requires an argument (see --help)" ;;
esac
[[ -z "$base" || "$command_name" == new ]] || die "--base applies only to new"
[[ "$force" == false || "$command_name" == sync-env || "$command_name" == remove ]] ||
  die "--force applies only to sync-env and remove"
[[ "$delete_branch" == false || "$command_name" == remove ]] ||
  die "--delete-branch applies only to remove"
case "$command_name" in
  new|open|pr) ;;
  *)
    [[ "$install_dependencies" == false && "$run_setup" == true ]] ||
      die "--install, --install-dir and --no-setup apply only to new, open and pr"
    ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"
current_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "run this command inside a Git checkout"
common_git_dir=$(git -C "$current_root" rev-parse --path-format=absolute --git-common-dir)
[[ "$(basename "$common_git_dir")" == ".git" ]] ||
  die "expected a non-bare repository with a .git common directory"

primary_root=$(dirname "$common_git_dir")
worktrees_root="$primary_root/.worktrees"
include_file="$primary_root/.worktreeinclude"
setup_hook="$primary_root/.worktree-setup.sh"
script_path=$0
destination=""
local_files_summary=""
setup_summary=""
install_summary=""
step_failures=0

default_include_patterns() {
  printf '%s\n' '.env' '.env.*' '*.env' '.envrc'
}

destination_for() {
  printf '%s/%s' "$worktrees_root" "${1//\//-}"
}

require_new_destination() {
  [[ ! -e "$destination" ]] || die "destination already exists: $destination"
}

require_existing_worktree() {
  [[ -e "$destination/.git" ]] || die "no worktree at $destination"
}

append_line() {
  local file=$1
  local line=$2

  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$line" >>"$file"
}

ensure_worktrees_ignored() {
  if git -C "$primary_root" check-ignore -q ".worktrees/probe"; then
    return
  fi

  mkdir -p "$common_git_dir/info"
  append_line "$common_git_dir/info/exclude" '/.worktrees/'
  note "Ignored /.worktrees/ in .git/info/exclude (run init to add it to .gitignore)"
}

# Prints, NUL-separated, the gitignored files of the main checkout that the
# include patterns select. Tracked and merely untracked files never qualify.
list_local_files() {
  local patterns_file

  patterns_file=$(mktemp)
  if [[ -f "$include_file" ]]; then
    cat "$include_file" >"$patterns_file"
  else
    default_include_patterns >"$patterns_file"
  fi

  git -C "$primary_root" ls-files -z --others --ignored --exclude-from="$patterns_file" -- . \
    ':(exclude).worktrees' \
    ':(exclude).claude/worktrees' \
    ':(exclude,glob)**/node_modules/**' \
    ':(exclude,glob)**/.venv/**' \
    ':(exclude,glob)**/.terraform/**' |
    git -C "$primary_root" check-ignore -z --stdin || true

  rm -f "$patterns_file"
}

# Uses copy-on-write clones where the filesystem supports them.
copy_file() {
  cp -pc "$1" "$2" 2>/dev/null ||
    cp -p --reflink=auto "$1" "$2" 2>/dev/null ||
    cp -p "$1" "$2"
}

# Copies selected local files without overwriting unless asked. Contents are never printed.
copy_local_files() {
  local destination_root=$1
  local overwrite=$2
  local relative_path target_path
  local copied=0
  local kept=0

  while IFS= read -r -d '' relative_path; do
    target_path="$destination_root/$relative_path"

    if [[ -e "$target_path" && "$overwrite" != true ]]; then
      note "Kept existing ${relative_path}"
      kept=$((kept + 1))
      continue
    fi

    mkdir -p "$(dirname "$target_path")"
    copy_file "$primary_root/$relative_path" "$target_path"
    note "Copied ${relative_path}"
    copied=$((copied + 1))
  done < <(list_local_files)

  local_files_summary="${copied} copied, ${kept} kept"
  if [[ -f "$include_file" ]]; then
    local_files_summary+=" (from .worktreeinclude)"
  else
    local_files_summary+=" (default .env patterns)"
  fi
}

# The hook always comes from the main checkout, so a branch or pull request
# cannot change the code that runs during setup.
run_setup_hook() {
  local destination_root=$1

  if [[ "$run_setup" == false ]]; then
    setup_summary="skipped (--no-setup)"
    return
  fi
  if [[ ! -f "$setup_hook" ]]; then
    setup_summary="none (.worktree-setup.sh not found)"
    return
  fi

  note "Running .worktree-setup.sh from the main checkout..."
  if (
    cd "$destination_root" &&
      WORKTREE_PRIMARY_ROOT="$primary_root" \
        WORKTREE_PATH="$destination_root" \
        bash "$setup_hook"
  ); then
    setup_summary="ok"
  else
    setup_summary="FAILED"
    step_failures=$((step_failures + 1))
  fi
}

record_install() {
  install_summary+="  $1"$'\n'
}

install_in() {
  local destination_root=$1
  local directory=$2
  local lockfile=$3
  local -a install_command

  case "$lockfile" in
    pnpm-lock.yaml) install_command=(pnpm install --frozen-lockfile) ;;
    package-lock.json) install_command=(npm ci) ;;
    yarn.lock) install_command=(yarn install --frozen-lockfile) ;;
    uv.lock) install_command=(uv sync --frozen) ;;
    poetry.lock) install_command=(poetry install) ;;
  esac

  if ! command -v "${install_command[0]}" >/dev/null 2>&1; then
    record_install "FAILED ${directory}: ${install_command[0]} is not installed"
    step_failures=$((step_failures + 1))
    return
  fi

  note "Installing ${directory} with ${install_command[*]}..."
  if (cd "$destination_root/$directory" && "${install_command[@]}"); then
    record_install "ok     ${directory}: ${install_command[*]}"
  else
    record_install "FAILED ${directory}: ${install_command[*]}"
    step_failures=$((step_failures + 1))
  fi
}

install_dependencies_in() {
  local destination_root=$1
  local lockfile_path directory

  while IFS= read -r -d '' lockfile_path; do
    directory=$(dirname "$lockfile_path")
    if [[ -n "$install_dirs" ]] && ! printf '%s' "$install_dirs" | grep -Fxq -- "$directory"; then
      continue
    fi
    install_in "$destination_root" "$directory" "$(basename "$lockfile_path")"
  done < <(
    git -C "$destination_root" ls-files -z -- \
      ':(glob)**/pnpm-lock.yaml' \
      ':(glob)**/package-lock.json' \
      ':(glob)**/yarn.lock' \
      ':(glob)**/uv.lock' \
      ':(glob)**/poetry.lock'
  )

  [[ -n "$install_summary" ]] || record_install "no matching lockfiles found"
}

finish_creation() {
  local branch commit

  copy_local_files "$destination" false
  run_setup_hook "$destination"
  if [[ "$install_dependencies" == true ]]; then
    install_dependencies_in "$destination"
  fi

  branch=$(git -C "$destination" symbolic-ref --quiet --short HEAD || printf '(detached)')
  commit=$(git -C "$destination" log -1 --format='%h %s')

  note ""
  note "Worktree ready."
  note "Path: ${destination}"
  note "Branch: ${branch}"
  note "Commit: ${commit}"
  note "Local files: ${local_files_summary}"
  note "Setup hook: ${setup_summary}"
  if [[ "$install_dependencies" == true ]]; then
    note "Dependencies:"
    printf '%s' "$install_summary"
  else
    note "Dependencies: not installed (use --install, or install inside the worktree)"
  fi
  note ""
  note "Remove when finished:"
  note "  bash $(printf '%q' "$script_path") remove $(printf '%q' "$(basename "$destination")")"

  ((step_failures == 0)) || exit 1
}

# Resolves the remote's default branch after a best-effort fetch, falling back
# to the cached ref, then to HEAD when the repository has no usable remote.
resolve_default_base() {
  local default_ref

  if ! git -C "$primary_root" remote get-url "$remote" >/dev/null 2>&1; then
    note "No remote ${remote}; branching from current HEAD" >&2
    printf 'HEAD'
    return
  fi

  default_ref=$(git -C "$primary_root" symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" || true)
  if [[ -z "$default_ref" ]]; then
    git -C "$primary_root" remote set-head "$remote" --auto >/dev/null 2>&1 || true
    default_ref=$(git -C "$primary_root" symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" || true)
  fi
  if [[ -z "$default_ref" ]]; then
    note "Could not determine ${remote}'s default branch; branching from current HEAD" >&2
    printf 'HEAD'
    return
  fi

  if ! git -C "$primary_root" fetch --quiet "$remote" \
    "refs/heads/${default_ref#"${remote}"/}:refs/remotes/${default_ref}" >&2; then
    note "Fetch failed; using the cached ${default_ref}" >&2
  fi
  printf '%s' "$default_ref"
}

create_new_branch() {
  local branch=$1
  local base_ref base_commit

  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch name: $branch"
  if git -C "$primary_root" show-ref --verify --quiet "refs/heads/$branch"; then
    die "branch already exists: $branch (use: open $branch)"
  fi
  destination=$(destination_for "$branch")
  require_new_destination

  case "$base" in
    "") base_ref=$(resolve_default_base) ;;
    head) base_ref=HEAD ;;
    *) base_ref=$base ;;
  esac
  base_commit=$(git -C "$current_root" rev-parse --verify --quiet "${base_ref}^{commit}") ||
    die "unknown base ref: $base_ref"

  ensure_worktrees_ignored
  note "Creating ${branch} from ${base_ref}..."
  # Starting from a commit, not a remote branch, keeps the new branch from tracking it.
  git -C "$primary_root" worktree add -b "$branch" "$destination" "$base_commit"
  finish_creation
}

open_existing_branch() {
  local branch=$1

  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch name: $branch"
  destination=$(destination_for "$branch")
  require_new_destination
  ensure_worktrees_ignored

  if git -C "$primary_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$primary_root" worktree add "$destination" "$branch"
  else
    git -C "$primary_root" remote get-url "$remote" >/dev/null 2>&1 ||
      die "branch is not local and git remote does not exist: $remote"
    note "Fetching ${branch} from ${remote}..."
    git -C "$primary_root" fetch "$remote" "refs/heads/${branch}:refs/remotes/${remote}/${branch}" ||
      die "branch not found locally or on ${remote}: $branch"
    git -C "$primary_root" worktree add --track -b "$branch" "$destination" "${remote}/${branch}"
  fi
  finish_creation
}

open_pull_request() {
  local number=$1

  [[ "$number" =~ ^[1-9][0-9]*$ ]] || die "provide a positive pull request number"
  destination="$worktrees_root/pr-${number}"
  require_new_destination
  ensure_worktrees_ignored

  if ! command -v gh >/dev/null 2>&1; then
    note "gh not found; checking out pull/${number}/head detached (pushing needs gh)..."
    git -C "$primary_root" fetch "$remote" "pull/${number}/head" ||
      die "could not fetch pull/${number}/head from ${remote}"
    git -C "$primary_root" worktree add --detach "$destination" FETCH_HEAD
    finish_creation
    return
  fi

  git -C "$primary_root" worktree add --detach "$destination" HEAD
  if ! (cd "$destination" && gh pr checkout "$number"); then
    note "Branch checkout failed; retrying detached (the PR branch may be checked out elsewhere)..."
    if ! (cd "$destination" && gh pr checkout "$number" --detach); then
      git -C "$primary_root" worktree remove --force "$destination"
      die "gh pr checkout ${number} failed; removed ${destination}"
    fi
  fi
  finish_creation
}

initialize_repository() {
  local ignore_source relative_path

  ignore_source=$(git -C "$primary_root" check-ignore -v ".worktrees/probe" 2>/dev/null | cut -f1 || true)
  if [[ -z "$ignore_source" || "$ignore_source" == .git/info/exclude:* ]]; then
    append_line "$primary_root/.gitignore" '/.worktrees/'
    note "Added /.worktrees/ to .gitignore"
  else
    note ".worktrees/ is already ignored (${ignore_source%%:*})"
  fi

  if [[ -f "$include_file" ]]; then
    note ".worktreeinclude already exists; left unchanged"
  else
    {
      printf '%s\n' \
        '# Gitignored local files copied into new worktrees (gitignore syntax).' \
        '# Read by the create-worktree skill, Claude Code, Conductor and Worktrunk.' \
        '# List patterns only, never secret values. Install dependencies in a setup' \
        '# script instead of copying node_modules or virtual environments.'
      default_include_patterns
    } >"$include_file"
    note "Created .worktreeinclude with the default .env patterns"
  fi

  note ""
  note "New worktrees will copy:"
  while IFS= read -r -d '' relative_path; do
    note "  ${relative_path}"
  done < <(list_local_files)

  note ""
  note "Other gitignored paths (not copied; add any you need to .worktreeinclude):"
  git -C "$primary_root" ls-files --others --ignored --exclude-standard --directory -- . \
    ':(exclude).worktrees' ':(exclude).claude/worktrees' |
    grep -v -E '^\.worktrees/|(^|/)(node_modules|\.venv|venv|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.next|dist|build|\.turbo|\.terraform|coverage)/' |
    grep -v -E '(^|/)(\.env[^/]*|[^/]*\.env|\.envrc|\.DS_Store|[^/]*\.pyc|[^/]*\.log|[^/]*\.tsbuildinfo)$' |
    sed 's/^/  /' | head -n 30 || true
  note ""
  note "Review both files, then commit .gitignore and .worktreeinclude."
}

sync_local_files() {
  destination=$(destination_for "$target")
  require_existing_worktree
  copy_local_files "$destination" "$force"
  note "Local files: ${local_files_summary}"
}

remove_worktree() {
  local branch orphan_commits

  destination=$(destination_for "$target")
  require_existing_worktree
  branch=$(git -C "$destination" symbolic-ref --quiet --short HEAD || true)

  if [[ -z "$branch" && "$force" == false ]]; then
    orphan_commits=$(git -C "$destination" rev-list --count HEAD --not --branches --tags --remotes)
    ((orphan_commits == 0)) ||
      die "detached HEAD has ${orphan_commits} commit(s) on no branch; create a branch or pass --force"
  fi

  if [[ "$force" == true ]]; then
    git -C "$primary_root" worktree remove --force "$destination"
  else
    git -C "$primary_root" worktree remove "$destination"
  fi
  note "Removed ${destination}"

  if [[ "$delete_branch" == true && -n "$branch" ]]; then
    # A local default branch that lags the remote should not block deleting a
    # branch whose commits are all on the remote's default branch.
    if git -C "$primary_root" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/${remote}/HEAD" 2>/dev/null; then
      git -C "$primary_root" branch -D "$branch"
    else
      git -C "$primary_root" branch -d "$branch" ||
        note "Kept branch ${branch}: it is not fully merged"
    fi
  elif [[ -n "$branch" ]]; then
    note "Kept branch ${branch}"
  fi
}

case "$command_name" in
  init) initialize_repository ;;
  new) create_new_branch "$target" ;;
  open) open_existing_branch "$target" ;;
  pr) open_pull_request "$target" ;;
  sync-env) sync_local_files ;;
  remove) remove_worktree ;;
  list) git -C "$primary_root" worktree list ;;
esac
