# Giving a sandboxed agent git access — design decisions

Written 2026-11-19, in the session that produced `.sandbox/host-commands/`.
It records **why** the implementation looks the way it does, so that a later
session can refine it for the production project (Azure DevOps) without
redoing the analysis.

Companion documents:
[scripts.md](./scripts.md), what each script behind the loader does about these
constraints, and [session-log.md](./session-log.md), the chronological record of
how the decisions were reached.

## The problem

Agents run inside [Sandbox](https://github.com/MaibornWolff/sandbox), a
Docker-based container. The project is mounted read-write at the same path as
on the host. The container has no credentials and cannot reach the git remote
over SSH.

An agent needs two things to finish a piece of work:

1. **push** its own branch, so a pull request can be opened;
2. **fetch**, so it can see the current `origin/main`, choose the right PR
   base, and rebase.

`sandbox escape -- <argv>` runs a command **on the host** if it matches an
`[[allow_host_commands]]` rule in `.sandbox/config.toml`. That is the only
route to the host's credentials.

## Requirements

| #   | Requirement                                                                                                                                                       |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1  | The agent can push its own work branches.                                                                                                                         |
| R2  | The agent can fetch the current state of the remote.                                                                                                              |
| R3  | Self-contained in the project: works for every developer after a clone. No per-user config, no machine-specific absolute paths, no install step.                  |
| R4  | Credentials never enter the container.                                                                                                                            |
| R5  | Protected branches (`main`, `master`, `develop`, `trunk`, `staging`, `production`, `release/*`, `hotfix/*`) cannot be pushed to, and no push can force or delete. |
| R6  | Nothing the container can write may lead to code running on the host.                                                                                             |
| R7  | Simple: small scripts, few moving parts, easy to read and maintain.                                                                                               |

R4 is what ruled out the alternative design (a token inside the container).
R6 is what shaped the loader.

## What makes this hard

Three properties of Sandbox, each verified against its source in
`/opt/sandbox-cli`:

### H1 — the working directory of a host command is agent-controlled

`broker.ts: mapWorkingDirectory` maps the container's current directory to the
host. Any subdirectory of the project is accepted. Rules cannot constrain it.

Consequence: a rule naming a **relative** script path does not identify a
file. The agent can place a file with the same relative path under a
subdirectory it controls and invoke the rule from there.

The other half of the same function is useful, though: it resolves the
candidate with `realpath` and refuses anything that is not inside the host
project root. So the working directory a host command starts in is _some_
directory inside the project — never outside it, never a symlink out of it.
That is the one piece of trustworthy input the loader gets, and it is what it
uses to find the project root (see below).

### H2 — rules and trust are evaluated once, at session start

The broker compiles the rule set at startup (`broker.ts:431`) and re-checks
nothing per command (`broker.ts:220`). Project trust is checked while loading
the configuration (`configuration-service.ts:129`); the hash covers every text
file under `.sandbox/` (`project-trust.ts:55`).

Consequence: `config.toml` may stay writable by the agent, because a change
only takes effect after a restart, and the trust prompt comes first. A
**script file** that a rule runs may not, because it would take effect
immediately, within the session.

### H3 — the project's `.git` is writable by the container

`.git/config` and `.git/hooks` are inside the mount. Host git run **inside the
project** therefore obeys settings the container chose. Several config keys
name a program that git then executes, and several hooks run during ordinary
fetch and push activity.

Consequence: a host-side helper must never run git **in the project repo**.
The project may only be used as a read-only source to fetch from.

This was confirmed experimentally during the session: with
`remote.origin.push` pointing elsewhere, an allowed `git push origin <branch>`
updated a different branch; and a `core.fsmonitor` entry caused a program to
run during a plain `git status`.

"Only fetch from it" is not quite free of H3 either, and the review of the
implementation sharpened it: `git fetch <path>` starts `git upload-pack` **in**
that path, as a child process, and that child reads the project's config. Two
things make it survivable, and both were tested on git 2.47: the client's `-c`
overrides travel to the child through `GIT_CONFIG_PARAMETERS`, and git already
refuses to honour `uploadpack.packObjectsHook` from repository config, exactly
because the repository being served may be untrusted. The helper still passes
`-c core.hooksPath=/dev/null -c core.alternateRefsCommand= -c core.fsmonitor=
-c uploadpack.packObjectsHook=`, so that it does not depend on that. Neither a
hook nor any of those keys fired in the test harness. This is the one place
where host git parses a repository the container controls, and it is the reason
"keep host git current" is a caveat rather than a nicety.

## The decision: a hash-checked loader

Rules name `/bin/sh` — an absolute path that exists on every macOS and Linux
machine — and pass a small **fixed loader** as `-c` text. The loader:

1. finds the project root by climbing from the working directory (trustworthy,
   see H1) to the topmost ancestor that holds a `.sandbox/config.toml` — the
   file the loader itself came from;
2. resolves the requested script path and refuses it unless it ends up in that
   root's own `.sandbox/host-commands/` directory;
3. leaves the agent-controlled working directory (`cd /`) and sanitises `PATH`
   against that root, so helper programs cannot be shadowed;
4. copies the requested script to a host-side temporary file;
5. computes the copy's SHA-256 and compares it against the hashes listed in
   the rule;
6. runs the copy only on a match, and passes the root to it in
   `SANDBOX_PROJECT_DIR`.

Steps 1 and 2 are why the root is not derived from the script path, which is
the obvious way to do it and is wrong: that path is an argument the container
chooses, so a copy of a pinned script in `sub/.sandbox/host-commands/` would
name `sub` as the project and leave `<project>/bin` on `PATH`, and a path with
`..` in it would name a project directory that no textual comparison matches.
It is also what keeps a second checkout of this project elsewhere on the host
out of reach: its scripts hash the same, but they are not in this root.

The climb takes the _topmost_ ancestor, not the nearest, because the container
can plant a `.sandbox/config.toml` deeper in the tree and a deeper root is a
narrower `PATH` filter. If it ever finds a root above the real project — a
stray `.sandbox/config.toml` in a parent directory, which Sandbox itself never
creates; its own user configuration lives in `~/.config/sandbox` — then step 2
refuses the call and names the root it found, instead of running a script with
the wrong project directory.

**The script's identity is its content, not its path.** That answers H1: a
file placed elsewhere does not have a listed hash. It answers H2: a script
edited during a session no longer matches the hash fixed at startup, so the
call is refused and the host only ever runs the text that was trusted when the
session began. Hashing the _copy_ rather than the original closes the gap
between checking and running.

### Why not the alternatives

| Alternative                                                    | Why not                                                                                                                                                                                                             |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Absolute script path in a rule                                 | Machine-specific, so it must live in each developer's user config. Fails R3.                                                                                                                                        |
| Whole script inline in `config.toml`                           | Secure and self-contained, but the config becomes the source of a long shell program. Rejected on maintainability (R7).                                                                                             |
| Read-only mount of the script directory                        | Blocks in-session edits, but a look-alike elsewhere still satisfies a relative rule (H1). Needs inline code to find the project root anyway.                                                                        |
| Host `git push` allowed directly, hardened with `-c` overrides | The set of config keys that can run a program is open-ended; every git release may add one. Fails R6.                                                                                                               |
| Token inside the container, enforcement by server-side rules   | Simplest by far, and the only option that works on native Windows. Fails R4. For Azure DevOps it is worse than for GitHub: a PAT cannot be scoped to a single repository, so a leak exposes the whole organisation. |
| A branch-name deny-list expressed purely as a Sandbox rule     | Possible — RE2 has no lookahead, but the complement can be generated — and it was proven to work. Useless on its own, because H3 means the argv is not what decides where the push lands.                           |

## Caveats that are not solved by this design

1. **Native Windows is not supported; use WSL.** There is no `/bin/sh`, and
   Windows resolves a command against the current directory first, which means
   _any_ host-command rule can be satisfied by a file the agent placed. This
   affects Sandbox generally, not just this design, and is worth reporting
   upstream.
2. **`.git` is shared with the host (H3).** Any git command run on the host in
   this checkout — including an IDE's background `git status` — uses config
   and hooks the container can write. The recommended mitigation is a
   **separate clone per sandbox** (`git clone --reference`, not
   `git worktree`), so the developer's own checkout is never touched by the
   agent. Trade-off: handing work _to_ the agent then goes through the remote;
   taking work _from_ it can still be a local `git fetch ../agent-clone`.
3. **Server-side protection is still required** as the real guarantee:
   GitHub rulesets, or Azure DevOps branch policies plus _deny Force push_.
   The scripts are a client-side convenience, and a second line of defence.
4. **Host git parses a repo the container controls** when the push script
   fetches from the project, and starts `upload-pack` inside it (H3). Keep host
   git current; this class of bug has had CVEs.
5. **The trust prompt is the security boundary for configuration.** An agent
   may edit `config.toml` and re-run the hash sync; both only take effect
   after a restart, and the prompt precedes it. Always review
   `git diff .sandbox/` before accepting, and before checking out a branch
   that touches `.sandbox/`.
6. **The host's environment reaches every host command**, because the broker
   passes its own `process.env` through. `sandbox-gh.sh` replaces it before
   starting `gh`, and the git scripts drop the `GIT_*` variables that would
   redirect git, but the loader and the scripts themselves still start with it.
   Do not keep tokens in the shell you start `sandbox` from.
7. **The project's `.git` may be a gitfile.** `git fetch <project>` follows
   `.git` wherever it points, and the container can rewrite that file, so the
   push script can be made to read a different repository on the host and
   publish a branch out of it to this project's remote. Refusing a gitfile is
   not an option: a `git worktree` checkout is one, which is how this project
   is often developed. The separate-clone mitigation in caveat 2 covers this
   as well, and server-side review of what arrives is the backstop.

## Porting to the production project (Azure DevOps)

- The remote URL is fixed inside each script — replace it.
- `sandbox-gh.sh` becomes `sandbox-az.sh`. The same rules apply: allow-list
  subcommands, always pass the project and repository explicitly rather than
  letting the tool infer them from the working directory, refuse file-reading
  flags, and replace the environment — `az` reads `AZURE_DEVOPS_EXT_PAT` and
  a pile of `AZURE_*` variables from it, and any tool with a `--query`/`--jq`
  style expression language can print whatever is left.
- Keep the rule count at one. Every rule that names a tool directly is a
  promise that no argument of that tool is a program or a path, which took
  three attempts to get wrong here.
- The fetch side ports unchanged: the cache path and the bundle are
  tool-agnostic, and `git bundle` is a git feature, not a GitHub one.
- Azure DevOps PATs cannot be scoped to one repository, which strengthens the
  case for R4 and therefore for this design.
- ccsafetynet complements this but does not replace it: it inspects commands
  the agent itself runs, not what a dependency or an injected instruction
  does, and not non-shell file writes.
