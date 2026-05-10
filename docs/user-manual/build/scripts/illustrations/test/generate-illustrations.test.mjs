import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import YAML from "yaml";
import {
  BRAND,
  CLASSIFICATION_ACCENTS,
  ILLUSTRATIONS,
  buildSVG,
  generateAll,
} from "../generate-illustrations.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const manualRoot = resolve(here, "../../../..");

const requiredIds = [
  "linear-vs-circular-genomes",
  "position-coordinates",
  "variant-notation",
  "fastq-record-anatomy",
  "paired-end-reads",
  "phred-quality-bar",
  "platform-read-length-comparison",
  "amplicon-vs-shotgun",
  "primer-scheme-diagram",
  "primer-trim-soft-clip",
  "read-mapping-cartoon",
  "coverage-histogram",
  "pileup-view",
  "cigar-anatomy",
  "vcf-row-anatomy",
  "allele-frequency-haploid-vs-diploid",
  "filter-flag-cartoon",
  "reference-bundle-anatomy",
  "viewport-panes",
  "ncbi-accession-anatomy",
  "msa-column-homology",
  "tree-anatomy",
  "classification-question",
  "assembly-vs-mapping",
];

test("registry contains every illustration requested by the review brief", () => {
  assert.deepEqual(
    ILLUSTRATIONS.map((item) => item.id),
    requiredIds,
  );
});

test("each SVG declares target dimensions and avoids pure black or pure white", () => {
  for (const spec of ILLUSTRATIONS) {
    const svg = buildSVG(spec);
    assert.match(svg, new RegExp(`width="${spec.width}"`));
    assert.match(svg, new RegExp(`height="${spec.height}"`));
    assert.doesNotMatch(svg, /#[fF]{6}|#[0]{6}/);
  }
});

test("illustrations use only brand colors plus the classification accents", () => {
  const allowed = new Set([...Object.values(BRAND), ...Object.values(CLASSIFICATION_ACCENTS)]);
  for (const spec of ILLUSTRATIONS) {
    const svg = buildSVG(spec);
    const colors = [...svg.matchAll(/#[0-9A-Fa-f]{6}\b/g)].map((match) => match[0].toUpperCase());
    for (const color of colors) {
      assert.ok(allowed.has(color), `${spec.id} used unexpected color ${color}`);
    }
  }
});

test("generated PNGs match every target dimension", async () => {
  const dir = await mkdtemp(join(tmpdir(), "lungfish-illustrations-"));
  try {
    const outputs = await generateAll({ outDir: dir });
    assert.equal(outputs.length, requiredIds.length);
    for (const output of outputs) {
      const png = await sharp(output.png).metadata();
      assert.equal(png.width, output.width, `${output.id} PNG width`);
      assert.equal(png.height, output.height, `${output.id} PNG height`);
      const svg = await readFile(output.svg, "utf8");
      assert.match(svg, /paperGrain/);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("central illustration registry covers the generated asset set", async () => {
  const source = await readFile(resolve(manualRoot, "illustrations.yaml"), "utf8");
  const registry = YAML.parse(source);
  const byId = new Map();
  for (const chapter of Object.values(registry.chapters)) {
    for (const item of chapter.illustrations) {
      byId.set(item.id, item);
    }
  }

  for (const spec of ILLUSTRATIONS) {
    const item = byId.get(spec.id);
    assert.ok(item, `registry missing ${spec.id}`);
    assert.equal(item.target_dimensions, `${spec.width}x${spec.height}`);
    assert.equal(item.asset, `assets/illustrations/${spec.chapter}/${spec.id}.png`);
    assert.equal(item.source, `assets/illustrations/${spec.chapter}/${spec.id}.svg`);
    await access(resolve(manualRoot, item.asset));
    await access(resolve(manualRoot, item.source));
  }
});

test("every generated illustration has a chapter body marker", async () => {
  for (const spec of ILLUSTRATIONS) {
    const chapter = await readFile(resolve(manualRoot, "chapters", `${spec.chapter}.md`), "utf8");
    assert.match(chapter, new RegExp(`<!-- ILLUSTRATION: ${spec.id} -->`), `${spec.id} marker`);
  }
});

test("expert-review correctness fixes stay encoded in the SVG source", async () => {
  const byId = new Map(ILLUSTRATIONS.map((spec) => [spec.id, spec]));

  const fastq = buildSVG(byId.get("fastq-record-anatomy"));
  assert.match(fastq, /ACGTTGACCTGAACTTACGGAACCTGACTA\[\.\.\.\]GTTACG/);
  assert.match(fastq, /FFFFFFFFFFHHHHHHHHHHGGGGGGGGGG\[\.\.\.\]&lt;&lt;&lt;;;/);

  const phred = buildSVG(byId.get("phred-quality-bar"));
  assert.match(phred, /M 1095 159 L 600 159/);
  assert.match(phred, /M 1095 218 L 820 218/);

  const primer = buildSVG(byId.get("primer-scheme-diagram"));
  assert.match(primer, /amp_3_LEFT/);
  assert.match(primer, /amp_3_RIGHT/);
  assert.match(primer, /BED is 0-based, half-open/);

  const cigar = buildSVG(byId.get("cigar-anatomy"));
  const cigarText = [...cigar.matchAll(/<text\b[^>]*>(.*?)<\/text>/g)].map((match) => match[1]).join("|");
  assert.match(cigar, /140 aligned bases/);
  assert.match(cigarText, /A\|C\|G\|T\|A/);
  assert.match(cigarText, /T\|T\|G\|C\|A/);

  const bundle = buildSVG(byId.get("reference-bundle-anatomy"));
  assert.match(bundle, /reproducibility provenance/);

  const ncbi = buildSVG(byId.get("ncbi-accession-anatomy"));
  assert.match(ncbi, /accession namespace/);
  assert.match(ncbi, /INSDC \/ GenBank/);
  assert.match(ncbi, /accession pattern helps choose fetch path/);

  const classification = buildSVG(byId.get("classification-question"));
  for (const accent of Object.values(CLASSIFICATION_ACCENTS)) {
    assert.doesNotMatch(classification, new RegExp(accent, "i"));
  }
});
