#!/usr/bin/env node
/**
 * shot/runner.mjs
 *
 * Usage: node runner.mjs <plan|execute> <recipe.yaml>
 *
 * Reads a recipe, validates against schema.json, prints a structured plan,
 * and in execution mode performs the safe local parts of a capture run:
 * dependency validation, opening files/apps, and writing an execution report.
 * Deliberate UI manipulation remains manual until the recipe schema grows
 * stable accessibility-targeted actions.
 */
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile, mkdir, stat, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "yaml";
import AjvModule from "ajv";
import addFormatsModule from "ajv-formats";

const Ajv = AjvModule.default ?? AjvModule;
const addFormats = addFormatsModule.default ?? addFormatsModule;

const here = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(here, "../../../../..");
const schema = JSON.parse(await readFile(resolve(here, "schema.json"), "utf8"));
const ajv = new Ajv({ allErrors: true, strict: false, validateSchema: false });
addFormats(ajv);
const validate = ajv.compile(schema);

const [, , cmd, recipePath, ...rest] = process.argv;
if (!cmd || !recipePath) {
  console.error("usage: runner.mjs <plan|execute> <recipe.yaml>");
  process.exit(2);
}

const raw = await readFile(resolve(recipePath), "utf8");
const recipe = yaml.parse(raw);
if (!validate(recipe)) {
  for (const err of validate.errors) console.error(`recipe error: ${err.instancePath} ${err.message}`);
  process.exit(1);
}

if (cmd === "plan") {
  console.log(JSON.stringify(buildPlan(recipe), null, 2));
  process.exit(0);
}
if (cmd === "execute") {
  const options = parseExecuteOptions(rest);
  options.reportPath ??= resolve(here, "artifacts", `${recipe.id}.execution.json`);
  const report = await executeRecipe(recipe, recipePath, options);
  if (options.reportPath) {
    await writeJson(options.reportPath, report);
  }
  console.log(JSON.stringify(report, null, 2));
  process.exit(report.status === "ok" ? 0 : 1);
}
console.error(`unknown command: ${cmd}`);
process.exit(2);

function buildPlan(recipe) {
  return {
    id: recipe.id,
    chapter: recipe.chapter,
    access_request: ["Lungfish"],
    steps: recipe.steps.map((s) => ({
      tool: mapActionToTool(s.action),
      args: { ...s },
    })),
    capture: { retina: recipe.post?.retina ?? true },
    crop: recipe.crop,
    annotations: recipe.annotations ?? [],
  };
}

async function executeRecipe(recipe, recipePath, options) {
  const started = new Date();
  const plan = buildExecutionPlan(recipe);
  const dependencies = await collectDependencies(recipe);
  const report = {
    runner: {
      name: "lungfish-manual-shot",
      version: "0.1.0",
      command: shellCommand(process.argv),
      node: process.version,
      platform: process.platform,
    },
    recipe: {
      id: recipe.id,
      chapter: recipe.chapter,
      path: resolve(process.cwd(), recipePath),
    },
    mode: options.dryRun ? "dry-run" : "execute",
    status: "ok",
    created_at: started.toISOString(),
    completed_at: null,
    duration_ms: null,
    dependencies,
    steps: plan.steps,
    commands: [],
    limitations: [
      "wait_ready, resize_window, and scroll_to are recorded only; this runner does not perform unsafe UI automation.",
      "Screenshots are not captured by execute mode; capture and annotation remain separate manual/post-processing steps.",
    ],
  };

  if (dependencies.missing.length > 0) {
    report.status = "blocked";
    finishReport(report, started);
    console.error(`missing recipe dependencies: ${dependencies.missing.map((item) => item.path).join(", ")}`);
    return report;
  }

  for (const step of plan.steps) {
    if (!step.command) continue;
    const commandReport = {
      step_index: step.index,
      kind: step.action,
      argv: step.command,
      status: options.dryRun ? "dry-run" : "pending",
      exit_status: null,
      stderr: "",
      stdout: "",
    };
    if (!options.dryRun) {
      const result = spawnSync(step.command[0], step.command.slice(1), { encoding: "utf8" });
      commandReport.exit_status = result.status;
      commandReport.stderr = result.stderr ?? "";
      commandReport.stdout = result.stdout ?? "";
      commandReport.status = result.status === 0 ? "ok" : "failed";
      if (result.error) {
        commandReport.status = "failed";
        commandReport.stderr = result.error.message;
      }
      if (commandReport.status === "failed") {
        report.status = "failed";
        report.commands.push(commandReport);
        break;
      }
    }
    report.commands.push(commandReport);
  }

  finishReport(report, started);
  return report;
}

