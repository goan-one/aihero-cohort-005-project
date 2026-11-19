#!/bin/sh
# sandbox-git-fetch.sh — bring the remote's branches within reach of the
# container, without ever letting host git read anything the container wrote.
#
# WHAT
#   sandbox-git-fetch.sh
#   Updates a bare mirror in a host-only cache directory
#   (${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-git-mirrors/<id>/mirror.git), then
#   writes every branch of it into <project>/.git-mirror.bundle — a single file
#   the container reads with ordinary git:
#
#     git fetch --prune --no-tags <project>/.git-mirror.bundle \
#       "+refs/heads/*:refs/remotes/origin/*"
#
#   Runs on the HOST, started by the loader in .sandbox/config.toml.
#
# WHY IT IS SHAPED THIS WAY
#   The container has to be able to read the objects, so something has to land
#   inside the project — and everything inside the project is writable by the
#   container (a read-only mount cannot be had from a committed project
#   configuration; see the Mounts comment in .sandbox/config.toml). The
#   question is only whether host git ever *reads* what lands there.
#
#   It used to: the mirror itself was a bare repository at <project>/.git-mirror
#   that this script fetched into, so every run handed host git a repository the
#   container could have tampered with. That needed a wall of defences — refuse
#   symlinks, refuse `commondir`/`gitdir`/`objects/info/alternates`, rewrite the
#   config from scratch, override every config key that can name a program —
#   and the wall was only as good as its list.
#
#   Now the authoritative mirror lives outside the project, where the container
#   cannot write at all, and the project only ever receives a *product*: a
#   bundle file, written to a fresh temporary name and renamed into place. The
#   rename replaces whatever is there, symlink or not, without following it, and
#   nothing on the host ever reads the file back. There is no list to keep.
#
# THE THREATS IT DEFENDS AGAINST
#   - a tampered mirror: impossible now. The mirror is outside the project.
#   - a planted symlink at .git-mirror.bundle: `mktemp` + `mv -f` writes a new
#     file and renames over the link; it never writes through it.
#   - a tampered bundle: only the container's own `git fetch` reads it, and a
#     mangled bundle makes that fetch fail. Host git never opens it.
#   - the host's environment: GIT_DIR and friends would send git to another
#     repository, so they are unset before anything runs.
#
# NOTES
#   POSIX sh. `local` is used: dash, ash and bash all support it.
#   Self-contained on purpose: it must not source anything from the project,
#   because only this file's own sha256 is pinned in the config.
#   The loader already sanitised PATH (no empty, relative or in-project
#   entries), so plain tool names are safe here. `git` is additionally resolved
#   to an absolute path outside the project, because it is the one tool here
#   that holds credentials.
#   The bundle holds the complete history of every branch, which is the simple
#   thing that works: 1.3 MB and 0.2 s for this repository. On a repository
#   large enough for that to hurt, the next step is an incremental bundle
#   (`git bundle create <file> --branches ^<what the container already has>`),
#   which needs the previous tips remembered in the cache — see
#   docs/sandbox-host-access/scripts.md.
#
# EXIT CODES
#   0 fetched   1 something failed   2 refused by policy or wrong usage
# shellcheck disable=SC3043 # `local` is not in POSIX, but dash, ash and bash
# all support it, and one of those is /bin/sh on every host this runs on.
set -euf

# Porting to another remote: change this one line.
REMOTE_URL=git@github.com:goan-one/aihero-cohort-005-project.git

# The name of the file the container reads. Keep it in .gitignore.
BUNDLE_NAME=.git-mirror.bundle

PROJECT_DIR=
CACHE_DIR=
MIRROR=
BUNDLE=
GIT=

