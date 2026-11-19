#!/bin/sh
# sandbox-gh.sh — the only way `gh` runs on the host.
#
# WHAT
#   sandbox-gh.sh <pr|issue> <subcommand> [argument]...
#   sandbox-gh.sh api <endpoint> [--jq <program>] [--paginate]
#   sandbox-gh.sh api --method POST <endpoint> -F <field>=<number>
#   sandbox-gh.sh auth status
#   Runs the host's `gh` with the repository pinned to the one below, an
#   allow-list of subcommands and endpoints, an allow-list of flags, and a
#   short fixed environment. Runs on the HOST, started by the loader in
#   .sandbox/config.toml. It replaces every rule that used to name `gh`:
#   `["gh", ["issue", "pr"], "*"]`, `["gh", "auth", "status"]` and the two
#   `["gh", "api", ...]` rules for Wayfinder.
#
# WHY NO RULE MAY NAME `gh` ANY MORE
#   1. The environment. A host command is given the environment of the
#      `sandbox` process (broker.ts passes its own process.env), `--jq` takes a
#      jq program, and `env` is a jq builtin — so `gh api <endpoint> --jq env`
#      printed the host's whole environment into the container. No argument
#      pattern can prevent that, because the argument is a program and `.|env`
#      starts like any legitimate expression. On a host that authenticates with
#      GH_TOKEN in a shell profile, that was requirement R4 broken by one
#      argument. Replacing the environment, which only a script can do, is the
#      fix — see WHY THE ENVIRONMENT IS REPLACED below.
#   2. The executable. `gh` in a rule is a bare name, resolved through the
#      host's PATH from a working directory the container chooses, so a
#      relative, empty or in-project PATH entry turns it into "run the agent's
#      own file". Only the loader guarantees a sanitised PATH.
#   3. The arguments. `*` allowed `--body-file <any host file>`, whose contents
#      gh then publishes, and subcommands such as `gh pr merge`. Some gh
#      subcommands also run host git *inside the project*, whose config and
#      hooks the container writes.
#
# WHY THESE SUBCOMMANDS
#   Allowed: the read and write operations an agent needs to work a ticket and
#   open a pull request — create, view, list, diff, comment, edit, ready. None
#   of them changes code, merges anything, or touches a local checkout.
#   Refused on purpose:
#     merge, pr ready-to-merge style operations that land code  -> a human merges.
#     checkout, pr develop                                      -> runs git in the project (see WHY above).
#     close, reopen, delete, transfer, lock, pin                -> closing a ticket is a human decision.
#     review (approve/request-changes)                           -> an agent must not approve its own work.
#     --web                                                     -> opens a browser on the host.
#   `auth status` is allowed because it reports which account the host is
#   logged in as and touches no repository; it takes no arguments, because
#   `--show-token` would print the token into the container.
#   This list is a starting point, not a verified set: see
#   docs/sandbox-host-access/scripts.md and widen it deliberately.
#
# WHY THESE API ENDPOINTS
#   `api` exists for the two GitHub features that have no `gh issue` equivalent
#   and that docs/agents/issue-tracker.md needs: an issue's database id, and
#   sub-issue / "blocked by" edges. It covers exactly what the two rules it
#   replaces covered, and keeps their narrowness:
#     GET  issues/<n>, issues/<n>/sub_issues, issues/<n>/dependencies/blocked_by
#     POST issues/<n>/sub_issues, issues/<n>/dependencies/blocked_by
#          with one -F sub_issue_id=<number> or -F issue_id=<number>
#   The repository is not something the caller passes: the endpoint is relative
#   to REPO below, so `repos/<other>/...` cannot be reached. Every id is digits
#   only, which is also what stops `-F x=@/etc/passwd` from uploading a host
#   file. No other method, flag or endpoint gets through.
#
# WHY THESE FLAGS
#   Flags are allow-listed rather than deny-listed, because every gh release can
#   add another one that reads a host file. Anything that reads a path is
#   refused: --body-file <path>, -F/-f/--field/--raw-field, --template, --input.
#   The single exception is `--body-file -`, which reads standard input — that
#   comes from the container through the bridge, not from the host filesystem,
#   and it is the only sane way to pass a long pull-request body.
#
# WHY THE ENVIRONMENT IS REPLACED
#   A host command inherits the environment of the `sandbox` process, and a
#   `--jq` expression can print it (`--jq env`), so every variable the host
#   happens to export would be readable from inside the container. gh therefore
#   starts from a short, fixed list. No token is on it: a GitHub token in the
#   host's shell must not be one argument away from the container (requirement
#   R4). Authenticate the host with `gh auth login`, not with GH_TOKEN.
#   `--jq env` still works, and now prints that short list — HOME, PATH and a
#   handful of empty placeholders. That is why `--jq` may stay: the leak was
#   the environment, not the flag.
#
# NOTES
#   POSIX sh. `local` is used: dash, ash and bash all support it.
#   Self-contained on purpose: it must not source anything from the project,
#   because only this file's own sha256 is pinned in the config.
#   A flag value that itself starts with "-" (`--title "-x"`) is refused: the
#   scan cannot tell a value from a flag. Reword the value.
#
# EXIT CODES
#   gh's own exit code on success   1 something failed   2 refused by policy
# shellcheck disable=SC3043 # `local` is not in POSIX, but dash, ash and bash
# all support it, and one of those is /bin/sh on every host this runs on.
set -euf

