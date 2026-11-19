# Host commands

The container has no credentials and cannot reach the git remote. These four
files give an agent inside [Sandbox](https://github.com/MaibornWolff/sandbox)
exactly three operations on the host: push a work branch, fetch the remote, and
a narrow `gh` for issues and pull requests. They are the _only_ host commands:
`.sandbox/config.toml` holds one rule, and it runs the loader.

| File                   | Runs on       | Does                                                      |
| ---------------------- | ------------- | --------------------------------------------------------- |
| `run`                  | the container | builds the `sandbox escape` invocation for the others     |
| `sandbox-git-push.sh`  | the host      | publishes work branches to the remote                     |
| `sandbox-git-fetch.sh` | the host      | updates the host-only mirror, writes `.git-mirror.bundle` |
| `sandbox-gh.sh`        | the host      | `gh pr`, `gh issue`, `gh api`, `gh auth status`           |

Why it is built this way — the threat model, what was rejected and why — is in
[docs/sandbox-host-access/design-decisions.md](../../docs/sandbox-host-access/design-decisions.md),
and what each script does about it in
[scripts.md](../../docs/sandbox-host-access/scripts.md) beside it.
The short version: a rule in `.sandbox/config.toml` names `/bin/sh` and passes a
fixed loader as `-c` text; the loader copies the named script to a host temp
file, checks the copy's sha256 against the hashes pinned in the rule, and runs
it only on a match. The hash is the control rather than the path, because the
path is an argument the container chooses and rules are compiled once, at
session start. The loader also finds the project root for itself — from its
working directory, not from that argument — and refuses any script that is not
the root's own.

Read the loader in `.sandbox/config.toml` as what it is: a short shell program.
`run loader` prints the copy the container would send.

## Using it

```sh
.sandbox/host-commands/run push fix/devui-switcher-close
.sandbox/host-commands/run push fix/one feature/two
.sandbox/host-commands/run fetch
.sandbox/host-commands/run gh issue view 7 --comments
.sandbox/host-commands/run gh pr create --base main --head fix/foo \
  --title "..." --body "..."
.sandbox/host-commands/run gh api issues/7 --jq .id
.sandbox/host-commands/run gh auth status
```

Each script has a real `--help`: `run push --help`, `run gh --help`.

`run fetch` writes `.git-mirror.bundle` in the project root. Read it with
ordinary git inside the container:

```sh
git fetch --prune --no-tags "$PWD/.git-mirror.bundle" \
  "+refs/heads/*:refs/remotes/origin/*"
```

`--prune` is what makes a branch deleted on the remote disappear from your
`origin/*` refs; the bundle holds the remote's branches and nothing else.

What is refused, and what to do instead:

- **A protected branch** (`main`, `master`, `develop`, `trunk`, `staging`,
  `production`, `release/*`, `hotfix/*`). Push your own branch and open a pull
  request against it.
- **A force push or a deletion.** There is no `--force`, and every refspec is
  `refs/heads/X:refs/heads/X`. A rewritten branch goes under a new name.
- **`gh pr merge`, `gh ... close`, `gh pr review`, `--web`.** A human merges,
  closes and approves. Say what you would do, and why.
- **Anything that reads a host file** (`--body-file <path>`, `-F`, `--template`).
  Use `--body`, or `--body-file -` and pipe the text in.
- **`gh pr checkout` / `gh issue develop`.** They work on a local checkout; use
  ordinary git inside the container.
- **Any `gh api` endpoint other than the Wayfinder ones.** `run gh api` allows
  `issues/<n>`, `issues/<n>/sub_issues` and
  `issues/<n>/dependencies/blocked_by` — a GET of each, and a POST to the last
  two with one `-F sub_issue_id=<number>` or `-F issue_id=<number>`. The
  repository is built into the path by the script, and every id is digits only.

`gh` runs with no local repository and `--repo` pinned, so `pr create` needs
`--head` (and usually `--base`); `--fill` is refused for the same reason.

`gh` also gets a short, fixed environment rather than the host's whole one,
because `--jq env` would otherwise print every variable the host exports into
the container. No token is on that list: authenticate the host with
`gh auth login`, not with `GH_TOKEN` in a shell profile. That leak is why no
rule may name `gh` any more — an argv pattern cannot replace an environment —
and why `gh auth status` and the two Wayfinder `gh api` rules moved in here.

## Changing a script

1. Edit the script.
2. `npm run sandbox:hash` — recomputes the hashes and rewrites the pinned list
   in `.sandbox/config.toml`. `npm run test` fails while a pin is stale.
3. Restart the sandbox. The rule set in force is the one compiled at session
   start, so until then the host refuses the edited script (exit 126).
4. At the trust prompt, **read `git diff .sandbox/`**. That prompt is the
   security boundary for this configuration: an agent can edit both the scripts
   and the hashes, and neither takes effect until a human accepts the diff.

Porting to another remote is one line per script (`REMOTE_URL`, `REPO`).

## Caveats

- **Native Windows is not supported; use WSL.** There is no `/bin/sh`, and
  Windows resolves a command against the current directory first, which makes
  every host-command rule satisfiable by a file the agent placed.
- **Server-side protection is still required.** GitHub rulesets, or Azure DevOps
  branch policies plus _deny force push_, are the real guarantee. These scripts
  are a convenience and a second line of defence.
- **`.git` is shared with the host.** Any git command a human or an IDE runs in
  this checkout uses config and hooks the container can write. These scripts
  never run git inside the project, but `git status` in your own terminal does.
  A separate clone per sandbox (`git clone --reference`, not `git worktree`) is
  the mitigation.
- **Nothing here is protected by a mount.** The scripts stay writable on
  purpose; the hash is what decides. Nothing else inside the project needs
  protecting any more: the mirror lives in
  `${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-git-mirrors`, which the container
  cannot write, and the only thing that lands in the project is
  `.git-mirror.bundle`, which host git writes and never reads. A read-only
  mount was tried first and cannot be had from a committed configuration — see
  the Mounts comment in `.sandbox/config.toml`.
- **A stale `.git-mirror` directory.** If you used an earlier version of these
  scripts, the project still holds the old in-project mirror. Nothing reads it;
  `run fetch` says so, and you can delete it.
- **PATH shadowing.** The loader drops empty, relative and in-project `PATH`
  entries, and puts the host's system directories first, so its own helpers,
  `git` and `gh` always come from outside the project. "In-project" means the
  project root, and the loader finds that root by climbing from the working
  directory — which the broker guarantees is a real directory inside the host
  project — to the topmost ancestor that holds a `.sandbox/config.toml`. The
  script path is not used for it: that path is an argument the container
  chooses, so a pinned script copied deeper in the tree would otherwise name a
  deeper "project" and leave in-project `PATH` entries in place. A stray
  `.sandbox/config.toml` in a directory _above_ the project would make the
  loader refuse every call and say which root it found; Sandbox never puts one
  there (its user configuration lives in `~/.config/sandbox`).
- **Host git parses a repository the container controls** while the push script
  fetches the branch out of the project: `git fetch <project>` starts
  `upload-pack` inside it, which reads its config. The keys that can name a
  program are overridden on the command line, and git ignores the worst of them
  (`uploadpack.packObjectsHook`) when it comes from repository config. Keep host
  git current; this class of bug has had CVEs.
- **The host's environment still reaches the git scripts.** `sandbox-gh.sh`
  replaces it, and the git scripts unset the `GIT_*` variables that would
  redirect git, but a host command is still started with the environment of the
  `sandbox` process. Do not keep secrets in the shell you start `sandbox` from.
- **`--body-file -`, `gh api` and `gh auth status` are unverified against the
  real `gh`.** The argv and the environment they produce are tested with a fake
  `gh`; nobody has run them against GitHub yet. Standard input is forwarded
  over the bridge, so `--body-file -` should work.
