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

test("palette flags non-palette hex in prose and SVG", async () => {
  const messages = await lint("bad-palette.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /#FF0000/);
  assert.match(reasons, /#336699/);
  // #00FF00 inside backticks (inlineCode) is not a style reference — must NOT flag
  assert.doesNotMatch(reasons, /#00FF00/);
});

test("typography flags non-brand fonts in HTML", async () => {
  const messages = await lint("bad-typography.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /Helvetica Neue/);
  assert.match(reasons, /Times New Roman/);
});

test("voice flags marketing patterns and sentence-terminal '!'", async () => {
  const messages = await lint("bad-voice.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  for (const word of ["revolutionary", "breakthrough", "AI-powered", "leverages", "unleash", "cutting-edge"]) {
    assert.match(reasons, new RegExp(word, "i"));
  }
  assert.match(reasons, /sentence-terminal '!'/);
});
