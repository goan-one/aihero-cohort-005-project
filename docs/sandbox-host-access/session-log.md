# Session log — from a DevUI bug to sandbox host access

2026-11-19. A chronological record of the session, in the order things were
asked and found. The reasoning is summarised rather than quoted; the raw
transcript can be exported from the session itself if an exact copy is needed.

For the resulting design, see [design-decisions.md](./design-decisions.md).

---

## 1. The original task: a DevUI bug

**Asked:** in the DevUI, picking a user from the switcher switched the user but
left the list open; clicking outside did not close it either. Reproduce it with
agent-browser, fix it, open a PR with before/after screenshots.

**Reproduced** on `/courses` by driving the page from the terminal: after
picking a user, the DOM still contained all 44 entries, and it still did after
clicking elsewhere and after a navigation.

**Fixed** in `app/components/dev-ui.tsx`:

- submitting the switch form closes the list;
- while the list is open, a `pointerdown` outside the switcher or an `Escape`
  key closes it; both listeners exist only while it is open.

**Verified** the same way: 0 entries after a pick, after an outside click and
after Escape; the toggle button still opens and closes; no console errors.
`typecheck`, `lint:oxlint`, `lint:boundaries` and `test` (662) pass.
`test:mutation` had nothing in scope (it covers `app/lib` and `app/modules`).
`format:check` fails on `.claude/settings.json` and `AGENTS.md`, both
pre-existing and untouched.

**Committed** as `330aea6` on `fix/devui-switcher-close`. Screenshots were put
on an unrelated orphan branch `pr-assets`, since a PR body cannot reference
local files.

**Blocked** at the last step: the sandbox cannot push. SSH to the remote is not
reachable from the container, and no `git` command is on the host allow-list.
That blocked PR is what started everything below.

---

## 2. First proposal, and why it was wrong

**Proposed** a host rule allowing `git push origin <branch>` with a branch-name
pattern, plus `git fetch origin`.

**Then found** that `.git/hooks` and `.git/config` are writable from inside the
container. Host git run in the project therefore executes settings the
container chose. Several config keys name a program that git runs; several
hooks run during ordinary fetch and push. So the proposal was withdrawn: an
argument pattern constrains the argv, not what host git actually does.

---

## 3. Questions asked, and what was found

### Can a rule allow every branch except a deny-list?

A subagent checked this against Sandbox's matching code and its RE2 engine.

- There is **no deny mechanism**: rules are allow-only, order is irrelevant,
  duplicates are dropped, and `test_match`/`test_no_match` only run when the
  config loads.
- RE2 has **no lookahead**, so a negative pattern cannot be written directly.
- But the **complement can be generated**: a set of alternatives that matches
  every name except the denied ones. The subagent generated it, split it across
  8 alternatives to stay under the 1024-character limit, and verified every
  case, including near-misses (`mainline`, `releases/x`) and attack forms
  (`--force`, `+x`, `x:main`, `refs/heads/main`, `HEAD`).

**Conclusion:** possible, unreadable, and beside the point — the same subagent
confirmed with real git that `.git/config` can redirect an allowed
`git push origin <branch>` to a protected branch. The deny-list belongs in a
script (three lines of `case`) and, as the real guarantee, on the server.

### Would a wrapper script on the host be better?

Yes, and the interface should be its own, not an imitation of `git push`. A
partial imitation invites flags that each then need a decision; a small
explicit command is easier for an agent to use and far easier to keep safe.

The wrapper never runs git in the project: it copies the branch into a
throwaway bare repo and pushes from there to a URL fixed in the script.

### Where should the scripts live?

Successive refinements:

1. `<repo>/tools/` — but the project is mounted read-write, so the agent could
   edit the script between sessions and have the host run it.
2. `<repo>/tools/` **mounted read-only** — Sandbox allows mounts inside the
   project, and the short form is read-only. Better, but a rule naming a
   relative path can still be satisfied by a look-alike elsewhere (H1 in the
   design document).
3. Absolute path in a **user config** — closes it, but is machine-specific and
   fails the self-contained requirement.
4. `.sandbox/host-commands/` — changes there are covered by the **trust
   hash**, which covers every file under `.sandbox/`. Good for `config.toml`,
   whose changes only take effect after a restart, but not sufficient for
   scripts, which take effect immediately.
5. **Hash-checked loader** — the rule names `/bin/sh` and pins each script's
   SHA-256. Identity is content, not path. This is what was chosen.