# Porting to another host or repository: change this one line (and for Azure
# DevOps, replace this script with the `az repos` equivalent).
REPO=goan-one/aihero-cohort-005-project

ALLOWED_PR_SUBCOMMANDS="create view list diff comment edit ready"
ALLOWED_ISSUE_SUBCOMMANDS="create view list comment edit"

ALLOWED_FLAGS="--help -h
--json --jq -q
--comments -c
--limit -L
--state -s
--search -S
--label -l --add-label --remove-label
--assignee -a --add-assignee --remove-assignee
--author -A
--milestone -m
--title -t
--body -b
--body-file
--base -B
--head -H
--draft -d
--name-only --patch"

PROJECT_DIR=
GH=
ENV_TOOL=

usage() {
  cat <<'EOF'
Usage: sandbox-gh.sh <pr|issue> <subcommand> [argument]...
       sandbox-gh.sh api <endpoint> [--jq <program>] [--paginate]
       sandbox-gh.sh api --method POST <endpoint> -F <field>=<number>
       sandbox-gh.sh auth status

EOF
  # Printed, not written out again, so that --help cannot drift from the lists
  # this script enforces.
  printf 'Allowed: gh pr    %s\n' "$ALLOWED_PR_SUBCOMMANDS"
  printf '         gh issue %s\n' "$ALLOWED_ISSUE_SUBCOMMANDS"
  printf 'The repository is always %s: --repo is added for you on pr and\n' "$REPO"
  echo "issue, built into the path on api, and refused if you pass it."
  cat <<'EOF'

  sandbox-gh.sh issue view 7 --comments
  sandbox-gh.sh issue list --state open --label bug --json number,title
  sandbox-gh.sh pr create --base main --head fix/foo --title "..." --body "..."
  sandbox-gh.sh pr create --base main --head fix/foo --title "..." --body-file -
  sandbox-gh.sh auth status

`gh` runs with no local repository, so `pr create` needs --head (and --base);
--fill and friends are refused because they would read a local checkout.

`api` endpoints are relative to the repository, and only these shapes exist:

  sandbox-gh.sh api issues/7 --jq .id
  sandbox-gh.sh api issues/7/sub_issues
  sandbox-gh.sh api issues/7/dependencies/blocked_by --jq '.[].number'
  sandbox-gh.sh api --method POST issues/7/sub_issues -F sub_issue_id=987654
  sandbox-gh.sh api --method POST issues/7/dependencies/blocked_by -F issue_id=987654

Every number is digits only, and a POST takes exactly one -F field, so no
argument can name a host file.

Inside the sandbox, call it through the helper:

  .sandbox/host-commands/run gh issue view 7 --comments
EOF
}

die() {
  echo "sandbox-gh: $*" >&2
  exit 1
}

refuse() {
  echo "sandbox-gh: refused: $*" >&2
  exit 2
}

# The loader passes the project directory, so nothing here depends on the
# working directory (which the container chooses). Resolve it once: the check
# in host_tool is textual, and ".." must not defeat it.
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

# A tool must come from an absolute path outside the project, so that nothing
# the container wrote can be executed as "gh".
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

check_subcommand() {
  local topic subcommand allowed candidate
  topic=$1
  subcommand=$2
  case $topic in
  pr) allowed=$ALLOWED_PR_SUBCOMMANDS ;;
  issue) allowed=$ALLOWED_ISSUE_SUBCOMMANDS ;;
  *) refuse "no subcommands are defined for \`$topic\`" ;;
  esac
  for candidate in $allowed; do
    [ "$subcommand" != "$candidate" ] || return 0
  done
  case $subcommand in
  merge)
    refuse "a human merges. Open the pull request and ask for a review."
    ;;
  checkout | develop)
    refuse "\`gh $topic $subcommand\` works on a local checkout, which this helper never touches. Use ordinary git inside the sandbox."
    ;;
  close | reopen | delete | transfer | lock | unlock | pin | unpin)
    refuse "\`gh $topic $subcommand\` changes the state of a ticket; that stays with a human. Say what you would close, and why."
    ;;
  review)
    refuse "an agent does not review or approve a pull request. Use \`$topic comment\` to say what you found."
    ;;
  esac
  refuse "\`gh $topic $subcommand\` is not on the allow-list in .sandbox/host-commands/sandbox-gh.sh (allowed: $allowed)"
}

