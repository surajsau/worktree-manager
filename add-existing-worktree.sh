#!/usr/bin/env bash
#
# Add a git worktree for an EXISTING branch of abema-androidtv, plus the
# gitignored local files listed in copy-on-create.txt.
#
# Unlike create-worktree.sh (which makes a NEW branch off origin/main), this
# checks out a branch that already exists — either locally or on origin.
#
# Usage:  ./add-existing-worktree.sh <branch>
#   <branch> is the full existing branch name (e.g. suraj/foo or feature/bar).
#   Slashes become "+" in the folder name (suraj/foo -> suraj+foo).
#
# Exit 0 on success, non-zero on failure (with an error message on stderr).
# Safe to invoke from the web server, a Claude skill, or any shell.

set -euo pipefail

# --- Config -----------------------------------------------------------------
MAIN_REPO="/Users/s24270/Documents/Github/abema-androidtv"
WORKTREE_DIR="/Users/s24270/Documents/Github/worktrees"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPY_LIST_FILE="$SCRIPT_DIR/copy-on-create.txt"

die() { echo "error: $1" >&2; exit 1; }

# --- Validate branch --------------------------------------------------------
branch="${1:-}"
[[ -n "$branch" ]]                     || die "branch is required (usage: $0 <branch>)"
[[ "$branch" != *[[:space:]]* ]]       || die "branch cannot contain spaces"
[[ "$branch" != *[\~^:?*\[\]\\@]* ]]   || die "branch contains an invalid character"
[[ "$branch" != *..* ]]                || die "branch cannot contain '..'"
[[ "$branch" != /* ]]                  || die "branch cannot start with '/'"
[[ "$branch" != */ ]]                  || die "branch cannot end with '/'"
# strip an origin/ prefix if the user pasted a remote-tracking ref
branch="${branch#origin/}"

folder="${branch//\//+}"
dest="$WORKTREE_DIR/$folder"

[[ ! -e "$dest" ]] || die "a worktree folder already exists at $dest"

# --- Locate the branch ------------------------------------------------------
echo "Fetching origin…"
git -C "$MAIN_REPO" fetch origin

if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "Adding worktree for existing local branch ${branch}…"
  git -C "$MAIN_REPO" worktree add "$dest" "$branch"
elif git -C "$MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  echo "Adding worktree for origin/$branch (creating local tracking branch)…"
  git -C "$MAIN_REPO" worktree add -b "$branch" "$dest" "origin/$branch"
else
  die "branch '$branch' not found locally or on origin"
fi

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

echo "Added $branch"
echo "path: $dest"