### Can an agent shadow a command like `gh` on macOS or Linux?

Tested directly, by launching a command the way Sandbox does from a directory
containing a look-alike, with various `PATH` values:

| Host `PATH` contains                          | Look-alike runs? |
| --------------------------------------------- | ---------------- |
| only absolute system directories              | no               |
| an empty entry (`:` at either end, or `::`)   | yes              |
| `.`                                           | yes              |
| a relative entry (`bin`, `node_modules/.bin`) | yes              |
| an absolute directory inside the project      | yes              |

On native Windows a subagent found it is **unconditional**: the launcher
resolves a command against the current directory first. Since the working
directory of a host command is agent-controlled, every rule on native Windows
is effectively unrestricted. Hence: WSL on Windows, and report it upstream.

Untested but suspected: version-manager shims (mise, asdf) resolve the tool
from config files in the current directory, which the agent can write.

This is why rules name `/bin/sh` absolutely, and why the loader's first action
is to leave the working directory and sanitise `PATH`.

### Would a token inside the container be simpler?

A subagent explored the whole space and recommended exactly that: fetch over
HTTPS (verified working from the container — the repo is public and GitHub is
on Sandbox's default network allow-list) and push with a fine-grained token,
with GitHub rulesets as enforcement. Four lines of config, plain `git` for
agents, and the only option that is safe on native Windows.

**Rejected for the production project**, because the credentials would be
inside the container, and Azure DevOps PATs cannot be limited to one
repository — a leak would expose the whole organisation. ccsafetynet does not
cover this: it inspects the agent's own shell commands, not a dependency's
behaviour, not non-shell file writes, and not a stolen token.

The same subagent found that the existing `gh pr *` rule already allows host
code execution and arbitrary host file disclosure, which is why `gh` was folded
into the loader design.

### Does `npm run sandbox:hash` let an agent bypass the check?

No. The hash list in effect is the one fixed at session start. Re-running the
sync updates `config.toml`, which only takes effect after a restart, and the
trust prompt comes first. It is equivalent to the agent editing `config.toml`
directly — which it could already do. **Reviewing `git diff .sandbox/` before
accepting the trust prompt is the security boundary.**

### Should the sandbox have its own `.git`?

Viable and recommended for production. It must be a **real clone**
(`git clone --reference` keeps it cheap), not a `git worktree`, which shares
the main `.git` and so isolates nothing.

- **Removes:** host git and the IDE ever using agent-written config or hooks;
  damage to the developer's working copy, stashes and reflog; clashes between
  parallel agents.
- **Costs:** a second install/seed per clone; work flows to the agent through
  the remote (taking work _from_ it can still be a local fetch); no live view
  of the agent's files in the IDE.

---

## 3a. Two changes after the implementation was reviewed

### `--jq env` — and why no rule may name `gh`

**Found** while reviewing the rules that had been left direct: a host command
is started with the environment of the `sandbox` process, `--jq` takes a jq
program, and `env` is a jq builtin. So
`sandbox escape -- gh api repos/.../issues/1 --jq env` printed the host's whole
environment into the container — a `GH_TOKEN` or an AWS key in the shell
`sandbox` was started from included. R4, broken by one argument.

**Why no pattern fixes it:** the argument is a program, not a value. `.|env`,
`[env]`, `env.GH_TOKEN` all start like legitimate expressions, and RE2 cannot
tell a jq program that prints the environment from one that does not.

**Decided:** remove `["gh", "auth", "status"]` and both `["gh", "api", ...]`
rules, and give `sandbox-gh.sh` an `auth` and an `api` topic instead. Behind
the loader, the script runs `gh` through `env -i` with a short fixed list, so
the environment holds nothing worth printing; `--jq` therefore stays. The
secondary reasons were already known: a bare executable name is resolved
through the host's PATH from a container-chosen working directory, and only the
loader guarantees a sanitised PATH.

`.sandbox/config.toml` now holds exactly one rule. The `api` topic allows the
same endpoints the two rules did, with the repository prefixed by the script
and every id checked digit by digit.

### The mirror moved out of the project

**Asked:** the in-project `.git-mirror` was defended by a list of refusals
(symlinks, `commondir`, `gitdir`, `objects/info/alternates`, a rewritten
config). Can the residual be removed instead of defended?

**Evaluated** a host-only cache mirror plus a bundle file handed into the
project, against four questions that could have sunk it. All four answered by
experiment in `/tmp`: a `--branches` bundle carries every branch head with no
prerequisites; the container-side `git fetch --prune` does prune a branch
deleted on the remote; `mktemp` + `mv -f` over a planted symlink does not write
through it; and a container-mangled bundle only breaks the container's own
fetch, because host git never opens the file. Numbers on this repository:
1.3 MB and 0.22 s to create, 4–6 ms to fetch from.

**Implemented**, and the list of refusals went with it. What stayed is what is
still load-bearing: unsetting the `GIT_*` variables, and refusing a cache
directory inside the project. The full-history bundle is the simple thing that
works; the incremental variant is written down in the design document for
whoever meets a repository where it matters.

---

## 4. State at the end of the session

- `fix/devui-switcher-close` — the DevUI fix, committed, verified, **not
  pushed**.
- `pr-assets` — six before/after screenshots, **not pushed**.
- `own-agent-browser` is **51 commits ahead** of `origin/main` and 0 behind, so
  a PR of the fix against `main` would carry all 51. The base needs deciding:
  push `own-agent-browser` first, or rebase the fix onto `main`.
- `sandbox-host-access` — this worktree: these documents, plus the loader
  implementation.

## 5. Independent verification

Three agents touched this: one wrote it, a second reviewed it and fixed what it
found, and the session's main thread then checked the result without reusing
either of their harnesses. That third pass drove the **real loader** the way the
broker does — from a subdirectory the "agent" chose, with a `PATH` containing an
empty entry, `.`, a relative entry and an in-project directory holding a fake
`git` — against throwaway repositories in `/tmp`:

- **Identity (3):** content that is not the pinned hash, a path outside
  `.sandbox/host-commands`, and a relative path are all refused.
- **Push policy (18):** every protected name, `release/*`, `hotfix/*`, `HEAD`,
  `refs/heads/main`, `heads/main`, `tags/v1`, `work:main`, `+work`, `:work`,
  `--force`, `--delete`, `--mirror`, and a name containing a space.
- **The planted repository (6):** a normal branch reaches the remote, while
  `remote.origin.push` does not move the remote's `main`,
  `remote.origin.url` leaves the attacker repository empty, and the
  `pre-push`, `reference-transaction` and `core.fsmonitor` plants never fire.
  The fake `git` on the in-project `PATH` never runs.
- **`gh` (11):** `merge`, `close`, `--body-file <path>`, `--body-file=<path>`
  and a `--repo` override refused; the Wayfinder `api` calls produce the
  endpoint prefixed with the pinned repository; another repository's endpoint,
  `api user`, `-F id=@/etc/passwd`, a non-numeric id, `-X DELETE` and
  `auth status --show-token` refused.
- **The environment (2):** with `GH_TOKEN` and a second secret set on the
  "host", neither reaches `gh` — including through `api … --jq env`, the call
  that prompted the change.
- **The fetch (6):** the mirror is created in the host cache outside the
  project, only `.git-mirror.bundle` appears inside it, no git directory is
  created in the project, the container-side fetch from the bundle produces
  `origin/main`, and a cache directory inside the project is refused.

Also checked at the source rather than taken on trust: the three pinned hashes
match the scripts on disk; `.sandbox/config.toml` contains exactly one rule and
no rule naming `gh`; and Sandbox's `parseMount` does expand a one-sided mount
entry to a relative container target, which is what made the read-only mirror
mount impossible in the first place.

Not verified by anyone, because it needs a restart and a real network: the
broker's own matching of the loader rule, and `gh` behaviour against the real
GitHub (`api`, `auth status`, `--body-file -`).

## 6. Open questions for the production refinement

1. Which `gh` / `az repos` subcommands are genuinely safe to allow — the
   allow-list in `sandbox-gh.sh` is a starting point, not a verified set. Its
   `api` and `auth status` topics have never been run against the real GitHub,
   only against a fake `gh` that prints its argv and environment.
2. Whether a read-only mount of `.sandbox/host-commands` behaves as expected —
   this needs a container restart to test. For `.git-mirror` the question is
   gone: there is nothing in the project left to protect.
3. Whether making `.git/config` and `.git/hooks` read-only in the container
   breaks legitimate agent work (`git config`, upstream tracking, Husky).
4. Whether any developer needs native Windows, which this design cannot
   support.
5. Reporting the Windows command-resolution finding to the Sandbox
   maintainers.
