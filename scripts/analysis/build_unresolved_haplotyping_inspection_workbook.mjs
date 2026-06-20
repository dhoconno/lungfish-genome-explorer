import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const [, , bundlePath, revisionID, outputPath] = process.argv;
if (!bundlePath || !revisionID || !outputPath) {
  throw new Error("Usage: node build_unresolved_haplotyping_inspection_workbook.mjs <bundle> <revision-id> <output.xlsx>");
}

const revisionDir = path.join(bundlePath, "artifacts", "ai-haplotyping", "revisions", revisionID);
const callsPath = path.join(revisionDir, "calls.json");
const analysisPath = path.join(revisionDir, "haplotype-analysis.json");
const provenanceInputPath = path.join(revisionDir, "ai-haplotyping.lungfish-provenance.json");

const [callsRaw, analysisRaw] = await Promise.all([
  fs.readFile(callsPath, "utf8"),
  fs.readFile(analysisPath, "utf8"),
]);
const calls = JSON.parse(callsRaw);
const analysis = JSON.parse(analysisRaw);

const unresolvedCalls = calls
  .filter((call) => call.status !== "called")
  .sort((a, b) => `${a.sample}\t${a.locus}\t${a.slot}`.localeCompare(`${b.sample}\t${b.locus}\t${b.slot}`));
const unresolvedSamples = new Set(unresolvedCalls.map((call) => call.sample));
const sampleCalls = calls
  .filter((call) => unresolvedSamples.has(call.sample))
  .sort((a, b) => `${a.sample}\t${a.locus}\t${a.slot}`.localeCompare(`${b.sample}\t${b.locus}\t${b.slot}`));

const statusCounts = new Map();
const locusCounts = new Map();
for (const call of unresolvedCalls) {
  statusCounts.set(call.status, (statusCounts.get(call.status) ?? 0) + 1);
  const key = `${call.locus}|${call.status}`;
  locusCounts.set(key, (locusCounts.get(key) ?? 0) + 1);
}

function text(value) {
  if (value === undefined || value === null) return "";
  if (Array.isArray(value)) return value.join("; ");
  return String(value);
}

function ai(call, key) {
  return call.aiMetadata?.[key] ?? "";
}

