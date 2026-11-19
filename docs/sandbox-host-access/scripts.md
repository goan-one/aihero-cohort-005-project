# The three scripts, and why each is shaped that way

Companion to [design-decisions.md](./design-decisions.md), which records the
constraints and the decision to put a hash-checked loader in front of
everything. This file records what each script behind that loader does about
them, and what was tried and rejected along the way.
[session-log.md](./session-log.md) has the chronology.

## Scope of the implementation

Three scripts behind the loader:

- `sandbox-git-push.sh` — validates branch names against the deny-list, copies
  the branches into a throwaway bare repo, pushes from there to the URL fixed
  in the script, with explicit non-force refspecs.
- `sandbox-git-fetch.sh` — updates a bare mirror in a host-only cache
  directory, then writes the remote's branches into the project as a single
  bundle file for the container to fetch from. See "Why the mirror left the
  project" below.
- `sandbox-gh.sh` — replaces every rule that named `gh`. See below.

### Why the mirror left the project

The first implementation put the bare mirror at `<project>/.git-mirror` and
fetched into it on every run. That is a repository the container can write,
handed to host git once per fetch — H3 again, in a place we built ourselves. A
planted `commondir` was shown to redirect the fetch into another repository on
the host, and the defence was a list: refuse symlinks, refuse `commondir`,
`gitdir` and `objects/info/alternates`, rewrite the config from scratch,
override every config key that can name a program. A list is only as good as
its last entry, and git keeps adding entries.

A read-only mount would have removed the problem and cannot be expressed from a
committed configuration: a project configuration may only mount paths inside
the project (`mount-path-resolution.ts` rejects the rest), the mirror is already
inside the project mount, and shadowing it would need the project's absolute
path, which is per-machine (R3). `"./.git-mirror:ro"` does not even parse into
what it looks like: Sandbox expands a one-sided entry to
`<source>:<source>:ro`, resolves only the source, and leaves the container
target as the relative string, which the runtime rejects.

So the mirror moved out of the project entirely:

- the authoritative bare mirror lives in
  `${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-git-mirrors/<id>/mirror.git`, where
  `<id>` is the first 16 hex digits of `sha256(remote URL + project path)` —
  stable, with no character of either path to escape, and one mirror per
  checkout. The container cannot write there at all;
- the project receives only a **product**: `.git-mirror.bundle`, written to a
  `mktemp` name and `mv -f`-ed into place. The rename replaces whatever stands
  there — a stale bundle, a directory, a symlink to `~/.ssh/id_ed25519` —
  without following it, and nothing on the host ever opens the file again;
- the container reads it with
  `git fetch --prune --no-tags .git-mirror.bundle "+refs/heads/*:refs/remotes/origin/*"`.

Host git now reads nothing the container can write, so the whole list of
refusals went away with it. What is left in the script is the part that is
still load-bearing: unsetting the `GIT_*` variables the host might export, and
refusing a cache directory that is itself inside the project.

Measured before committing to it, on this repository (26 refs, 6,634 objects,
a 2.5 MiB pack):

| What                                           | Number         |
| ---------------------------------------------- | -------------- |
| `git bundle create --branches` of every branch | 1.3 MB, 0.22 s |
| container-side `git fetch` from that bundle    | 6 ms           |
| the same fetch again, nothing new              | 4 ms           |
| `git clone` from the bundle                    | 62 ms          |

And the two questions that would have sunk it, both answered by experiment:
`--branches` produces a bundle with every branch head and no prerequisites, and
the container-side `git fetch --prune` **does** prune a branch that was deleted
on the remote (a bundle advertises its refs like any other transport). A
container-mangled bundle only breaks the container's own fetch.

The cost is that the bundle holds complete history, so every `run fetch`
rewrites all of it. At 1.3 MB that is irrelevant; on a repository where it is
not, the next step is an incremental bundle —
`git bundle create <file> --branches ^<previous tips>`, with the tips
remembered in the cache — which trades the simplicity for a fallback path when
the container's clone does not have the prerequisites. Do not reach for it
before the numbers say so.

### Why `gh` moved behind the loader too

The existing rule `pattern = ["gh", ["issue", "pr"], "*"]` has three problems:

1. `gh` is a **bare name**, resolved through the host's `PATH` from the
   agent-controlled working directory. On macOS and Linux this is only
   exploitable when `PATH` contains a relative entry, an empty entry, or a
   directory inside the project — but that is a property of each developer's
   shell, not of the project.
2. Some `gh` subcommands run host git **in the project**, which is H3.
3. `*` allows any argument, including `--body-file <path>`, which reads an
   arbitrary host file and publishes its contents; and subcommands such as
   `merge`.

4. Everything the host exports is in `gh`'s environment (the broker passes the
   `sandbox` process's own `process.env`), and `--jq` is a jq program, so
   `--jq env` prints it into the container. On a host that authenticates with
   `GH_TOKEN` in a shell profile rather than with `gh auth login`, that is R4
   broken by one argument. No regex on the `--jq` value can fix it: `.|env`
   starts like any legitimate expression.

Behind the loader, the executable is absolute, the working directory is left,
the script allow-lists subcommands, pins `--repo`, refuses file-reading flags,
and replaces the environment with a short fixed list that holds no token.

Point 4 is the one that decides the question, because it is the only one an
argv pattern cannot reach: the leak is not in the flag but in the environment,
and only a script can replace an environment. So **no rule names `gh` any
more.** `gh auth status` and the two Wayfinder `gh api` rules became two more
topics of `sandbox-gh.sh`:

- `auth status`, with no arguments — `--show-token` would print the host's
  token into the container;
- `api`, with the same endpoints the rules allowed, and the same narrowness:
  `GET issues/<n>`, `.../sub_issues`, `.../dependencies/blocked_by`, with
  optional `--jq`/`--paginate`; `POST` to the last two with exactly one
  `-F sub_issue_id=<digits>` or `-F issue_id=<digits>`. The endpoint is
  relative to the repository, which the script prefixes, so `repos/<someone
else>/...` cannot be expressed; every id is checked digit by digit, which is
  also what refuses `-F x=@/etc/passwd`, a `..` segment and a query string.

`--jq` is still allowed. The leak was the environment, and `--jq env` now
prints the short fixed list: `HOME`, `PATH` and a handful of deliberately empty
placeholders. gh's jq cannot read files, so with the environment replaced the
flag is contained.

`.sandbox/config.toml` therefore holds exactly one rule. The general form of
the lesson, written where the rules used to be: if a command takes an argument
that is a program or a path, or if its name is not absolute, it belongs behind
the loader and not in a rule.