is_allowed_flag() {
  local candidate flag
  candidate=$1
  for flag in $ALLOWED_FLAGS; do
    [ "$candidate" != "$flag" ] || return 0
  done
  return 1
}

# Scans every argument, because a flag that reads a host file must not get
# through in any position or spelling (--flag value, --flag=value, -Fvalue).
check_arguments() {
  local argument expect_stdin
  expect_stdin=no
  for argument in "$@"; do
    if [ "$expect_stdin" = yes ]; then
      [ "$argument" = "-" ] ||
        refuse "--body-file only reads standard input here. Pass \`--body-file -\` and pipe the text in, or use --body."
      expect_stdin=no
      continue
    fi
    case $argument in
    --)
      refuse "\`--\` would hide the arguments after it from this check"
      ;;
    --body-file=-) ;;
    --body-file) expect_stdin=yes ;;
    --body-file=* | -F | -F=* | -f | -f=* | --field | --field=* | --raw-field | --raw-field=* | --template | --template=* | --input | --input=*)
      refuse "$argument reads a host file. Use --body, or \`--body-file -\` and pipe the text in."
      ;;
    --web | -w)
      refuse "$argument opens a browser on the host. Read the result here instead (--json, --comments)."
      ;;
    --repo | --repo=* | -R | -R=*)
      refuse "the repository is fixed to $REPO and added for you"
      ;;
    --hostname | --hostname=*)
      refuse "$argument would point gh at another GitHub host"
      ;;
    --fill | --fill-first | --fill-verbose | --editor | -e | --recover | --recover=*)
      refuse "$argument reads a local checkout or opens an editor on the host. Pass --title and --body explicitly."
      ;;
    -*)
      # Also catches every short flag with its value attached (-Fx), and every
      # cluster of short flags (-cF), because neither is on the list.
      is_allowed_flag "${argument%%=*}" ||
        refuse "$argument is not on the flag allow-list in .sandbox/host-commands/sandbox-gh.sh"
      ;;
    *) ;;
    esac
  done
  [ "$expect_stdin" = no ] || refuse "--body-file needs a value; pass \`--body-file -\`"
}