function hashFile(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function setTitle(sheet, title, subtitle, widthCols) {
  const endCol = String.fromCharCode("A".charCodeAt(0) + Math.max(widthCols - 1, 1));
  const titleRange = sheet.getRange(`A1:${endCol}1`);
  titleRange.merge();
  titleRange.values = [[title]];
  titleRange.format.font = { bold: true, size: 16, color: "#1F2937" };
  titleRange.format.fill = { color: "#EAF2F8" };
  const subtitleRange = sheet.getRange(`A2:${endCol}2`);
  subtitleRange.merge();
  subtitleRange.values = [[subtitle]];
  subtitleRange.format.font = { size: 10, color: "#4B5563" };
  subtitleRange.format.fill = { color: "#F8FAFC" };
}

function writeHeader(sheet, row, headers) {
  const range = sheet.getRangeByIndexes(row - 1, 0, 1, headers.length);
  range.values = [headers];
  range.format.font = { bold: true, color: "#FFFFFF" };
  range.format.fill = { color: "#315A8C" };
  range.format.borders = { preset: "all", style: "thin", color: "#D0D7DE" };
  range.format.wrapText = true;
}

function writeRows(sheet, startRow, rows, columnCount) {
  if (rows.length === 0) return;
  const range = sheet.getRangeByIndexes(startRow - 1, 0, rows.length, columnCount);
  range.values = rows;
  range.format.borders = { preset: "all", style: "thin", color: "#E5E7EB" };
  range.format.wrapText = true;
}

function colorStatusRange(sheet, startRow, rowCount, statusColumnIndex) {
  for (let index = 0; index < rowCount; index += 1) {
    const row = startRow + index;
    const status = sheet.getCell(row - 1, statusColumnIndex).values?.[0]?.[0];
    const range = sheet.getRangeByIndexes(row - 1, 0, 1, 12);
    if (status === "noHaplotype") {
      range.format.fill = { color: "#FFF7D6" };
    } else if (status === "notAssayed") {
      range.format.fill = { color: "#F3F4F6" };
    } else {
      range.format.fill = { color: "#FEE2E2" };
    }
  }
}

const workbook = Workbook.create();

const summary = workbook.worksheets.add("Summary");
setTitle(
  summary,
  "Hybrid AI Haplotyping - Unresolved Samples",
  `Bundle: ${bundlePath} | Revision: ${revisionID}`,
  8,
);
writeHeader(summary, 4, ["Metric", "Value"]);
const summaryRows = [
  ["AI revision", revisionID],
  ["Review state", text(analysis.reviewState ?? analysis.source)],
  ["Total AI-reviewed slots", calls.length],
  ["Called slots", calls.filter((call) => call.status === "called").length],
  ["Unresolved/non-called slots", unresolvedCalls.length],
  ["Samples with unresolved/non-called slots", unresolvedSamples.size],
  ["Generated workbook", new Date().toISOString()],
];
writeRows(summary, 5, summaryRows, 2);

writeHeader(summary, 14, ["Status", "Slots"]);
writeRows(
  summary,
  15,
  [...statusCounts.entries()].sort((a, b) => a[0].localeCompare(b[0])),
  2,
);

writeHeader(summary, 22, ["Locus", "Status", "Slots"]);
writeRows(
  summary,
  23,
  [...locusCounts.entries()]
    .map(([key, count]) => {
      const [locus, status] = key.split("|");
      return [locus, status, count];
    })
    .sort((a, b) => `${a[0]}\t${a[1]}`.localeCompare(`${b[0]}\t${b[1]}`)),
  3,
);
summary.getRange("A:A").format.columnWidthPx = 180;
summary.getRange("B:B").format.columnWidthPx = 640;
summary.getRange("C:C").format.columnWidthPx = 90;
summary.freezePanes.freezeRows(4);

const matrix = workbook.worksheets.add("Unresolved Sample Matrix");
setTitle(matrix, "Samples With Any Unresolved AI Haplotyping Slot", "All AI-reviewed slots for only samples that still need manual inspection.", 8);
const matrixHeaders = ["Sample", "Locus", "Slot", "Status", "Proposed haplotype", "Confidence", "Review state", "Rationale code"];
writeHeader(matrix, 4, matrixHeaders);
writeRows(
  matrix,
  5,
  sampleCalls.map((call) => [
    call.sample,
    call.locus,
    call.slot,
    call.status,
    text(call.proposedHaplotypeLabel),
    text(ai(call, "confidenceTier")),
    text(ai(call, "reviewState")),
    text(ai(call, "rationaleCode")),
  ]),
  matrixHeaders.length,
);
colorStatusRange(matrix, 5, sampleCalls.length, 3);
matrix.freezePanes.freezeRows(4);
matrix.getRange("A:A").format.columnWidthPx = 90;
matrix.getRange("B:D").format.columnWidthPx = 90;
matrix.getRange("E:E").format.columnWidthPx = 160;
matrix.getRange("F:H").format.columnWidthPx = 120;

const detail = workbook.worksheets.add("Unresolved AI Review");
setTitle(detail, "Unresolved AI Review Detail", "One row per non-called AI slot, with rationale and cited evidence refs.", 12);
const detailHeaders = [
  "Sample",
  "Locus",
  "Slot",
  "Status",
  "Proposed haplotype",
  "Alternates",
  "Confidence",
  "Review state",
  "Rationale code",
  "Rationale",
  "Support evidence refs",
  "Counterevidence refs",
];
writeHeader(detail, 4, detailHeaders);
writeRows(
  detail,
  5,
  unresolvedCalls.map((call) => [
    call.sample,
    call.locus,
    call.slot,
    call.status,
    text(call.proposedHaplotypeLabel),
    text(ai(call, "alternates")),
    text(ai(call, "confidenceTier")),
    text(ai(call, "reviewState")),
    text(ai(call, "rationaleCode")),
    text(ai(call, "rationale")),
    text(call.supportEvidenceRefs),
    text(call.counterevidenceRefs),
  ]),
  detailHeaders.length,
);
colorStatusRange(detail, 5, unresolvedCalls.length, 3);
detail.freezePanes.freezeRows(4);
[
  90, 90, 70, 110, 170, 170, 100, 120, 130, 620, 620, 360,
].forEach((width, index) => {
  detail.getRangeByIndexes(0, index, Math.max(unresolvedCalls.length + 4, 5), 1).format.columnWidthPx = width;
});

const source = workbook.worksheets.add("Source Files");
setTitle(source, "Source Files And Checksums", "Inputs used to build this unresolved-sample inspection workbook.", 5);
writeHeader(source, 4, ["Role", "Path", "Size bytes", "SHA256", "Exists"]);
const sourceFiles = [
  ["bundle manifest", path.join(bundlePath, "genotype-result.json")],
  ["AI calls", callsPath],
  ["AI analysis", analysisPath],
  ["AI provenance", provenanceInputPath],
];
const sourceRows = [];
for (const [role, filePath] of sourceFiles) {
  try {
    const bytes = await fs.readFile(filePath);
    sourceRows.push([role, filePath, bytes.length, hashFile(bytes), true]);
  } catch {
    sourceRows.push([role, filePath, "", "", false]);
  }
}
writeRows(source, 5, sourceRows, 5);
source.freezePanes.freezeRows(4);
source.getRange("A:A").format.columnWidthPx = 150;
source.getRange("B:B").format.columnWidthPx = 720;
source.getRange("C:C").format.columnWidthPx = 100;
source.getRange("D:D").format.columnWidthPx = 460;
source.getRange("E:E").format.columnWidthPx = 80;

await fs.mkdir(path.dirname(outputPath), { recursive: true });
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);

const outputBytes = await fs.readFile(outputPath);
const provenance = {
  schemaVersion: "1.0",
  workflowName: "lungfish genotype ai-haplotyping unresolved-inspection-xlsx",
  workflowVersion: "ad-hoc-2026-06-18",
  argv: process.argv,
  inputPaths: sourceRows.map((row) => ({ role: row[0], path: row[1], sizeBytes: row[2], sha256: row[3], exists: row[4] })),
  outputPaths: [{ role: "unresolved inspection workbook", path: outputPath, sizeBytes: outputBytes.length, sha256: hashFile(outputBytes) }],
  revisionID,
  bundlePath,
  statusCounts: Object.fromEntries(statusCounts),
  unresolvedSampleCount: unresolvedSamples.size,
  unresolvedCallCount: unresolvedCalls.length,
  generatedAt: new Date().toISOString(),
};
await fs.writeFile(`${outputPath}.lungfish-provenance.json`, `${JSON.stringify(provenance, null, 2)}\n`);

console.log(JSON.stringify({
  outputPath,
  provenancePath: `${outputPath}.lungfish-provenance.json`,
  unresolvedCallCount: unresolvedCalls.length,
  unresolvedSampleCount: unresolvedSamples.size,
  statusCounts: Object.fromEntries(statusCounts),
}, null, 2));