usage() {
  cat <<'EOF'
Usage: sandbox-git-fetch.sh

Updates the host-only mirror of the remote, then writes every branch of it to
<project>/.git-mirror.bundle. Takes no arguments.

Inside the sandbox, call it through the helper:

  .sandbox/host-commands/run fetch

and then read the result with ordinary git, inside the container:

  git fetch --prune --no-tags "$PWD/.git-mirror.bundle" \
    "+refs/heads/*:refs/remotes/origin/*"

--prune is what makes a branch deleted on the remote disappear from your
origin/* refs.
EOF
}

die() {
  echo "sandbox-git-fetch: $*" >&2
  exit 1
}

refuse() {
  echo "sandbox-git-fetch: refused: $*" >&2
  exit 2
}

# The loader passes the project directory, so nothing here depends on the
# working directory (which the container chooses). Resolve it once: the bundle
# path and the cache id are built from it, and ".." must not move either.
require_project_dir() {
  [ -n "${SANDBOX_PROJECT_DIR:-}" ] ||
    die "SANDBOX_PROJECT_DIR is not set — start this script through the loader in .sandbox/config.toml"
  case $SANDBOX_PROJECT_DIR in
  /*) ;;
  *) die "SANDBOX_PROJECT_DIR is not an absolute path: $SANDBOX_PROJECT_DIR" ;;
  esac
  PROJECT_DIR=$(cd -- "$SANDBOX_PROJECT_DIR" 2>/dev/null && pwd -P) ||
    die "not a directory: $SANDBOX_PROJECT_DIR"
}

# This command inherits the environment of the `sandbox` process on the host.
# GIT_DIR and friends would send git to another repository, GIT_CONFIG_* would
# inject configuration, and a credential prompt would hang: the bridge has no
# terminal. Keep GIT_SSH_COMMAND and the credential helpers — they are how the
# host authenticates.
sanitise_git_environment() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_NAMESPACE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  GIT_TERMINAL_PROMPT=0
  export GIT_TERMINAL_PROMPT
}

# A tool must come from an absolute path outside the project, so that nothing
# the container wrote can be executed as "git".
host_tool() {
  local name resolved
  name=$1
  resolved=$(command -v "$name") ||
    die "$name is not on the host PATH"
  case $resolved in
  /*) ;;
  *) die "$name does not resolve to an absolute path: $resolved" ;;
  esac
  case $resolved in
  "$PROJECT_DIR"/*)
    die "$name resolves inside the project: $resolved"
    ;;
  esac
  printf '%s\n' "$resolved"
}

# One mirror per (remote, project), named by a hash so that no character of
# either path has to be escaped. The cache also gets a plain-text note saying
# which pair it belongs to, for whoever finds it in a year.
cache_id() {
  local sum
  sum=$(printf '%s %s' "$REMOTE_URL" "$PROJECT_DIR" | sha256sum 2>/dev/null) ||
    sum=$(printf '%s %s' "$REMOTE_URL" "$PROJECT_DIR" | shasum -a 256) ||
    die "the host has neither sha256sum nor shasum"
  printf '%.16s\n' "${sum%% *}"
}

resolve_paths() {
  local cache_root
  [ -n "${HOME:-}" ] || [ -n "${XDG_CACHE_HOME:-}" ] ||
    die "neither XDG_CACHE_HOME nor HOME is set on the host, so there is nowhere to keep the mirror"
  cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-git-mirrors
  case $cache_root in
  /*) ;;
  *) die "XDG_CACHE_HOME is not an absolute path: $cache_root" ;;
  esac
  # The whole point is that the container cannot write the mirror. If the cache
  # is inside the project, it can.
  case $cache_root in
  "$PROJECT_DIR" | "$PROJECT_DIR"/*)
    refuse "the cache directory $cache_root is inside the project, which the container can write. Point XDG_CACHE_HOME somewhere else."
    ;;
  esac
  CACHE_DIR=$cache_root/$(cache_id)
  MIRROR=$CACHE_DIR/mirror.git
  BUNDLE=$PROJECT_DIR/$BUNDLE_NAME
}

# Hooks off, and the config keys that can name a program neutralised. The
# mirror is ours now, so this is belt and braces: it keeps the fetch hermetic
# even if a cache from an older version of this script is lying around.
git_mirror() {
  "$GIT" \
    -c core.hooksPath=/dev/null \
    -c core.alternateRefsCommand= \
    -c core.fsmonitor= \
    -c uploadpack.packObjectsHook= \
    --git-dir="$MIRROR" "$@"
}

update_mirror() {
  mkdir -p "$CACHE_DIR" || die "could not create $CACHE_DIR"
  printf 'project: %s\nremote:  %s\n' "$PROJECT_DIR" "$REMOTE_URL" \
    >"$CACHE_DIR/project"
  # No template: a host template directory would otherwise add hooks that run
  # during the fetch.
  "$GIT" -c init.templateDir= init --bare --quiet "$MIRROR" ||
    die "could not initialise the mirror at $MIRROR"
  git_mirror fetch --prune --no-tags -- \
    "$REMOTE_URL" "+refs/heads/*:refs/heads/*" ||
    die "could not fetch from $REMOTE_URL (is the host's ssh key loaded?)"
}

# Write to a fresh name, then rename. `mktemp` creates the file itself, so the
# container cannot have it already; the rename replaces whatever stands at the
# target — a stale bundle, a directory's worth of nonsense, or a symlink to
# something precious — without ever writing through it.
publish_bundle() {
  local temp
  temp=$(mktemp "$PROJECT_DIR/$BUNDLE_NAME.XXXXXX") ||
    die "could not create a temporary file in $PROJECT_DIR"
  git_mirror bundle create --quiet "$temp" --branches || {
    rm -f "$temp"
    die "could not write the bundle (does the remote have any branches?)"
  }
  mv -f -- "$temp" "$BUNDLE" || {
    rm -f "$temp"
    die "could not move the bundle into place at $BUNDLE"
  }
}

summary() {
  local branches size
  branches=$(git_mirror for-each-ref --format='%(refname)' refs/heads |
    wc -l | tr -d ' ')
  size=$(wc -c <"$BUNDLE" | tr -d ' ')
  echo "mirror updated: $MIRROR"
  echo "  branch refs: $branches"
  git_mirror for-each-ref \
    --format='  %(refname:short) %(objectname:short) %(committerdate:relative)' \
    refs/heads/main refs/heads/master
  echo "bundle written: $BUNDLE ($size bytes)"
  echo "Inside the sandbox, update your remote-tracking refs from it:"
  echo "  git fetch --prune --no-tags \"$BUNDLE\" \"+refs/heads/*:refs/remotes/origin/*\""
  if [ -e "$PROJECT_DIR/.git-mirror" ]; then
    echo "Note: $PROJECT_DIR/.git-mirror is left over from the previous design"
    echo "      (the mirror lived in the project then). Nothing reads it now;"
    echo "      delete it."
  fi
}

main() {
  case ${1:-} in
  -h | --help | help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    echo "sandbox-git-fetch: takes no arguments" >&2
    usage >&2
    exit 2
    ;;
  esac
  require_project_dir
  sanitise_git_environment
  GIT=$(host_tool git)
  resolve_paths
  update_mirror
  publish_bundle
  summary
}

main "$@"
