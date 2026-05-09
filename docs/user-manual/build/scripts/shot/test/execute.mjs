import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const runner = resolve(root, "runner.mjs");

test("plan emits mapped tool steps", () => {
  const recipePath = resolve(here, "fixtures", "valid-recipe.yaml");
  const result = spawnSync(process.execPath, [
    runner,
    "plan",
    recipePath,
  ], { cwd: root, encoding: "utf8" });

  assert.equal(result.status, 0, result.stderr);
  const plan = JSON.parse(result.stdout);
  assert.equal(plan.id, "example");
  assert.deepEqual(plan.access_request, ["Lungfish"]);
  assert.equal(plan.steps[0].tool, "mcp__computer-use__open_application");
});

test("execute validates dependencies and writes dry-run report", async () => {
  const temp = await mkdtemp(resolve(tmpdir(), "shot-execute-"));
  try {
    const fixture = resolve(here, "fixtures");
    const recipePath = resolve(temp, "recipe.yaml");
    const reportPath = resolve(temp, "report.json");

    await writeFile(recipePath, `
id: execute-example
chapter: 99-test/example
caption: "Example execution."
viewport_class: variant
app_state:
  fixture: ${JSON.stringify(fixture)}
  open_files:
    - image: "{fixture}/solid.png"
  window_size: [800, 600]
  appearance: light
steps:
  - action: open_application
    app: Lungfish
  - action: open_file
    path: "{fixture}/solid.png"
  - action: wait_ready
    signal: variant_browser_loaded
  - action: resize_window
    size: [800, 600]
  - action: scroll_to
    target: first_variant
crop:
  mode: viewport
post:
  retina: true
  format: png
`);

    const result = spawnSync(process.execPath, [
      runner,
      "execute",
      recipePath,
      "--dry-run",
      "--report",
      reportPath,
    ], { cwd: root, encoding: "utf8" });

    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(await readFile(reportPath, "utf8"));
    assert.equal(report.recipe.id, "execute-example");
    assert.equal(report.mode, "dry-run");
    assert.equal(report.status, "ok");
    assert.equal(report.dependencies.missing.length, 0);
    assert.equal(report.dependencies.present.length, 2);
    assert.equal(report.commands.length, 2);
    assert.deepEqual(report.commands.map((command) => command.kind), ["open_application", "open_file"]);
    assert.equal(report.steps.length, 5);
    assert.ok(report.created_at);
    assert.ok(report.completed_at);
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
});

test("execute fails before opening files when a dependency is missing", async () => {
  const temp = await mkdtemp(resolve(tmpdir(), "shot-execute-missing-"));
  try {
    const fixture = resolve(here, "fixtures");
    const recipePath = resolve(temp, "missing.yaml");
    const reportPath = resolve(temp, "missing-report.json");

    await writeFile(recipePath, `
id: missing-example
chapter: 99-test/example
caption: "Missing dependency."
viewport_class: variant
app_state:
  fixture: ${JSON.stringify(fixture)}
  open_files:
    - image: "{fixture}/does-not-exist.png"
  window_size: [800, 600]
steps:
  - action: open_file
    path: "{fixture}/does-not-exist.png"
crop:
  mode: viewport
post:
  retina: true
  format: png
`);

    const result = spawnSync(process.execPath, [
      runner,
      "execute",
      recipePath,
      "--dry-run",
      "--report",
      reportPath,
    ], { cwd: root, encoding: "utf8" });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /missing recipe dependencies/);
    const report = JSON.parse(await readFile(reportPath, "utf8"));
    assert.equal(report.status, "blocked");
    assert.equal(report.dependencies.missing.length, 1);
    assert.equal(report.commands.length, 0);
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
});
