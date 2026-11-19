import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  loaderText,
  pathMatcher,
  pinnedHashes,
  readConfig,
  scriptHashes,
} from "./sandbox-host-command-hashes";

// The host-command rule in .sandbox/config.toml runs a script on the host only
// if its sha256 is pinned in the rule. A stale pin means the script is refused
// at the next session, with an error that reads like a security incident. This
// test is the reminder: edit a script, run `npm run sandbox:hash`.

const projectFile = (relative: string) =>
  fileURLToPath(new URL(`../${relative}`, import.meta.url));

describe("host-command hashes", () => {
  it("pins the current sha256 of every host-command script", () => {
    expect(pinnedHashes(readConfig())).toEqual(scriptHashes());
  });

  it("refuses a hash in the block that names no script", () => {
    const config = readConfig().replace(
      /^ {4}"([0-9a-f]{64})", # (\S+)$/m,
      '    "$1",\n    "$1", # $2'
    );
    expect(() => pinnedHashes(config)).toThrowError(/unexpected line/);
  });
});

describe("host-command path matcher", () => {
  const expression = new RegExp(`^(?:${pathMatcher(readConfig())})$`, "u");

  it("matches each script at its real absolute path", () => {
    const paths = scriptHashes().map(({ name }) =>
      projectFile(`.sandbox/host-commands/${name}`)
    );
    expect(paths.filter((path) => !expression.test(path))).toEqual([]);
  });

  it("rejects a look-alike that is not one of these scripts", () => {
    const lookAlikes = [
      "/tmp/evil/sandbox-gh.sh",
      "/project/.sandbox/host-commands/evil.sh",
      "/project/.sandbox/host-commands/sandbox-gh.sh.bak",
      "/project/sandbox-gh.sh",
      "relative/.sandbox/host-commands/sandbox-gh.sh",
    ];
    expect(lookAlikes.filter((path) => expression.test(path))).toEqual([]);
  });
});

// The loader is a shell program written inside a TOML string, and
// .sandbox/host-commands/run has to send the host exactly that text: the
// broker compares it with the rule it compiled at session start and refuses
// anything else. Both halves of that are checked here, because neither shows
// up as a type error or as a failing push — only as "command is not allowed"
// in front of whoever edits this configuration next.
describe("host-command loader", () => {
  const loader = loaderText(readConfig());

  it("is a syntactically valid POSIX shell program", () => {
    expect(() =>
      execFileSync("sh", ["-n"], { input: loader, stdio: "pipe" })
    ).not.toThrow();
  });

  it("is the text that .sandbox/host-commands/run sends to the host", () => {
    const sent = execFileSync(
      "sh",
      [projectFile(".sandbox/host-commands/run"), "loader"],
      { encoding: "utf8" }
    );
    expect(sent).toBe(loader);
  });
});