function finishReport(report, started) {
  const completed = new Date();
  report.completed_at = completed.toISOString();
  report.duration_ms = completed.getTime() - started.getTime();
}

function parseExecuteOptions(args) {
  const options = { dryRun: false, reportPath: null };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--dry-run") {
      options.dryRun = true;
    } else if (arg === "--report") {
      const reportPath = args[index + 1];
      if (!reportPath) throw new Error("--report requires a path");
      options.reportPath = resolve(process.cwd(), reportPath);
      index += 1;
    } else {
      throw new Error(`unknown execute option: ${arg}`);
    }
  }
  return options;
}

function buildExecutionPlan(recipe) {
  let activeApp = null;
  const fixture = resolveFixture(recipe.app_state.fixture);
  const steps = recipe.steps.map((step, index) => {
    const resolved = { ...step, index };
    if (step.path) resolved.path = resolveRecipePath(interpolate(step.path, fixture));
    let command = null;
    if (step.action === "open_application") {
      if (!step.app) throw new Error(`step ${index} open_application requires app`);
      activeApp = step.app;
      command = ["open", "-a", step.app];
    } else if (step.action === "open_file") {
      if (!resolved.path) throw new Error(`step ${index} open_file requires path`);
      command = activeApp ? ["open", "-a", activeApp, resolved.path] : ["open", resolved.path];
    }
    return {
      index,
      action: step.action,
      args: resolved,
      command,
      note: command ? undefined : "recorded only",
    };
  });
  return { steps };
}

async function collectDependencies(recipe) {
  const fixture = resolveFixture(recipe.app_state.fixture);
  const candidates = [{ role: "fixture", path: fixture }];
  for (const entry of recipe.app_state.open_files ?? []) {
    for (const [role, path] of Object.entries(entry)) {
      candidates.push({ role, path: resolveRecipePath(interpolate(path, fixture)) });
    }
  }
  for (const step of recipe.steps) {
    if (step.action === "open_file" && step.path) {
      candidates.push({ role: "step.open_file", path: resolveRecipePath(interpolate(step.path, fixture)) });
    }
  }

  const present = [];
  const missing = [];
  for (const candidate of dedupeByPath(candidates)) {
    if (!existsSync(candidate.path)) {
      missing.push(candidate);
      continue;
    }
    const info = await stat(candidate.path);
    present.push({
      ...candidate,
      type: info.isDirectory() ? "directory" : "file",
      size: info.size,
      sha256: info.isFile() ? await sha256(candidate.path) : null,
    });
  }
  return { present, missing };
}

function dedupeByPath(candidates) {
  const seen = new Map();
  for (const candidate of candidates) {
    const existing = seen.get(candidate.path);
    if (existing) {
      existing.role = `${existing.role},${candidate.role}`;
    } else {
      seen.set(candidate.path, { ...candidate });
    }
  }
  return [...seen.values()];
}

function resolveFixture(fixture) {
  return resolveRecipePath(fixture);
}

function resolveRecipePath(path) {
  if (path.startsWith("/")) return path;
  return resolve(workspaceRoot, path);
}

function interpolate(value, fixture) {
  return value.replaceAll("{fixture}", fixture);
}

async function sha256(path) {
  const bytes = await readFile(path);
  return createHash("sha256").update(bytes).digest("hex");
}

async function writeJson(path, data) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(data, null, 2)}\n`);
}

function shellCommand(argv) {
  return argv.map((arg) => (arg.includes(" ") ? JSON.stringify(arg) : arg)).join(" ");
}

function mapActionToTool(action) {
  switch (action) {
    case "open_application": return "mcp__computer-use__open_application";
    case "wait_ready": return "internal:wait";
    case "open_file": return "bash:open -a";
    case "resize_window": return "mcp__computer-use__computer_batch";
    case "scroll_to": return "mcp__computer-use__scroll";
    default: throw new Error(`unknown action: ${action}`);
  }
}
