#!/bin/sh
# sandbox-git-push.sh — publish work branches from the project to the remote.
#
# WHAT
#   sandbox-git-push.sh <branch>...
#   Copies each named branch out of the project into a throwaway bare repo and
#   pushes it from there to the URL fixed below, with explicit non-force
#   refspecs. Runs on the HOST, started by the loader in .sandbox/config.toml.
#
# WHY IT IS SHAPED THIS WAY
#   The project is mounted read-write into the container, so .git/config and
#   .git/hooks are whatever the agent wrote. Host git run *inside* the project
#   would obey them: several config keys name a program git then executes, and
#   `remote.origin.push` alone is enough to redirect an allowed
#   `git push origin <branch>` to a protected branch. So this script never runs
#   git in the project. The project is only ever a repository to fetch *from*,
#   into a fresh bare repo under $TMPDIR whose config we own, and the push
#   names a hard-coded URL and full refspecs rather than a remote.
#
# THE THREATS IT DEFENDS AGAINST
#   - argv is agent-controlled: every branch name is validated before use, and
#     `--` separates options from operands so a name can never become a flag.
#   - the project repo is agent-controlled: no git command runs in it, hooks are
#     disabled for the commands that read it, and nothing in its config can
#     influence where the push lands.
#   - protected branches and history rewrites: deny-list below, no `+` in any
#     refspec, no --force, no --delete, no --mirror.
#   Residual risk, accepted: fetching from the project makes host git parse a
#   repository the container controls, and spawn `upload-pack` in it. Keep host
#   git current. See docs/sandbox-host-access/design-decisions.md.
#
# NOTES
#   POSIX sh. `local` is used: dash, ash and bash all support it, and it is the
#   one non-POSIX construct here (documented in README.md).
#   The script is self-contained on purpose: it must not source anything from
#   the project, because only this file's own sha256 is pinned in the config.
#   The loader already sanitised PATH (no empty, relative or in-project
#   entries), so plain tool names are safe here. `git` is additionally resolved
#   to an absolute path outside the project, because it is the one tool here
#   that holds credentials.
#
# EXIT CODES
#   0 pushed   1 something failed   2 refused by policy or wrong usage
# shellcheck disable=SC3043 # `local` is not in POSIX, but dash, ash and bash
# all support it, and one of those is /bin/sh on every host this runs on.
set -euf

# Porting to another remote: change this one line.
REMOTE_URL=git@github.com:goan-one/aihero-cohort-005-project.git

# Branches the agent may not push to. `release/*` and `hotfix/*` are handled as
# prefixes below. The real guarantee is server-side (GitHub rulesets / Azure
# DevOps branch policies); this is the second line of defence.
PROTECTED_BRANCHES="main master develop trunk staging production"

PROJECT_DIR=
GIT=
# WORK and BARE are script-level on purpose: the EXIT trap that removes the
# temporary repository runs after the function has returned, where a `local`
# would already be out of scope.
WORK=
BARE=

usage() {
  cat <<'EOF'
Usage: sandbox-git-push.sh <branch>...

Pushes each branch of the project to the remote, fast-forward only.

  sandbox-git-push.sh fix/devui-switcher-close
  sandbox-git-push.sh fix/one feature/two

Refused: main, master, develop, trunk, staging, production, release/*,
hotfix/* — and any force push, deletion or raw refspec. To replace a branch
that has already been pushed, push it under a new name.

Inside the sandbox, call it through the helper:

  .sandbox/host-commands/run push <branch>...
EOF
}

die() {
  echo "sandbox-git-push: $*" >&2
  exit 1
}

refuse() {
  echo "sandbox-git-push: refused: $*" >&2
  exit 2
}

# The loader passes the project directory, so nothing here depends on the
# working directory (which the container chooses). Resolve it once: every
# comparison below is textual, and ".." must not defeat it.
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

# Every git command runs against the throwaway bare repo, with hooks disabled
# and with the config keys that can name a program neutralised. `-c` travels to
# the `upload-pack` that git starts inside the project, which is the one place
# where a repository the container controls is read.
git_bare() {
  "$GIT" \
    -c core.hooksPath=/dev/null \
    -c core.alternateRefsCommand= \
    -c core.fsmonitor= \
    -c uploadpack.packObjectsHook= \
    --git-dir="$BARE" "$@"
}

refuse_protected() {
  echo "sandbox-git-push: refused: $1 is a protected branch." >&2
  echo "Push your own work branch instead (for example fix/<what> or feature/<what>)" >&2
  echo "and open a pull request against $1." >&2
  exit 2
}

check_branch() {
  local branch protected
  branch=$1
  # The ref-path forms are here because `git check-ref-format --branch` accepts
  # "refs/heads/main" as a valid *branch name*, which would then reach the
  # remote as a branch literally called refs/heads/main.
  case $branch in
  "") refuse "empty branch name" ;;
  -* | +*)
    refuse "a branch name may not start with '-' or '+': $branch"
    ;;
  *:*)
    refuse "a branch name may not contain ':' — refspecs are not accepted: $branch"
    ;;
  HEAD | refs/* | heads/* | tags/* | remotes/*)
    refuse "pass a plain branch name, not a ref path: $branch"
    ;;
  esac
  for protected in $PROTECTED_BRANCHES; do
    [ "$branch" != "$protected" ] || refuse_protected "$branch"
  done
  case $branch in
  release/* | hotfix/*) refuse_protected "$branch" ;;
  esac
  # Rejects whitespace, control characters and the glob characters, which is
  # what makes the refspec list below safe to split on spaces.
  "$GIT" check-ref-format --branch "$branch" >/dev/null 2>&1 ||
    refuse "not a valid branch name: $branch"
}

# Branch names cannot contain whitespace — check_branch has run — so building a
# space-separated refspec list and letting the shell split it is safe here.
refspecs_for() {
  local branch out
  out=
  for branch in "$@"; do
    out="$out refs/heads/$branch:refs/heads/$branch"
  done
  printf '%s\n' "${out# }"
}

publish() {
  local refspecs branch
  refspecs=$(refspecs_for "$@")
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/sandbox-git-push.XXXXXX") ||
    die "could not create a temporary directory"
  trap 'rm -rf "$WORK"' EXIT HUP INT TERM
  BARE=$WORK/push.git
  # No template: a host template directory would otherwise put hooks in here.
  "$GIT" -c init.templateDir= init --bare --quiet "$BARE" ||
    die "could not create the temporary repository"

  # shellcheck disable=SC2086 # deliberate word splitting, see refspecs_for;
  # `set -f` keeps the shell from also expanding it as a glob.
  git_bare fetch --no-tags --quiet -- "$PROJECT_DIR" $refspecs ||
    die "could not read $* from the project — is every branch committed and named correctly?"

  # No '+' in any refspec and no --force: the remote rejects anything that is
  # not a fast-forward.
  # shellcheck disable=SC2086 # deliberate word splitting, see refspecs_for
  git_bare push --atomic -- "$REMOTE_URL" $refspecs ||
    die "the remote rejected the push (see above). A rewritten branch has to go under a new name."

  echo "pushed to $REMOTE_URL:"
  for branch in "$@"; do
    echo "  $branch"
  done
}

main() {
  local branch
  case ${1:-} in
  -h | --help | help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
  esac
  require_project_dir
  sanitise_git_environment
  GIT=$(host_tool git)
  for branch in "$@"; do
    check_branch "$branch"
  done
  publish "$@"
}

main "$@"