is_digits() {
  case ${1:-} in
  "" | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# An endpoint is always relative to REPO, so `repos/<someone-else>/...` and an
# absolute URL cannot be expressed. Every number is checked digit by digit,
# which also rejects `..`, a query string and `@file`.
check_api_endpoint() {
  local endpoint kind number
  endpoint=$1
  kind=$2
  case $endpoint in
  issues/*/sub_issues)
    number=${endpoint#issues/}
    number=${number%/sub_issues}
    ;;
  issues/*/dependencies/blocked_by)
    number=${endpoint#issues/}
    number=${number%/dependencies/blocked_by}
    ;;
  issues/*)
    [ "$kind" = read ] ||
      refuse "a POST may only go to issues/<n>/sub_issues or issues/<n>/dependencies/blocked_by, not $endpoint"
    number=${endpoint#issues/}
    ;;
  *)
    refuse "$endpoint is not one of the endpoints this script allows. Run sandbox-gh.sh --help for the list."
    ;;
  esac
  is_digits "$number" ||
    refuse "the issue number must be digits only, so \`$endpoint\` is refused"
}

check_api_field() {
  local field value
  field=$1
  case $field in
  sub_issue_id=* | issue_id=*) value=${field#*=} ;;
  *)
    refuse "a POST field must be sub_issue_id=<number> or issue_id=<number>, not $field"
    ;;
  esac
  is_digits "$value" ||
    refuse "the id must be digits only — GitHub's numeric database id, not #number or a file: $field"
}

# Only --jq and --paginate may follow the endpoint. The jq program itself is
# free text: gh's jq cannot read files, and the environment it can print is the
# short one this script builds.
check_api_read_flags() {
  local argument expect_program
  expect_program=no
  for argument in "$@"; do
    if [ "$expect_program" = yes ]; then
      expect_program=no
      continue
    fi
    case $argument in
    --paginate) ;;
    --jq) expect_program=yes ;;
    --jq=*) ;;
    *)
      refuse "after the endpoint, only --jq <program> and --paginate are allowed, not $argument"
      ;;
    esac
  done
  [ "$expect_program" = no ] || refuse "--jq needs a jq program"
}

run_topic_api() {
  local endpoint
  case ${1:-} in
  "")
    refuse "say which endpoint: sandbox-gh.sh api issues/<n> [--jq <program>]"
    ;;
  --method | --method=* | -X) run_api_post "$@" ;;
  -*)
    refuse "the endpoint comes first: sandbox-gh.sh api issues/<n> [--jq <program>] [--paginate]"
    ;;
  *)
    endpoint=$1
    shift
    check_api_endpoint "$endpoint" read
    check_api_read_flags "$@"
    run_gh api "repos/$REPO/$endpoint" "$@"
    ;;
  esac
}

run_api_post() {
  local endpoint
  case $1 in
  --method | -X)
    shift
    [ "${1:-}" = POST ] ||
      refuse "only POST is available here, not \`${1:-}\`"
    ;;
  --method=*)
    [ "${1#--method=}" = POST ] ||
      refuse "only POST is available here, not \`${1#--method=}\`"
    ;;
  esac
  shift
  [ $# -ge 1 ] ||
    refuse "say which endpoint: sandbox-gh.sh api --method POST issues/<n>/sub_issues -F sub_issue_id=<number>"
  endpoint=$1
  shift
  check_api_endpoint "$endpoint" write
  [ $# -eq 2 ] ||
    refuse "a POST takes exactly one field: -F sub_issue_id=<number> or -F issue_id=<number>"
  [ "$1" = "-F" ] ||
    refuse "a POST takes exactly one field: -F sub_issue_id=<number> or -F issue_id=<number>"
  check_api_field "$2"
  run_gh api --method POST "repos/$REPO/$endpoint" -F "$2"
}

run_topic_auth() {
  [ $# -ge 1 ] || refuse "the only check available here is \`auth status\`"
  [ "$1" = status ] ||
    refuse "only \`auth status\` is available here, not \`auth $1\`"
  [ $# -eq 1 ] ||
    refuse "\`auth status\` takes no arguments — --show-token would print the host's token into the container"
  run_gh auth status
}

run_topic_issue_or_pr() {
  local topic subcommand
  topic=$1
  shift
  [ $# -ge 1 ] ||
    refuse "say which subcommand: sandbox-gh.sh $topic <subcommand> ..."
  subcommand=$1
  shift
  check_subcommand "$topic" "$subcommand"
  check_arguments "$@"
  run_gh "$topic" "$subcommand" --repo "$REPO" "$@"
}

# A short, fixed environment instead of the host's whole one — see WHY THE
# ENVIRONMENT IS REPLACED above. The optional entries are passed even when they
# are empty, which gh and the Go libraries behind it treat as unset.
# HTTPS_PROXY is forwarded because a corporate host needs it; a proxy URL with
# a password in it would be readable from the container, so do not use one.
# Resolving the tools happens here, after every check, so that a refusal never
# depends on gh being installed.
run_gh() {
  require_project_dir
  [ -n "${HOME:-}" ] || die "HOME is not set on the host, so gh cannot find its configuration"
  GH=$(host_tool gh)
  ENV_TOOL=$(host_tool env)
  exec "$ENV_TOOL" -i \
    "HOME=$HOME" \
    "PATH=$PATH" \
    "TMPDIR=${TMPDIR-}" \
    "XDG_CONFIG_HOME=${XDG_CONFIG_HOME-}" \
    "XDG_STATE_HOME=${XDG_STATE_HOME-}" \
    "XDG_DATA_HOME=${XDG_DATA_HOME-}" \
    "GH_CONFIG_DIR=${GH_CONFIG_DIR-}" \
    "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS-}" \
    "SSL_CERT_FILE=${SSL_CERT_FILE-}" \
    "SSL_CERT_DIR=${SSL_CERT_DIR-}" \
    "HTTPS_PROXY=${HTTPS_PROXY-}" "https_proxy=${https_proxy-}" \
    "HTTP_PROXY=${HTTP_PROXY-}" "http_proxy=${http_proxy-}" \
    "NO_PROXY=${NO_PROXY-}" "no_proxy=${no_proxy-}" \
    GH_PAGER=cat GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$GH" "$@"
}

main() {
  local topic
  case ${1:-} in
  "")
    usage >&2
    exit 2
    ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  esac
  topic=$1
  shift
  case $topic in
  pr | issue) run_topic_issue_or_pr "$topic" "$@" ;;
  api) run_topic_api "$@" ;;
  auth) run_topic_auth "$@" ;;
  *)
    refuse "only \`pr\`, \`issue\`, \`api\` and \`auth status\` are available here, not \`$topic\`"
    ;;
  esac
}

main "$@"
