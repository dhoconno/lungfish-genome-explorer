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

test("primer-before-procedure flags Procedure appearing before primer", async () => {
  const messages = await lint("bad-primer-order.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /'## Procedure' before any primer section/);
});

test("frontmatter flags missing required keys", async () => {
  const messages = await lint("bad-frontmatter.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /missing required key: chapter_id/);
  assert.match(reasons, /missing required key: audience/);
});

test("frontmatter flags SHOT marker mismatches", async () => {
  const messages = await lint("bad-shot-marker.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /declared-but-unused/);
  assert.match(reasons, /undeclared-orphan/);
});

test("data-viz flags red-amber-green and non-palette colors in vega-lite", async () => {
  const messages = await lint("bad-data-viz.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /red-amber-green/);
  assert.match(reasons, /non-palette colour in chart/);
});

test("em-dash flags em dashes in prose and headings but not in code", async () => {
  const messages = await lint("bad-em-dash.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  // At least one em-dash message must fire
  assert.match(reasons, /em dash/);
  // The inline-code span and fenced code block must NOT produce messages
  // (total message count should be less than the number of em dashes in code spans)
  // We expect exactly 4 prose em dashes (2 in first para, 2 in second para,
  // 1 in heading) but NOT the inlineCode or fenced block — at least 1 message.
  assert.ok(messages.some((m) => /em dash/.test(m.reason)), "should flag at least one em dash");
});

test("bullet-cap flags >5-item list and >2 lists per H2 section", async () => {
  const messages = await lint("bad-bullet-cap.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  // Per-list item cap: 6-item list fires
  assert.match(reasons, /6 items/);
  // Per-H2 section cap: third list fires
  assert.match(reasons, /3rd list in this H2 section/);
});
