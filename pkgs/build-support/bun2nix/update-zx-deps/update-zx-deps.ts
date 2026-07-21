#!/usr/bin/env bun
//
// update-zx-deps — Resolve SRI hashes for ///!dep directives in zx scripts.
//
// Usage:
//   bun scripts/update-zx-deps.ts <script.ts>
//   bun scripts/update-zx-deps.ts --check <script.ts>
//
// Each ///!dep line is expected to have the form:
//   ///!dep <name@version> [sri-hash]
//
// The tool fetches each package's tarball from the npm registry, computes
// the sha512 SRI hash, and rewrites the directive in-place. In --check mode,
// it exits 1 if any hashes are missing or incorrect.

import { parseArgs } from "node:util";
import { readFileSync, writeFileSync } from "node:fs";

const DIRECTIVE_RE = /^(\/\/\/!dep\s+)(\S+)(\s*)(.*)/;

interface DepDirective {
  lineIndex: number;
  prefix: string;
  key: string;
  existingHash: string;
}

function parseTarballUrl(key: string): string {
  const atIdx = key.lastIndexOf("@");
  if (atIdx <= 0) throw new Error(`Invalid dep key (no version): ${key}`);
  const name = key.slice(0, atIdx);
  const version = key.slice(atIdx + 1);
  const bareName = name.startsWith("@") ? name.split("/")[1] : name;
  return `https://registry.npmjs.org/${name}/-/${bareName}-${version}.tgz`;
}

async function computeSriHash(url: string): Promise<string> {
  const resp = await fetch(url);
  if (!resp.ok)
    throw new Error(
      `Failed to fetch ${url}: ${resp.status} ${resp.statusText}`,
    );
  const buf = await resp.arrayBuffer();
  const hashBuf = await crypto.subtle.digest("SHA-512", buf);
  return `sha512-${Buffer.from(hashBuf).toString("base64")}`;
}

function parseDirectives(lines: string[]): DepDirective[] {
  const directives: DepDirective[] = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(DIRECTIVE_RE);
    if (m) {
      directives.push({
        lineIndex: i,
        prefix: m[1],
        key: m[2],
        existingHash: m[4] || "",
      });
    }
  }
  return directives;
}

async function main() {
  const { values, positionals } = parseArgs({
    args: Bun.argv.slice(2),
    options: {
      check: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
    allowPositionals: true,
  });

  if (values.help || positionals.length === 0) {
    console.log(`Usage: bun scripts/update-zx-deps.ts [--check] <script.ts>

Resolve SRI hashes for ///!dep directives.

Options:
  --check   Exit 1 if any hashes are missing or would change (for CI)
  -h, --help  Show this help`);
    process.exit(positionals.length === 0 && !values.help ? 1 : 0);
  }

  const scriptPath = positionals[0];
  const content = readFileSync(scriptPath, "utf-8");
  const lines = content.split("\n");
  const directives = parseDirectives(lines);

  if (directives.length === 0) {
    console.log(`No ///!dep directives found in ${scriptPath}`);
    process.exit(0);
  }

  console.log(`Found ${directives.length} dep directive(s) in ${scriptPath}`);

  const results = await Promise.all(
    directives.map(async (d) => {
      const url = parseTarballUrl(d.key);
      const hash = await computeSriHash(url);
      return { ...d, computedHash: hash, url };
    }),
  );

  let changed = 0;
  for (const r of results) {
    if (r.existingHash === r.computedHash) {
      console.log(`  ${r.key} — up to date`);
    } else if (r.existingHash === "") {
      console.log(`  ${r.key} — added hash`);
      changed++;
    } else {
      console.log(`  ${r.key} — hash changed`);
      changed++;
    }
    lines[r.lineIndex] = `${r.prefix}${r.key} ${r.computedHash}`;
  }

  if (changed === 0) {
    console.log("All hashes up to date.");
    process.exit(0);
  }

  if (values.check) {
    console.log(
      `\n${changed} hash(es) need updating. Run without --check to fix.`,
    );
    process.exit(1);
  }

  writeFileSync(scriptPath, lines.join("\n"), "utf-8");
  console.log(`\nUpdated ${changed} hash(es) in ${scriptPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
