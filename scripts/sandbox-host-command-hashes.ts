import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// `npm run sandbox:hash`. The host-command rule in .sandbox/config.toml runs a
// script on the host only when its sha256 is one of the hashes pinned in the
// rule, so every edit to a script needs the pinned list updating. Keeping the
// list in the configuration (and not in a file beside the scripts) is what
// makes the check meaningful: rules are compiled once, at session start, and
// .sandbox/ is covered by the trust prompt, so a hash the agent changes only
// takes effect after a restart and a human look at `git diff .sandbox/`.
//
// Node built-ins only, on purpose: this has to keep working when node_modules
// is in any state.

const BEGIN_MARKER = "# BEGIN sandbox:hash";
const END_MARKER = "# END sandbox:hash";

const configUrl = new URL("../.sandbox/config.toml", import.meta.url);
const scriptsUrl = new URL("../.sandbox/host-commands/", import.meta.url);

export type ScriptHash = {
  readonly name: string;
  readonly sha256: string;
};

export function readConfig(): string {
  return readFileSync(configUrl, "utf8");
}

export function scriptHashes(): ScriptHash[] {
  return readdirSync(scriptsUrl)
    .filter((name) => name.endsWith(".sh"))
    .sort()
    .map((name) => ({
      name,
      sha256: createHash("sha256")
        .update(readFileSync(new URL(name, scriptsUrl)))
        .digest("hex"),
    }));
}

// Every line of the block has to be one pinned hash with the name of the
// script it belongs to. A line this does not recognise is an error rather
// than something to skip: a bare `"<sha256>",` in the block would be a live
// fourth alternative in the rule — the host would run a script with that
// content — while a parser that only collects what it recognises would
// compare the rest, find it correct, and report nothing.
export function pinnedHashes(config: string): ScriptHash[] {
  const lines = blockLines(config).filter((line) => line.trim() !== "");
  const open = lines.shift()?.trim();
  const close = lines.pop()?.trim();
  if (open !== "[" || close !== "],") {
    throw new Error(
      "the sandbox:hash block in .sandbox/config.toml is not one TOML " +
        "array of hashes. Run `npm run sandbox:hash` to rewrite it."
    );
  }
  return lines.map((line) => {
    const match = /^ {4}"([0-9a-f]{64})", # (\S+)$/.exec(line);
    if (!match) {
      throw new Error(
        `unexpected line in the sandbox:hash block of .sandbox/config.toml: ${line.trim()}\n` +
          "Every line has to be one pinned sha256 followed by the name of " +
          "its script, as `npm run sandbox:hash` writes it."
      );
    }
    return { name: match[2], sha256: match[1] };
  });
}

export function withPinnedHashes(
  config: string,
  hashes: readonly ScriptHash[]
): string {
  const lines = config.split("\n");
  const { begin, end } = blockBounds(lines);
  const block = [
    "  [",
    ...hashes.map(({ name, sha256 }) => `    "${sha256}", # ${name}`),
    "  ],",
  ];
  return [...lines.slice(0, begin + 1), ...block, ...lines.slice(end)].join(
    "\n"
  );
}

// The loader program the rule runs on the host: the one TOML multi-line
// literal string in the configuration. A newline straight after the opening
// delimiter is not part of the value. `.sandbox/host-commands/run` reads the
// same text out of the same file at run time, with `sed`, because the broker
// compares the text it receives byte for byte with the rule it compiled when
// the session started.
export function loaderText(config: string): string {
  const parts = config.split("'''");
  if (parts.length !== 3) {
    throw new Error(
      "expected exactly one ''' string in .sandbox/config.toml (the loader), " +
        `found ${Math.max(0, parts.length - 1)} delimiters. ` +
        "Keep ''' out of the comments."
    );
  }
  return parts[1].replace(/^\r?\n/, "");
}

// The path matcher of the loader rule: the one regex matcher that constrains a
// path under .sandbox/host-commands.
export function pathMatcher(config: string): string {
  const match = /\{ regex = '([^']*host-commands[^']*)' \}/.exec(config);
  if (!match) throw new Error("no host-commands path matcher in config.toml");
  return match[1];
}

function blockBounds(lines: readonly string[]) {
  const begin = lines.findIndex((line) => line.includes(BEGIN_MARKER));
  const end = lines.findIndex((line) => line.includes(END_MARKER));
  if (begin === -1 || end === -1 || end <= begin) {
    throw new Error(
      `${BEGIN_MARKER} / ${END_MARKER} not found in .sandbox/config.toml`
    );
  }
  return { begin, end };
}

function blockLines(config: string): string[] {
  const lines = config.split("\n");
  const { begin, end } = blockBounds(lines);
  return lines.slice(begin + 1, end);
}

function main(): void {
  const config = readConfig();
  const hashes = scriptHashes();
  const updated = withPinnedHashes(config, hashes);
  for (const { name, sha256 } of hashes) {
    console.log(`${sha256}  ${name}`);
  }
  if (updated === config) {
    console.log("\n.sandbox/config.toml is already up to date.");
    return;
  }
  writeFileSync(configUrl, updated);
  console.log(
    "\nUpdated .sandbox/config.toml. Restart the sandbox for it to take " +
      "effect, and review `git diff .sandbox/` at the trust prompt."
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
