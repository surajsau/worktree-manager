#!/usr/bin/env bash
#
# Create a git worktree: a fresh branch off the latest trunk (or a given base
# branch), plus the gitignored local files listed in copy-on-create.txt.
#
# Usage:  ./create-worktree.sh <name> [base]
#   <name> is the part after the configured branch prefix. It may contain
#   slashes, which become "+" in the folder name (foo/bar -> foo+bar).
#   [base] is the ref to branch off; defaults to origin/<main branch>.
#   `git fetch` runs only when the base is a remote ref (origin/...).
#
# The repository, worktree folder, branch prefix and main branch come from
# config.sh — see the comment at the top of it.
#
# Exit 0 on success, non-zero on failure (with an error message on stderr).
# Safe to invoke from the app, a Claude skill, or any shell.

set -euo pipefail

# --- Config -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
require_repo
COPY_LIST_FILE="$SCRIPT_DIR/copy-on-create.txt"

die() { echo "error: $1" >&2; exit 1; }

# --- Validate name ----------------------------------------------------------
name="${1:-}"
[[ -n "$name" ]]                    || die "name is required (usage: $0 <name>)"
[[ "$name" != *[[:space:]]* ]]      || die "name cannot contain spaces"
[[ "$name" != *[\~^:?*\[\]\\@]* ]]  || die "name contains an invalid character"
[[ "$name" != *..* ]]              || die "name cannot contain '..'"
# slashes are allowed mid-name (they become '+'), just not at the ends
[[ "$name" != /* ]]                || die "name cannot start with '/'"
[[ "$name" != */ ]]                || die "name cannot end with '/'"
[[ "$name" != .* && "$name" != *. ]] || die "name cannot start or end with '.'"

# --- Validate base ------------------------------------------------------------
base="${2:-origin/$MAIN_BRANCH}"
[[ "$base" != -* ]]                 || die "base cannot start with '-'"
[[ "$base" != *[[:space:]]* ]]      || die "base cannot contain spaces"
[[ "$base" != *[\~^:?*\[\]\\@]* ]]  || die "base contains an invalid character"
git -C "$MAIN_REPO" rev-parse --verify --quiet "refs/heads/$base" >/dev/null \
  || git -C "$MAIN_REPO" rev-parse --verify --quiet "refs/remotes/$base" >/dev/null \
  || [[ "$base" == origin/* ]] \
  || die "base branch not found: $base"

branch="${BRANCH_PREFIX}${name}"
folder="${branch//\//+}"
dest="$WORKTREE_DIR/$folder"

# --- Create -----------------------------------------------------------------
if [[ "$base" == origin/* ]]; then
  echo "Fetching origin…"
  git -C "$MAIN_REPO" fetch origin
fi

echo "Creating worktree $branch off ${base}…"
git -C "$MAIN_REPO" worktree add -b "$branch" "$dest" "$base"

# --- Copy gitignored local files --------------------------------------------
if [[ -f "$COPY_LIST_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    src="$MAIN_REPO/$line"
    dst="$dest/$line"
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      echo "copied $line"
    else
      echo "skipped $line (not in main repo)"
    fi
  done < "$COPY_LIST_FILE"
fi

echo "Created $branch"
echo "path: $dest"
"$SCRIPT_DIR/agent-artifacts.sh" "$branch"
