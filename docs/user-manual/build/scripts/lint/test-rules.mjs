import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { remark } from "remark";
import config from "./.remarkrc.mjs";

const here = dirname(fileURLToPath(import.meta.url));

async function lint(relPath) {
  const path = resolve(here, "fixtures", relPath);
  const source = await readFile(path, "utf8");
  const processor = remark();
  for (const plugin of config.plugins) {
    const [p, ...opts] = Array.isArray(plugin) ? plugin : [plugin];
    processor.use(p, ...opts);
  }
  const file = await processor.process({ path, value: source });
  return file.messages;
}

test("known-good chapter produces no messages", async () => {
  const messages = await lint("passing.md");
  assert.deepEqual(messages.map((m) => m.reason), []);
});

test("written-identity flags every wrong spelling", async () => {
  const messages = await lint("bad-written-identity.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /LUNGFISH/);
  assert.match(reasons, /LungFish/);
  assert.match(reasons, /Lung Fish/);
  assert.match(reasons, /lowercase 'lungfish'/);
});
