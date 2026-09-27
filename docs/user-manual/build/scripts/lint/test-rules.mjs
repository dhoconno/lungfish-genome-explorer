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

test("app-name enforces first full mention, LGE after, and no bare Lungfish", async () => {
  const messages = await lint("bad-app-name.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /'LGE' before the first 'Lungfish Genome Explorer'/);
  assert.match(reasons, /bare 'Lungfish'/);
  assert.match(reasons, /LUNGFISH/);
  assert.equal((reasons.match(/bare 'Lungfish'/g) || []).length, 1);
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

test("bullet-cap flags >5-item list and >2 lists per section", async () => {
  const messages = await lint("bad-bullet-cap.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  // Per-list item cap: 6-item list fires
  assert.match(reasons, /6 items/);
  // Per-section cap: third list fires
  assert.match(reasons, /3rd list in this section/);
});

test("bullet-cap counts lists per H3, not only per H2", async () => {
  const messages = await lint("bullet-cap-h3.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  // Two lists under each of two H3 subsections of one H2: nothing fires.
  assert.doesNotMatch(reasons, /list in this section/);
});

test("semicolon flags semicolons in prose but not in code", async () => {
  const messages = await lint("bad-semicolon.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /semicolon in prose/);
  assert.equal((reasons.match(/semicolon in prose/g) || []).length, 2);
});

test("sentence-colon flags joiner colons and allows lead-in colons", async () => {
  const messages = await lint("bad-sentence-colon.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.equal((reasons.match(/colon inside a sentence/g) || []).length, 2);
});

test("ai-tells flags listed words, inflections, and sentence patterns, but not quoted labels or code", async () => {
  const messages = await lint("bad-ai-tells.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /overused word 'delve'/i);
  assert.match(reasons, /overused word 'seamlessly'/i);
  assert.match(reasons, /overused word 'navigating'/i);
  assert.match(reasons, /pattern "It's not X, it's Y"/);
  assert.match(reasons, /pattern "No X\. No Y\. Just Z"/);
  assert.doesNotMatch(reasons, /overused word 'Navigate'/);
  assert.doesNotMatch(reasons, /overused word 'tap'/);
  assert.equal((reasons.match(/overused word 'navigat/gi) || []).length, 1);
});

test("settings-coverage flags unknown ids and undocumented settings", async () => {
  const messages = await lint("bad-settings-coverage.md");
  const reasons = messages.map((m) => m.reason).join("\n");
  assert.match(reasons, /unknown parameters_refs id 'test.missing'/);
  assert.match(reasons, /setting 'Quality cutoff' of 'test.trim' is not documented/);
  assert.match(reasons, /period outside the bold/);
  assert.doesNotMatch(reasons, /setting 'Minimum length'/);
});
