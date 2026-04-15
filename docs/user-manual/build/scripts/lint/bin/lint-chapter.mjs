#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { remark } from "remark";
import { reporter } from "vfile-reporter";
import config from "../.remarkrc.mjs";

const [, , ...args] = process.argv;
if (args.length === 0) {
  console.error("usage: lint-chapter <path-to-chapter.md> [...]");
  process.exit(2);
}

let hadFailure = false;
for (const arg of args) {
  const path = resolve(arg);
  const source = await readFile(path, "utf8");
  const processor = remark();
  for (const plugin of config.plugins) {
    const [p, ...opts] = Array.isArray(plugin) ? plugin : [plugin];
    processor.use(p, ...opts);
  }
  const file = await processor.process({ path, value: source });
  process.stdout.write(reporter(file));
  if (file.messages.some((m) => m.fatal !== false)) hadFailure = true;
}
process.exit(hadFailure ? 1 : 0);
