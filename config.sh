#!/usr/bin/env bash
#
# Shared configuration for the worktree scripts. Sourced, never run.
#
# The menu bar app's Settings window is the source of truth; it exports these
# when it invokes a script, and mirrors them into a config file for the times
# you run one from a terminal instead:
#
#   WORKTREE_MANAGER_REPO           the git checkout worktrees are made from
#   WORKTREE_MANAGER_WORKTREE_DIR   folder the worktrees are created in
#                                   (default: a "worktrees" sibling of the repo)
#   WORKTREE_MANAGER_BRANCH_PREFIX  put in front of every created branch name
#   WORKTREE_MANAGER_MAIN_BRANCH    the repo's trunk (default: main)
#
# An exported variable always wins over the file, so a running app's settings
# beat a stale config.

# Environment first, so sourcing the file below can't clobber it.
_env_repo="${WORKTREE_MANAGER_REPO:-}"
_env_worktree_dir="${WORKTREE_MANAGER_WORKTREE_DIR:-}"
_env_main_branch="${WORKTREE_MANAGER_MAIN_BRANCH:-}"
# "No prefix" is a real setting, so this one is tracked by whether it was
# exported at all rather than by whether it is empty.
_env_branch_prefix="${WORKTREE_MANAGER_BRANCH_PREFIX-}"
_env_branch_prefix_set="${WORKTREE_MANAGER_BRANCH_PREFIX+yes}"

CONFIG_FILE="${WORKTREE_MANAGER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/worktree-manager/config}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

MAIN_REPO="${_env_repo:-${WORKTREE_MANAGER_REPO:-}}"
WORKTREE_DIR="${_env_worktree_dir:-${WORKTREE_MANAGER_WORKTREE_DIR:-}}"
if [[ -n "$_env_branch_prefix_set" ]]; then
  BRANCH_PREFIX="$_env_branch_prefix"
else
  BRANCH_PREFIX="${WORKTREE_MANAGER_BRANCH_PREFIX-}"
fi
MAIN_BRANCH="${_env_main_branch:-${WORKTREE_MANAGER_MAIN_BRANCH:-main}}"

# Worktrees live beside the checkout, not inside it, where they would show up as
# untracked files.
if [[ -z "$WORKTREE_DIR" && -n "$MAIN_REPO" ]]; then
  WORKTREE_DIR="$(dirname "$MAIN_REPO")/worktrees"
fi

# Agent-system artifacts, kept per-repo so two checkouts don't share a tracker.
TRACKER_SCRATCH="${WORKTREE_MANAGER_TRACKER_DIR:-}"
if [[ -z "$TRACKER_SCRATCH" && -n "$MAIN_REPO" ]]; then
  TRACKER_SCRATCH="$HOME/tmp/$(basename "$MAIN_REPO")-agents/scratch"
fi
SHIP_RUNS="${WORKTREE_MANAGER_SHIP_RUNS_DIR:-$HOME/tmp/ship}"

# Called by the scripts that can't do anything without a repository.
require_repo() {
  if [[ -z "$MAIN_REPO" ]]; then
    echo "error: no repository configured — set one in the app's Settings," \
         "or export WORKTREE_MANAGER_REPO=/path/to/repo" >&2
    exit 1
  fi
  if [[ ! -e "$MAIN_REPO/.git" ]]; then
    echo "error: $MAIN_REPO is not a git repository" >&2
    exit 1
  fi
}
