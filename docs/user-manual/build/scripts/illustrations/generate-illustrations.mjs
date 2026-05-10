#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

export const BRAND = {
  creamsicle: "#EE8B4F",
  peach: "#F6B088",
  ink: "#1F1A17",
  cream: "#FAF4EA",
  grey: "#8A847A",
};

export const CLASSIFICATION_ACCENTS = {
  kraken2: "#3B6FB6",
  esviritu: "#3F8E66",
  taxtriage: "#7A56B0",
  naoMgs: "#C99435",
};

export const ILLUSTRATIONS = [
  spec("01-foundations/01-what-is-a-genome", "linear-vs-circular-genomes", 1200, 600, drawLinearVsCircular),
  spec("01-foundations/01-what-is-a-genome", "position-coordinates", 1400, 300, drawPositionCoordinates),
  spec("01-foundations/01-what-is-a-genome", "variant-notation", 1400, 500, drawVariantNotation),
  spec("01-foundations/02-sequencing-reads", "fastq-record-anatomy", 1400, 600, drawFastqRecord),
  spec("01-foundations/02-sequencing-reads", "paired-end-reads", 1400, 500, drawPairedEndReads),
  spec("01-foundations/02-sequencing-reads", "phred-quality-bar", 1400, 400, drawPhredQualityBar),
  spec("01-foundations/02-sequencing-reads", "platform-read-length-comparison", 1400, 500, drawPlatformReadLength),
  spec("01-foundations/03-amplicon-vs-shotgun", "amplicon-vs-shotgun", 1400, 800, drawAmpliconVsShotgun),
  spec("01-foundations/03-amplicon-vs-shotgun", "primer-scheme-diagram", 1400, 500, drawPrimerScheme),
  spec("01-foundations/03-amplicon-vs-shotgun", "primer-trim-soft-clip", 1400, 500, drawPrimerTrimSoftClip),
  spec("01-foundations/04-alignment-files", "read-mapping-cartoon", 1400, 600, drawReadMapping),
  spec("01-foundations/04-alignment-files", "coverage-histogram", 1400, 350, drawCoverageHistogram),
  spec("01-foundations/04-alignment-files", "pileup-view", 1000, 700, drawPileupView),
  spec("01-foundations/04-alignment-files", "cigar-anatomy", 1400, 600, drawCigarAnatomy),
  spec("01-foundations/05-variants-and-vcf", "vcf-row-anatomy", 1600, 500, drawVcfRowAnatomy),
  spec("01-foundations/05-variants-and-vcf", "allele-frequency-haploid-vs-diploid", 1400, 600, drawAlleleFrequency),
  spec("01-foundations/05-variants-and-vcf", "filter-flag-cartoon", 1200, 500, drawFilterFlag),
  spec("02-sequences/01-importing-and-viewing", "reference-bundle-anatomy", 1400, 600, drawReferenceBundle),
  spec("02-sequences/01-importing-and-viewing", "viewport-panes", 1400, 800, drawViewportPanes),
  spec("02-sequences/02-downloading-from-ncbi", "ncbi-accession-anatomy", 1400, 500, drawNcbiAccession),
  spec("02-sequences/04-msa-and-trees", "msa-column-homology", 1400, 600, drawMsaColumnHomology),
  spec("02-sequences/04-msa-and-trees", "tree-anatomy", 1400, 700, drawTreeAnatomy),
  spec("06-classification/01-what-is-classification", "classification-question", 1400, 500, drawClassificationQuestion),
  spec("07-assembly/01-when-to-assemble", "assembly-vs-mapping", 1400, 600, drawAssemblyVsMapping),
];

function spec(chapter, id, width, height, render) {
  return { chapter, id, width, height, render };
}

export function buildSVG(item) {
  const body = item.render(item.width, item.height);
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${item.width}" height="${item.height}" viewBox="0 0 ${item.width} ${item.height}" role="img" aria-labelledby="title-${item.id}">`,
    `<title id="title-${item.id}">${escapeText(item.id)}</title>`,
    `<defs>${defs()}</defs>`,
    `<rect width="100%" height="100%" fill="${BRAND.cream}"/>`,
    `<rect width="100%" height="100%" fill="${BRAND.cream}" filter="url(#paperGrain)" opacity="0.34"/>`,
    body,
    "</svg>",
  ].join("");
}

export async function generateAll({ outDir = defaultOutDir() } = {}) {
  const outputs = [];
  for (const item of ILLUSTRATIONS) {
    const chapterDir = resolve(outDir, item.chapter);
    await mkdir(chapterDir, { recursive: true });
    const svg = buildSVG(item);
    const svgPath = resolve(chapterDir, `${item.id}.svg`);
    const pngPath = resolve(chapterDir, `${item.id}.png`);
    await writeFile(svgPath, `${svg}\n`);
    await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(pngPath);
    outputs.push({ ...item, svg: svgPath, png: pngPath });
  }
  return outputs;
}

function defaultOutDir() {
  const here = dirname(fileURLToPath(import.meta.url));
  return resolve(here, "../../..", "assets", "illustrations");
}

function defs() {
  return [
    `<filter id="paperGrain" x="0" y="0" width="100%" height="100%">`,
    `<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="19" result="noise"/>`,
    `<feColorMatrix type="saturate" values="0"/>`,
    `<feBlend in="SourceGraphic" in2="noise" mode="multiply"/>`,
    `</filter>`,
    `<filter id="pencilTexture" x="-4%" y="-4%" width="108%" height="108%">`,
    `<feTurbulence type="fractalNoise" baseFrequency="0.055" numOctaves="3" seed="31" result="pencilNoise"/>`,
    `<feDisplacementMap in="SourceGraphic" in2="pencilNoise" scale="0.65" xChannelSelector="R" yChannelSelector="G"/>`,
    `</filter>`,
    `<marker id="arrowCream" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">`,
    `<path d="M 0 0 L 10 5 L 0 10 Q 2 5 0 0" fill="${BRAND.creamsicle}"/>`,
    `</marker>`,
    `<marker id="arrowInk" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">`,
    `<path d="M 0 0 L 10 5 L 0 10 Q 2 5 0 0" fill="${BRAND.ink}"/>`,
    `</marker>`,
    `<linearGradient id="qualityGradient" x1="0%" x2="100%" y1="0%" y2="0%">`,
    `<stop offset="0%" stop-color="${BRAND.cream}"/>`,
    `<stop offset="35%" stop-color="${BRAND.peach}"/>`,
    `<stop offset="100%" stop-color="${BRAND.creamsicle}"/>`,
    `</linearGradient>`,
  ].join("");
}

function drawLinearVsCircular() {
  return group([
    text(170, 430, "linear chromosome", { fill: BRAND.grey, size: 28 }),
    text(820, 506, "circular genome", { fill: BRAND.grey, size: 28 }),
    path(wavyLine(145, 275, 485, 275, 8, 6), { stroke: BRAND.creamsicle, width: 22, fill: "none", cap: "round" }),
    path(wavyLine(145, 275, 485, 275, 8, 6), { stroke: BRAND.ink, width: 2.2, fill: "none", cap: "round", opacity: 0.75 }),
    line(140, 247, 140, 302, { stroke: BRAND.ink, width: 4, cap: "round" }),
    line(490, 247, 490, 302, { stroke: BRAND.ink, width: 4, cap: "round" }),
    text(118, 230, "5'", { mono: true, size: 32 }),
    text(468, 230, "3'", { mono: true, size: 32 }),
    path("M 755 275 C 745 160 875 90 1005 145 C 1135 205 1120 380 995 430 C 860 482 730 405 755 275", { stroke: BRAND.creamsicle, width: 20, fill: "none", cap: "round" }),
    path("M 755 275 C 745 160 875 90 1005 145 C 1135 205 1120 380 995 430 C 860 482 730 405 755 275", { stroke: BRAND.ink, width: 2, fill: "none", cap: "round", opacity: 0.7 }),
    line(937, 129, 937, 84, { stroke: BRAND.ink, width: 4, cap: "round" }),
    text(937, 65, "position 1", { mono: true, size: 28, anchor: "middle" }),
  ]);
}

function drawPositionCoordinates() {
  const y = 190;
  const xs = [150, 325, 565, 815, 1210];
  return group([
    path(wavyLine(135, y, 1235, y, 16, 5), { stroke: BRAND.creamsicle, width: 16, fill: "none", cap: "round" }),
    path("M 555 58 Q 676 38 812 62 L 823 123 Q 693 147 546 124 Z", { stroke: BRAND.creamsicle, width: 3, fill: BRAND.cream }),
    text(684, 96, "SARS-CoV-2 MN908947.3, 29,903 bases", { mono: true, size: 24, anchor: "middle" }),
    path("M 690 128 C 705 145 710 155 718 180", { stroke: BRAND.creamsicle, width: 3, fill: "none", cap: "round" }),
    ...xs.flatMap((x, i) => [
      line(x, y - 24 - (i % 2) * 4, x, y + 25 + (i % 3) * 4, { stroke: BRAND.ink, width: 3, cap: "round" }),
      text(x, 258, ["1", "1000", "5000", "10000", "29903"][i], { mono: true, size: 21, anchor: "middle" }),
    ]),
    text(76, 154, "1-based", { fill: BRAND.grey, size: 21 }),
  ]);
}

function drawVariantNotation() {
  const x = 315;
  const y = 190;
  const parts = [
    ["MN908947.3", x],
    [":", x + 325],
    ["21618", x + 360],
    [" ", x + 526],
    ["C", x + 555],
    [">", x + 625],
    ["T", x + 695],
  ];
  return group([
    roughRect(x + 548, y - 54, 50, 70, { fill: BRAND.peach, stroke: BRAND.peach, width: 1, opacity: 0.28 }),
    roughRect(x + 688, y - 54, 50, 70, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 1, opacity: 0.22 }),
    ...parts.map(([value, px]) => text(px, y, value, { mono: true, size: 56, fill: BRAND.ink })),
    callout(380, 150, 285, 92, "chromosome name"),
    callout(652, 148, 620, 75, "colon separator"),
    callout(760, 148, 930, 92, "1-based position"),
    callout(875, 218, 800, 328, "reference base"),
    callout(1020, 218, 1105, 328, "alternate base"),
  ]);
}

function drawFastqRecord() {
  const left = 285;
  const width = 900;
  const rows = [
    { y: 92, h: 82, label: "header", fill: BRAND.creamsicle, text: "@SRR36291587.1.1 length=150" },
    { y: 188, h: 112, label: "sequence", fill: BRAND.cream, text: "ACGTTGACCTGAACTTACGGAACCTGACTA[...]GTTACG" },
    { y: 318, h: 54, label: "separator", fill: BRAND.cream, text: "+" },
    { y: 390, h: 86, label: "quality", fill: BRAND.cream, text: "FFFFFFFFFFHHHHHHHHHHGGGGGGGGGG[...]<<<;;;" },
  ];
  return group([
    ...rows.flatMap((row, i) => [
      text(235, row.y + row.h / 2 + 9, row.label, { size: 26, weight: 700, anchor: "end" }),
      roughRect(left, row.y, width, row.h, {
        fill: row.fill,
        stroke: i === 0 ? BRAND.creamsicle : BRAND.ink,
        width: i === 0 ? 0 : 1.4,
        opacity: i === 1 ? 0.45 : 1,
      }),
      text(left + width / 2, row.y + row.h / 2 + 9, row.text, { mono: true, size: i === 1 ? 24 : 26, anchor: "middle" }),
    ]),
    text(700, 536, "one FASTQ record repeats as four lines: header, sequence, separator, quality", { fill: BRAND.grey, size: 22, anchor: "middle" }),
  ]);
}

function drawPairedEndReads() {
  const y = 245;
  return group([
    path(wavyLine(190, y, 1210, y, 14, 4), { stroke: BRAND.ink, width: 8, fill: "none", cap: "round" }),
    arrow(205, y - 55, 555, y - 55, { stroke: BRAND.creamsicle, width: 12 }),
    arrow(1190, y + 55, 845, y + 55, { stroke: BRAND.creamsicle, width: 12 }),
    text(375, y - 100, "read 1 (forward)", { size: 26, anchor: "middle" }),
    text(1018, y + 115, "read 2 (reverse complement)", { size: 26, anchor: "middle" }),
    path("M 606 247 Q 705 215 794 247", { stroke: BRAND.grey, width: 3, fill: "none", cap: "round" }),
    text(700, y + 82, "unsequenced insert", { fill: BRAND.grey, size: 24, anchor: "middle" }),
  ]);
}

function drawPhredQualityBar() {
  const read = "ACGTTGACCTGAACTTACGGAACCTGACTA";
  const left = 160;
  const top = 76;
  const colW = 28;
  const qualities = [34, 36, 35, 38, 37, 36, 35, 34, 33, 32, 31, 35, 37, 38, 36, 34, 32, 31, 30, 29, 28, 26, 24, 23, 22, 24, 25, 23, 21, 20];
  return group([
    ...read.split("").map((base, i) => text(left + i * colW, top, base, { mono: true, size: 24 })),
    roughRect(left, 136, 880, 42, { fill: "url(#qualityGradient)", stroke: BRAND.ink, width: 1.2 }),
    ...[0, 10, 20, 30, 40].flatMap((q) => {
      const x = left + (q / 40) * 880;
      return [line(x, 130, x, 188, { stroke: BRAND.ink, width: 2 }), text(x, 218, String(q), { mono: true, size: 20, fill: BRAND.grey, anchor: "middle" })];
    }),
    ...qualities.map((q, i) => roughRect(left + i * colW - 2, 266, colW - 5, 58 + (i % 3), { fill: qFill(q), stroke: BRAND.ink, width: 0.45, opacity: 0.98 })),
    text(1130, 158, "Q20 = 1% error", { size: 26 }),
    text(1130, 218, "Q30 = 0.1% error", { size: 26 }),
    path("M 1095 159 L 600 159", { stroke: BRAND.creamsicle, width: 3, fill: "none", cap: "round" }),
    path("M 1095 218 L 820 218", { stroke: BRAND.creamsicle, width: 3, fill: "none", cap: "round" }),
  ]);
}

function drawPlatformReadLength() {
  const rulerY = 405;
  const ticks = [
    ["100 bp", 200],
    ["1 kb", 485],
    ["10 kb", 780],
    ["100 kb", 1085],
  ];
  return group([
    platformBar(200, 100, 52, "Illumina, ~150 bp"),
    platformBar(200, 205, 635, "PacBio HiFi, ~15 kb"),
    platformBar(485, 310, 600, "Oxford Nanopore, 1-100 kb", true),
    line(185, rulerY, 1115, rulerY, { stroke: BRAND.grey, width: 3, cap: "round" }),
    ...ticks.flatMap(([label, x]) => [
      line(x, rulerY - 18, x, rulerY + 18 + (x % 2) * 3, { stroke: BRAND.grey, width: 3 }),
      text(x, rulerY + 55, label, { mono: true, fill: BRAND.grey, size: 22, anchor: "middle" }),
    ]),
  ]);
}

function drawAmpliconVsShotgun() {
  const topY = 225;
  const bottomY = 565;
  const reads = [
    [270, 126, 70, -1, true], [370, 158, 82, 1], [486, 200, 72, -1], [590, 142, 78, 1],
    [705, 182, 86, -1, true], [835, 128, 76, -1], [948, 176, 84, 1], [1080, 134, 76, -1],
    [1110, 248, 82, 1], [984, 292, 74, -1], [840, 252, 72, 1], [700, 305, 82, -1],
    [555, 268, 76, 1, true], [414, 310, 80, -1], [286, 266, 72, 1], [1160, 315, 64, 1],
    [460, 112, 66, -1], [1015, 222, 72, -1], [630, 230, 68, 1], [775, 220, 74, -1],
  ].map(([x, y, len, dir, soft]) => smallRead(x, y, len, dir, { soft }));
  const tiles = Array.from({ length: 9 }, (_, i) => {
    const x = 235 + i * 100;
    return roughRect(x, bottomY - 84 + (i % 2) * 28, 190, 52, { fill: BRAND.peach, stroke: BRAND.ink, width: 1, opacity: 0.65 });
  });
  return group([
    text(160, topY + 8, "shotgun", { size: 32, weight: 700, anchor: "end" }),
    text(160, bottomY + 8, "amplicon", { size: 32, weight: 700, anchor: "end" }),
    line(225, topY, 1220, topY, { stroke: BRAND.ink, width: 6, cap: "round" }),
    ...reads,
    line(225, bottomY, 1220, bottomY, { stroke: BRAND.ink, width: 6, cap: "round" }),
    ...tiles,
    ...Array.from({ length: 14 }, (_, i) => smallRead(265 + i * 68, bottomY - 18 + (i % 3) * 28, 78, i % 2 ? -1 : 1)),
    text(990, bottomY - 120, "~400 bp", { mono: true, fill: BRAND.grey, size: 22 }),
  ]);
}

function drawPrimerScheme() {
  const y = 170;
  const pairs = [
    ["amp_1_LEFT", 230, 355, 270, 92],
    ["amp_2_LEFT", 535, 665, 575, 92],
    ["amp_3_LEFT", 840, 970, 880, 92],
  ];
  const rev = [
    ["amp_1_RIGHT", 490, 365, 452, 238],
    ["amp_2_RIGHT", 795, 670, 755, 238],
    ["amp_3_RIGHT", 1100, 975, 1060, 238],
  ];
  return group([
    line(190, y, 1210, y, { stroke: BRAND.ink, width: 6, cap: "round" }),
    ...[205, 510, 815].map((x, i) => roughRect(x, y - 52, 320, 106, { fill: BRAND.peach, stroke: BRAND.peach, width: 2, opacity: 0.45 + i * 0.03 })),
    ...pairs.flatMap(([name, x1, x2, labelX, labelY]) => [
      arrow(x1, y - 48, x2, y - 48, { stroke: BRAND.creamsicle, width: 12 }),
      text(labelX, labelY, name, { mono: true, size: 18, anchor: "middle" }),
    ]),
    ...rev.flatMap(([name, x1, x2, labelX, labelY]) => [
      arrow(x1, y + 48, x2, y + 48, { stroke: BRAND.creamsicle, width: 12 }),
      text(labelX, labelY, name, { mono: true, size: 18, anchor: "middle" }),
    ]),
    text(700, 308, "BED-style coordinates", { size: 22, weight: 700, anchor: "middle" }),
    drawMiniTable(470, 318, [
      ["name", "start", "end"],
      ["amp_1_LEFT", "30", "54"],
      ["amp_1_RIGHT", "410", "434"],
      ["amp_2_LEFT", "380", "404"],
      ["amp_2_RIGHT", "760", "784"],
      ["amp_3_LEFT", "730", "754"],
      ["amp_3_RIGHT", "1110", "1134"],
    ], [210, 88, 88], 20),
    text(700, 486, "BED is 0-based, half-open", { fill: BRAND.grey, size: 15, anchor: "middle" }),
  ]);
}

function drawPrimerTrimSoftClip() {
  return group([
    text(130, 64, "before primer trim", { size: 27, weight: 700 }),
    text(130, 276, "after primer trim", { size: 27, weight: 700 }),
    readCapsule(350, 80, 730, 68, 165, 1),
    readCapsule(350, 292, 730, 68, 165, 0.3),
    path("M 1005 172 C 1085 225 1082 258 1005 307", { stroke: BRAND.creamsicle, width: 5, fill: "none", cap: "round", markerEnd: "url(#arrowCream)" }),
    text(456, 395, "[soft-clipped]", { mono: true, size: 24 }),
    path("M 440 373 Q 505 352 570 372", { stroke: BRAND.ink, width: 3, fill: "none", cap: "round" }),
    text(930, 410, "primer bases ignored by the variant caller", { size: 26, anchor: "middle" }),
  ]);
}

function drawReadMapping() {
  const y = 115;
  const reads = Array.from({ length: 20 }, (_, i) => {
    const x = 230 + ((i * 74) % 880);
    const row = Math.floor(i / 5);
    const yy = 178 + row * 58 + (i % 2) * 8;
    const len = 82 + ((i * 17) % 44);
    const dir = i % 4 === 0 || i % 4 === 3 ? -1 : 1;
    return readArrow(x, yy, len, dir, { soft: i % 5 === 0, width: 7 });
  });
  return group([
    line(155, y, 1250, y, { stroke: BRAND.ink, width: 7, cap: "round" }),
    text(162, 72, "reference", { size: 24 }),
    ...reads,
    callout(388, 302, 230, 444, "forward strand"),
    callout(805, 244, 1030, 430, "reverse strand"),
    callout(252, 186, 270, 158, "soft-clipped end"),
    line(155, 520, 1250, 520, { stroke: BRAND.grey, width: 3 }),
    ...[["1", 155], ["500", 430], ["1000", 735], ["1500", 1035]].flatMap(([label, x]) => [
      line(x, 505, x, 535, { stroke: BRAND.grey, width: 2 }),
      text(x, 566, label, { mono: true, fill: BRAND.grey, size: 20, anchor: "middle" }),
    ]),
  ]);
}

function drawCoverageHistogram() {
  const left = 110;
  const bottom = 290;
  const height = 230;
  const points = Array.from({ length: 52 }, (_, i) => {
    const x = left + i * 23;
    const wave = 130 + 50 * Math.sin(i / 3) + 30 * Math.sin(i / 1.7);
    const trough = i > 29 && i < 37 ? 18 + (i % 3) * 3 : wave;
    return [x, bottom - Math.max(16, trough)];
  });
  const d = [`M ${left} ${bottom}`, ...points.map(([x, y]) => `L ${x} ${y}`), `L ${left + 51 * 23} ${bottom}`, "Z"].join(" ");
  return group([
    line(left, 55, left, bottom, { stroke: BRAND.ink, width: 3 }),
    line(left, bottom, 1290, bottom, { stroke: BRAND.ink, width: 3 }),
    path(d, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1.5, opacity: 0.92 }),
    roughRect(810, 178, 142, 108, { fill: BRAND.peach, stroke: BRAND.peach, width: 2, opacity: 0.34 }),
    callout(875, 222, 1030, 92, "low coverage"),
    ...[0, 500, 1000, 1500, 2000].map((v) => text(74, bottom - (v / 2000) * height + 7, String(v), { mono: true, fill: BRAND.grey, size: 16, anchor: "end" })),
    ...[1, 500, 1000, 1500, 2000].map((v, i) => text(left + i * 295, 330, String(v), { mono: true, fill: BRAND.grey, size: 16, anchor: "middle" })),
  ]);
}

function drawPileupView() {
  const stackX = 315;
  const rows = ["C", "C", "C", "T", "C", "C", "T", "C", "C", "T"];
  return group([
    roughRect(stackX - 70, 60, 190, 62, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 2 }),
    text(stackX + 25, 102, "C", { mono: true, size: 38, anchor: "middle" }),
    text(stackX + 165, 100, "reference", { size: 22 }),
    ...rows.flatMap((base, i) => {
      const y = 155 + i * 42;
      return [
        roughRect(stackX - 95 + (i % 2) * 10, y, 240, 31, { fill: qFill(20 + ((i * 7) % 18)), stroke: BRAND.ink, width: 1 }),
        text(stackX + 25, y + 24, base, { mono: true, size: 25, anchor: "middle" }),
      ];
    }),
    text(555, 275, `7 \u00d7 C, 3 \u00d7 T`, { size: 30, weight: 700 }),
    text(555, 340, "allele frequency = 3/10 = 30%", { size: 26 }),
  ]);
}

function drawCigarAnatomy() {
  const left = 145;
  const y = 105;
  const clipW = 96;
  const matchW = 760;
  const rightX = left + clipW + matchW;
  const baseW = 17;
  return group([
    text(left, 70, "read sequence", { size: 22, weight: 700 }),
    roughRect(left, y, clipW, 56, { fill: BRAND.peach, stroke: BRAND.ink, width: 1.2, opacity: 0.85 }),
    ...["A", "C", "G", "T", "A"].map((base, i) => text(left + 13 + i * baseW, y + 36, base, { mono: true, size: 20, fill: BRAND.ink })),
    roughRect(left + clipW, y, matchW, 56, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1.2, opacity: 0.72 }),
    text(left + clipW + 36, y + 36, "CGTTGACCTGAA", { mono: true, size: 20, fill: BRAND.ink }),
    text(left + clipW + matchW / 2, y + 36, "140 aligned bases", { size: 22, weight: 700, anchor: "middle" }),
    text(left + clipW + matchW - 180, y + 36, "TACGTAACCGT", { mono: true, size: 20, fill: BRAND.ink }),
    roughRect(rightX, y, clipW, 56, { fill: BRAND.peach, stroke: BRAND.ink, width: 1.2, opacity: 0.85 }),
    ...["T", "T", "G", "C", "A"].map((base, i) => text(rightX + 13 + i * baseW, y + 36, base, { mono: true, size: 20, fill: BRAND.ink })),
    text(left + clipW + 15, 258, "reference", { size: 22, weight: 700 }),
    line(left + clipW, 280, left + clipW + matchW, 280, { stroke: BRAND.ink, width: 5, cap: "round" }),
    text(left + clipW + 32, 317, "CGTTGACCTGAA", { mono: true, size: 18, fill: BRAND.ink }),
    text(left + clipW + matchW - 175, 317, "TACGTAACCGT", { mono: true, size: 18, fill: BRAND.ink }),
    bracket(left, 178, left + clipW, 178, "5S"),
    bracket(left + clipW, 178, left + clipW + matchW, 178, "140M"),
    bracket(rightX, 178, rightX + clipW, 178, "5S"),
    text(610, 435, "5S140M5S", { mono: true, size: 58, anchor: "middle" }),
    line(left + clipW, 334, left + clipW, 362, { stroke: BRAND.grey, width: 2 }),
    text(left + clipW, 392, "1000", { mono: true, fill: BRAND.grey, size: 20, anchor: "middle" }),
    text(1085, 345, "soft-clipped bases keep their base calls", { size: 23, anchor: "middle" }),
    text(1085, 384, "they are not replaced with N", { size: 23, anchor: "middle" }),
  ]);
}

function drawVcfRowAnatomy() {
  const left = 55;
  const top = 62;
  const widths = [160, 95, 70, 70, 70, 90, 100, 210, 145, 170];
  const headers = ["CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT", "sample"];
  const values = ["MN908947.3", "21618", ".", "C", "T", "1234", "PASS", "DP=200;AF=0.95", "GT:DP:AF", "1:200:0.95"];
  const caps = ["chromosome", "1-based position", "ID or .", "REF base", "ALT base", "Phred quality", "filter status", "INFO annotations", "format keys", "sample values"];
  let x = left;
  const cells = [];
  for (let i = 0; i < widths.length; i += 1) {
    cells.push(roughRect(x, top, widths[i], 70, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1.1 }));
    cells.push(roughRect(x, top + 70, widths[i], 90, { fill: BRAND.cream, stroke: BRAND.ink, width: 1.1 }));
    cells.push(text(x + widths[i] / 2, top + 43, headers[i], { size: 21, weight: 700, anchor: "middle" }));
    cells.push(text(x + widths[i] / 2, top + 123, values[i], { mono: true, size: i === 7 ? 17 : 19, anchor: "middle" }));
    cells.push(roughRect(x, top + 178, widths[i], 122, { fill: BRAND.cream, stroke: BRAND.ink, width: 0.7, opacity: 0.68 }));
    cells.push(wrappedText(x + widths[i] / 2, top + 212, caps[i], widths[i] - 12, 18, { fill: BRAND.grey, size: 16, weight: 800, anchor: "middle" }));
    x += widths[i];
  }
  return group(cells);
}

function drawAlleleFrequency() {
  const virions = Array.from({ length: 34 }, (_, i) => {
    const x = 835 + (i % 7) * 48 + ((i * 13) % 9);
    const y = 145 + Math.floor(i / 7) * 46 + ((i * 7) % 8);
    return group([
      circle(x, y, 15 + (i % 3), { fill: BRAND.cream, stroke: BRAND.ink, width: 2 }),
      i % 2 === 0 ? circle(x + 3, y - 2, 5, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 1 }) : "",
    ]);
  });
  return group([
    line(700, 82, 700, 535, { stroke: BRAND.grey, width: 3 }),
    chromosome(205, 190, true),
    chromosome(205, 275, false),
    text(335, 426, "human diploid", { size: 24, weight: 700, anchor: "middle" }),
    text(335, 464, "1 of 2 alleles carries the variant, AF = 0.5", { size: 21, anchor: "middle" }),
    callout(360, 190, 490, 128, "variant"),
    path("M 810 100 Q 1030 60 1240 100 L 1195 465 Q 1018 505 850 465 Z", { fill: BRAND.cream, stroke: BRAND.ink, width: 3 }),
    ...virions,
    text(1040, 510, "viral haploid", { size: 24, weight: 700, anchor: "middle" }),
    text(1040, 548, "half the read evidence supports the variant, AF = 0.5", { size: 21, anchor: "middle" }),
    callout(996, 147, 1220, 130, "variant"),
  ]);
}

function drawFilterFlag() {
  const left = 125;
  const top = 92;
  const rows = [
    ["MN908947.3", "21618", "C", "T", "PASS", "pass"],
    ["MN908947.3", "22813", "G", "A", "ft", "failed allele-frequency threshold"],
    ["MN908947.3", "23063", "A", "T", "sb", "failed strand bias filter"],
  ];
  return group([
    roughRect(left + 440, top - 15, 145, 332, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 1, opacity: 0.22 }),
    ...rows.flatMap((row, i) => {
      const y = top + i * 105;
      return [
        roughRect(left, y, 600, 70, { fill: BRAND.cream, stroke: BRAND.ink, width: 1.3 }),
        text(left + 35, y + 44, row[0], { mono: true, fill: BRAND.grey, size: 18 }),
        text(left + 215, y + 44, row[1], { mono: true, fill: BRAND.grey, size: 18 }),
        text(left + 310, y + 44, row[2], { mono: true, fill: BRAND.grey, size: 18 }),
        text(left + 370, y + 44, row[3], { mono: true, fill: BRAND.grey, size: 18 }),
        text(left + 490, y + 44, row[4], { mono: true, size: 25, anchor: "middle" }),
        i === 0 ? path(`M ${left + 660} ${y + 39} l 16 16 l 36 -39`, { stroke: BRAND.ink, width: 6, fill: "none", cap: "round" }) : warning(left + 655, y + 23, 0.82),
        i === 1 ? group([text(left + 785, y + 36, "failed allele-frequency", { size: 19 }), text(left + 785, y + 62, "threshold", { size: 19 })]) : "",
        i === 2 ? text(left + 785, y + 46, "failed strand bias filter", { size: 19 }) : "",
      ];
    }),
    text(610, 445, "ft, sb are Lungfish cross-caller filter names", { fill: BRAND.grey, size: 18, anchor: "middle" }),
  ]);
}

function drawReferenceBundle() {
  const files = [
    ["MN908947.3.fasta", "sequence", 430, 135],
    ["MN908947.3.fasta.fai", "samtools faidx index", 790, 135],
    ["manifest.json", "bundle metadata", 430, 360],
    ["provenance.json", "reproducibility provenance", 790, 360],
  ];
  return group([
    folderIcon(85, 115, 245, 175, "MN908947.3.lungfishref/"),
    line(330, 230, 375, 230, { stroke: BRAND.creamsicle, width: 3, cap: "round" }),
    line(375, 168, 375, 428, { stroke: BRAND.creamsicle, width: 3, cap: "round" }),
    line(375, 168, 430, 168, { stroke: BRAND.creamsicle, width: 3, cap: "round" }),
    line(375, 168, 790, 168, { stroke: BRAND.creamsicle, width: 3, cap: "round" }),
    line(375, 428, 430, 428, { stroke: BRAND.creamsicle, width: 3, cap: "round" }),
    line(375, 428, 790, 428, { stroke: BRAND.creamsicle, width: 3, cap: "round" }),
    ...files.map(([name, cap, x, y]) => fileIcon(x, y, name, cap)),
  ]);
}

function drawViewportPanes() {
  return group([
    roughRect(120, 85, 1160, 620, { fill: BRAND.cream, stroke: BRAND.ink, width: 3 }),
    roughRect(170, 135, 780, 245, { fill: BRAND.cream, stroke: BRAND.creamsicle, width: 5 }),
    roughRect(170, 415, 780, 215, { fill: BRAND.cream, stroke: BRAND.creamsicle, width: 4 }),
    roughRect(990, 135, 240, 495, { fill: BRAND.cream, stroke: BRAND.creamsicle, width: 4 }),
    coverageSparkline(215, 225, 650, 88),
    text(560, 515, "ATG  GAA  TTT  CCA", { mono: true, size: 28, anchor: "middle" }),
    ...["gene", "product", "location", "strand"].map((label, i) => text(1030, 215 + i * 70, label, { fill: BRAND.grey, size: 22 })),
    callout(545, 143, 260, 80, "track viewer"),
    callout(530, 525, 310, 685, "sequence panel"),
    callout(1115, 175, 1090, 90, "feature inspector"),
  ]);
}

function drawNcbiAccession() {
  const y = 160;
  return group([
    text(510, y, "MN908947.3", { mono: true, size: 66, anchor: "middle" }),
    callout(385, 108, 320, 92, "accession namespace"),
    callout(520, 108, 650, 82, "accession number"),
    callout(714, 108, 960, 92, "version"),
    fileIcon(195, 250, "INSDC / GenBank", "nucleotide record"),
    fileIcon(560, 250, "record", "selected by number"),
    fileIcon(920, 250, "snapshot", "selected by version"),
    text(700, 455, "accession pattern helps choose fetch path. version tells you which snapshot.", { fill: BRAND.grey, size: 23, anchor: "middle" }),
    text(900, 192, "RefSeq accessions start with NC_, NM_, etc.", { fill: BRAND.grey, size: 19 }),
  ]);
}

function drawMsaColumnHomology() {
  const before = ["ACGTTACCTA", "ACGACCTA", "ACGTTACCGA"];
  const after = ["ACGTTACCTA", "ACG--ACCTA", "ACGTTACCGA"];
  return group([
    text(210, 80, "before MAFFT", { size: 28, weight: 700 }),
    ...before.map((seq, i) => text(230, 138 + i * 45, seq, { mono: true, size: 28 })),
    path("M 570 210 C 650 240 712 270 780 300", { stroke: BRAND.creamsicle, width: 5, fill: "none", cap: "round", markerEnd: "url(#arrowCream)" }),
    text(915, 80, "after MAFFT", { size: 28, weight: 700 }),
    ...[887, 921, 972].map((x) => roughRect(x - 8, 112, 32, 160, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 1, opacity: 0.18 })),
    ...after.map((seq, i) => text(835, 138 + i * 45, seq, { mono: true, size: 28 })),
    text(930, 370, "homologous columns share a column", { size: 26, anchor: "middle" }),
  ]);
}

function drawTreeAnatomy() {
  const lines = [
    [180, 350, 330, 350], [330, 190, 330, 510], [330, 190, 550, 190], [330, 510, 560, 510],
    [550, 130, 550, 250], [550, 130, 1050, 130], [550, 250, 870, 250],
    [560, 440, 560, 580], [560, 440, 980, 440], [560, 580, 1030, 580],
    [870, 215, 870, 285], [870, 215, 1110, 215], [870, 285, 1030, 285],
  ];
  return group([
    ...lines.map(([x1, y1, x2, y2]) => line(x1, y1, x2, y2, { stroke: BRAND.ink, width: 5, cap: "round" })),
    ...[
      ["sample-A", 1065, 137], ["sample-B", 1125, 222], ["sample-C", 1045, 292], ["sample-D", 995, 447], ["sample-E", 1045, 587],
    ].map(([label, x, y]) => text(x, y, label, { mono: true, fill: BRAND.grey, size: 22 })),
    pill(575, 175, "0.95"),
    pill(895, 200, "0.78"),
    pill(585, 425, "1.00"),
    callout(1055, 130, 1170, 85, "tip"),
    callout(330, 350, 300, 240, "internal node"),
    callout(760, 440, 735, 380, "branch length"),
    callout(610, 176, 470, 85, "bootstrap support"),
  ]);
}

function drawClassificationQuestion() {
  return group([
    fileIcon(120, 172, "reads.fastq.gz", "input reads"),
    arrow(360, 250, 525, 250, { stroke: BRAND.creamsicle, width: 7 }),
    roughRect(535, 148, 345, 205, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 3, opacity: 0.92 }),
    text(707, 212, "classifier", { size: 31, weight: 700, anchor: "middle" }),
    text(707, 260, "Kraken2 / EsViritu", { size: 20, anchor: "middle" }),
    text(707, 292, "TaxTriage / NAO-MGS", { size: 20, anchor: "middle" }),
    text(707, 324, "alternative tools", { size: 18, fill: BRAND.ink, anchor: "middle" }),
    arrow(885, 250, 1015, 250, { stroke: BRAND.creamsicle, width: 7 }),
    sunburst(1130, 250),
    line(1130, 84, 1130, 122, { stroke: BRAND.creamsicle, width: 2, cap: "round" }),
    text(1130, 64, "bacteria", { size: 21, anchor: "middle" }),
    line(1266, 250, 1290, 250, { stroke: BRAND.creamsicle, width: 2, cap: "round" }),
    text(1302, 258, "virus", { size: 21 }),
    line(1061, 382, 1035, 408, { stroke: BRAND.creamsicle, width: 2, cap: "round" }),
    text(1018, 435, "host", { size: 21, anchor: "middle" }),
  ]);
}

function drawAssemblyVsMapping() {
  return group([
    line(700, 78, 700, 528, { stroke: BRAND.grey, width: 3 }),
    text(350, 92, "mapping", { size: 32, weight: 700, anchor: "middle" }),
    line(135, 285, 590, 285, { stroke: BRAND.ink, width: 7, cap: "round" }),
    ...Array.from({ length: 8 }, (_, i) => {
      const x = 165 + i * 50;
      const y = 155 + (i % 3) * 42;
      return group([readArrow(x, y, 85, 1, { width: 7 }), path(`M ${x + 40} ${y + 16} Q ${x + 55} ${y + 70} ${x + 70} 278`, { stroke: BRAND.creamsicle, width: 2.5, fill: "none" })]);
    }),
    text(350, 438, "reference required", { fill: BRAND.grey, size: 23, anchor: "middle" }),
    text(1050, 92, "assembly", { size: 32, weight: 700, anchor: "middle" }),
    ...Array.from({ length: 9 }, (_, i) => readArrow(815 + (i % 3) * 112 - Math.floor(i / 3) * 26, 140 + Math.floor(i / 3) * 42, 120, 1, { width: 7 })),
    text(1050, 314, "overlap then extend", { fill: BRAND.grey, size: 20, anchor: "middle" }),
    ...[850, 910, 970].map((x, i) => path(wavyLine(x, 340 + i * 18, x + 260, 340 + i * 18, 7, 4), { stroke: BRAND.creamsicle, width: 8, fill: "none", cap: "round" })),
    arrow(1050, 380, 1050, 413, { stroke: BRAND.creamsicle, width: 5 }),
    ...[825, 1000, 1135].map((x, i) => path(wavyLine(x, 450 + i * 24, x + 250 - i * 35, 450 + i * 24, 7, 4), { stroke: BRAND.creamsicle, width: 16, fill: "none", cap: "round" })),
    text(1050, 535, "no reference required", { fill: BRAND.grey, size: 23, anchor: "middle" }),
  ]);
}

function platformBar(x, y, w, label, frayed = false) {
  const right = frayed
    ? `L ${x + w - 18} ${y} l 22 8 l -10 8 l 18 9 l -22 9 l 12 8 L ${x} ${y + 42} Z`
    : `L ${x + w} ${y} Q ${x + w + 8} ${y + 20} ${x + w} ${y + 42} L ${x} ${y + 42} Q ${x - 6} ${y + 20} ${x} ${y} Z`;
  return group([
    path(`M ${x} ${y} ${right}`, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1.5 }),
    pencilShade(x, y, w, 42, BRAND.creamsicle, 0.9),
    text(x + w + (frayed ? 18 : 34), y + 29, label, { mono: true, size: frayed ? 18 : 22 }),
  ]);
}

function readCapsule(x, y, w, h, primerW, primerOpacity) {
  return group([
    roughRect(x, y, primerW, h, { fill: BRAND.peach, stroke: BRAND.ink, width: 1.2, opacity: primerOpacity }),
    roughRect(x + primerW, y, w - primerW, h, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1.2 }),
    text(x + 82, y + 44, "primer", { size: 21, anchor: "middle" }),
    text(x + primerW + (w - primerW) / 2, y + 44, "sample-derived read body", { size: 21, anchor: "middle" }),
  ]);
}

function chromosome(x, y, hasVariant) {
  return group([
    path(`M ${x} ${y} C ${x + 45} ${y - 24} ${x + 240} ${y - 20} ${x + 320} ${y} C ${x + 240} ${y + 22} ${x + 45} ${y + 24} ${x} ${y} Z`, { fill: BRAND.ink, stroke: BRAND.ink, width: 2, opacity: 0.9 }),
    path(`M ${x + 155} ${y - 18} Q ${x + 170} ${y} ${x + 155} ${y + 18}`, { stroke: BRAND.cream, width: 4, fill: "none", cap: "round" }),
    hasVariant ? path(`M ${x + 235} ${y - 18} Q ${x + 258} ${y} ${x + 235} ${y + 18}`, { stroke: BRAND.creamsicle, width: 12, fill: "none", cap: "round" }) : "",
  ]);
}

function folderIcon(x, y, w, h, label) {
  return group([
    path(`M ${x} ${y + 45} Q ${x + 6} ${y + 25} ${x + 42} ${y + 26} L ${x + 110} ${y + 26} L ${x + 132} ${y + 48} L ${x + w} ${y + 48} Q ${x + w + 16} ${y + h - 5} ${x + w - 18} ${y + h} L ${x + 14} ${y + h} Q ${x - 8} ${y + h - 4} ${x} ${y + 45} Z`, { fill: BRAND.cream, stroke: BRAND.creamsicle, width: 5 }),
    text(x + w / 2, y + h + 42, label, { mono: true, size: 22, anchor: "middle" }),
  ]);
}

function fileIcon(x, y, name, caption) {
  return group([
    path(`M ${x} ${y} L ${x + 170} ${y} L ${x + 205} ${y + 34} L ${x + 205} ${y + 132} Q ${x + 105} ${y + 144} ${x} ${y + 132} Z`, { fill: BRAND.cream, stroke: BRAND.creamsicle, width: 4 }),
    path(`M ${x + 170} ${y} L ${x + 170} ${y + 36} L ${x + 205} ${y + 34}`, { fill: "none", stroke: BRAND.creamsicle, width: 3 }),
    text(x + 102, y + 64, name, { mono: true, size: 19, anchor: "middle" }),
    text(x + 102, y + 167, caption, { fill: BRAND.grey, size: 19, anchor: "middle" }),
  ]);
}

function coverageSparkline(x, y, w, h) {
  const pts = Array.from({ length: 28 }, (_, i) => [x + i * (w / 27), y + h - (18 + ((i * 19) % 60))]);
  const d = [`M ${x} ${y + h}`, ...pts.map(([px, py]) => `L ${px} ${py}`), `L ${x + w} ${y + h}`, "Z"].join(" ");
  return group([
    path(d, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1 }),
    pencilShade(x, y + 12, w, h - 12, BRAND.creamsicle, 0.72),
  ]);
}

function sunburst(cx, cy) {
  return group([
    wedge(cx, cy, 34, 116, -90, 25, BRAND.creamsicle),
    wedge(cx, cy, 34, 116, 25, 140, BRAND.peach),
    wedge(cx, cy, 34, 116, 140, 270, BRAND.grey),
    wedge(cx, cy, 122, 170, -70, 40, BRAND.creamsicle),
    wedge(cx, cy, 122, 170, 45, 175, BRAND.peach),
    wedge(cx, cy, 122, 170, 178, 260, BRAND.creamsicle),
    circle(cx, cy, 32, { fill: BRAND.cream, stroke: BRAND.ink, width: 2 }),
  ]);
}

function wedge(cx, cy, r1, r2, a1, a2, fill) {
  const p1 = polar(cx, cy, r2, a1);
  const p2 = polar(cx, cy, r2, a2);
  const p3 = polar(cx, cy, r1, a2);
  const p4 = polar(cx, cy, r1, a1);
  const large = a2 - a1 > 180 ? 1 : 0;
  return path(`M ${p1.x} ${p1.y} A ${r2} ${r2} 0 ${large} 1 ${p2.x} ${p2.y} L ${p3.x} ${p3.y} A ${r1} ${r1} 0 ${large} 0 ${p4.x} ${p4.y} Z`, { fill, stroke: BRAND.ink, width: 2, opacity: 0.72 });
}

function polar(cx, cy, r, degrees) {
  const rad = (degrees * Math.PI) / 180;
  return { x: round(cx + r * Math.cos(rad)), y: round(cy + r * Math.sin(rad)) };
}

function drawMiniTable(x, y, rows, widths, rowH = 30) {
  const parts = [];
  const fontSize = rowH <= 22 ? 14 : 16;
  for (let r = 0; r < rows.length; r += 1) {
    let cx = x;
    for (let c = 0; c < rows[r].length; c += 1) {
      parts.push(roughRect(cx, y + r * rowH, widths[c], rowH, { fill: r === 0 ? BRAND.creamsicle : BRAND.cream, stroke: BRAND.ink, width: 1 }));
      parts.push(text(cx + 10, y + r * rowH + rowH * 0.72, rows[r][c], { mono: true, size: fontSize }));
      cx += widths[c];
    }
  }
  return group(parts);
}

function bracket(x1, y, x2, _y2, label) {
  const mid = (x1 + x2) / 2;
  return group([
    path(`M ${x1} ${y} Q ${mid} ${y + 16} ${x2} ${y} M ${x1} ${y} l 0 28 M ${x2} ${y} l 0 28`, { stroke: BRAND.ink, width: 2.3, fill: "none", cap: "round" }),
    text(mid, y + 58, label, { mono: true, size: 22, anchor: "middle" }),
  ]);
}

function pill(x, y, value) {
  return group([
    path(`M ${x} ${y} Q ${x + 50} ${y - 16} ${x + 102} ${y} Q ${x + 112} ${y + 31} ${x + 102} ${y + 42} Q ${x + 50} ${y + 56} ${x} ${y + 42} Q ${x - 12} ${y + 12} ${x} ${y} Z`, { fill: BRAND.creamsicle, stroke: BRAND.creamsicle, width: 1 }),
    text(x + 51, y + 29, value, { mono: true, size: 20, anchor: "middle" }),
  ]);
}

function warning(x, y, scale = 1) {
  const s = scale;
  return group([
    path(`M ${x + 28 * s} ${y} L ${x + 58 * s} ${y + 54 * s} L ${x} ${y + 54 * s} Z`, { fill: BRAND.peach, stroke: BRAND.ink, width: 3 * s }),
    line(x + 29 * s, y + 18 * s, x + 29 * s, y + 34 * s, { stroke: BRAND.ink, width: 4 * s, cap: "round" }),
    circle(x + 29 * s, y + 44 * s, 2.5 * s, { fill: BRAND.ink, stroke: BRAND.ink, width: 1 }),
  ]);
}

function callout(ax, ay, lx, ly, label) {
  const circlePart = circle(ax, ay, 7, { fill: BRAND.cream, stroke: BRAND.creamsicle, width: 3 });
  const cx = round((ax + lx) / 2 + (ay > ly ? -20 : 20));
  const cy = round((ay + ly) / 2);
  return group([
    circlePart,
    path(`M ${ax} ${ay} Q ${cx} ${cy} ${lx} ${ly}`, { stroke: BRAND.creamsicle, width: 3, fill: "none", cap: "round" }),
    text(lx, ly - 12, label, { size: 24, weight: 700, anchor: lx < ax ? "end" : "start" }),
  ]);
}

function readArrow(x, y, len, dir = 1, { soft = false, width = 10 } = {}) {
  const x1 = dir === 1 ? x : x + len;
  const x2 = dir === 1 ? x + len : x;
  const tipStart = dir === 1 ? x : x + len - 28;
  const d = `M ${x1} ${y} C ${x1 + dir * len * 0.25} ${y - 5} ${x1 + dir * len * 0.72} ${y + 5} ${x2} ${y}`;
  return group([
    soft ? roughRect(tipStart, y - 10, 36, 20, { fill: BRAND.peach, stroke: BRAND.peach, width: 1, opacity: 0.55 }) : "",
    path(d, { stroke: BRAND.creamsicle, width, fill: "none", cap: "round", markerEnd: "url(#arrowCream)" }),
    path(d.replaceAll(` ${y}`, ` ${round(y - 2.2)}`), { stroke: BRAND.creamsicle, width: Math.max(1.3, width * 0.22), fill: "none", cap: "round", opacity: 0.34 }),
    path(d.replaceAll(` ${y}`, ` ${round(y + 2.1)}`), { stroke: BRAND.peach, width: Math.max(1.1, width * 0.16), fill: "none", cap: "round", opacity: 0.28 }),
  ]);
}

function smallRead(x, y, len, dir = 1, { soft = false } = {}) {
  const h = 18;
  const head = Math.min(20, len * 0.28);
  const tail = dir === 1 ? x : x + len;
  const tip = dir === 1 ? x + len : x;
  const neck = dir === 1 ? tip - head : tip + head;
  const d = [
    `M ${tail} ${y - h * 0.32}`,
    `Q ${(tail + neck) / 2} ${y - h * 0.56} ${neck} ${y - h * 0.34}`,
    `L ${neck} ${y - h * 0.62}`,
    `L ${tip} ${y}`,
    `L ${neck} ${y + h * 0.62}`,
    `L ${neck} ${y + h * 0.34}`,
    `Q ${(tail + neck) / 2} ${y + h * 0.56} ${tail} ${y + h * 0.32}`,
    "Z",
  ].join(" ");
  const softX = dir === 1 ? tail - 4 : tail - 22;
  return group([
    soft ? roughRect(softX, y - 8, 26, 16, { fill: BRAND.peach, stroke: BRAND.peach, width: 1, opacity: 0.46 }) : "",
    path(d, { fill: BRAND.creamsicle, stroke: BRAND.ink, width: 1.1, opacity: 0.9 }),
    path(wavyLine(tail + dir * 8, y - 2, neck - dir * 6, y - 2, 4, 1), { stroke: BRAND.peach, width: 1.2, fill: "none", cap: "round", opacity: 0.46 }),
  ]);
}

function arrow(x1, y1, x2, y2, { stroke = BRAND.creamsicle, width = 5 } = {}) {
  const d = `M ${x1} ${y1} C ${(x1 + x2) / 2} ${y1 - 10} ${(x1 + x2) / 2} ${y2 + 10} ${x2} ${y2}`;
  return group([
    path(d, {
      stroke,
      width,
      fill: "none",
      cap: "round",
      markerEnd: stroke === BRAND.ink ? "url(#arrowInk)" : "url(#arrowCream)",
    }),
    path(d, { stroke, width: Math.max(1.2, width * 0.25), fill: "none", cap: "round", opacity: 0.32 }),
  ]);
}

function roughRect(x, y, w, h, { fill = BRAND.cream, stroke = BRAND.ink, width = 2, opacity = 1 } = {}) {
  const d = [
    `M ${x + 3} ${y + 1}`,
    `Q ${x + w / 2} ${y - 5} ${x + w - 4} ${y + 3}`,
    `Q ${x + w + 4} ${y + h / 2} ${x + w - 3} ${y + h - 2}`,
    `Q ${x + w / 2} ${y + h + 5} ${x + 2} ${y + h - 3}`,
    `Q ${x - 4} ${y + h / 2} ${x + 3} ${y + 1}`,
    "Z",
  ].join(" ");
  const base = path(d, { fill, stroke, width, opacity });
  const shade = pencilShade(x, y, w, h, fill, opacity);
  return group([base, shade]);
}

function pencilShade(x, y, w, h, color, opacity = 1) {
  if (!String(color).startsWith("#") || color === BRAND.cream || opacity < 0.2 || w < 35 || h < 18) return "";
  const count = Math.max(2, Math.min(12, Math.round((w * h) / 14000)));
  const parts = [];
  for (let i = 0; i < count; i += 1) {
    const ratio = (i + 1) / (count + 1);
    const jitter = Math.sin((x + y + i * 37) * 0.09) * 3.2;
    const y1 = round(y + h * ratio + jitter);
    const x1 = round(x + 9 + Math.cos((x + i) * 0.05) * 3);
    const x2 = round(x + w - 9 + Math.sin((y + i) * 0.06) * 3);
    parts.push(path(wavyLine(x1, y1, x2, y1 + Math.sin(i) * 1.8, 5, 1.4), {
      stroke: color,
      width: 1.15,
      fill: "none",
      cap: "round",
      opacity: Math.min(0.22, opacity * 0.16),
    }));
  }
  return group(parts);
}

function circle(cx, cy, r, { fill = BRAND.cream, stroke = BRAND.ink, width = 2, opacity = 1 } = {}) {
  const filter = shouldTextureFill(fill) ? ` filter="url(#pencilTexture)"` : "";
  return `<circle cx="${round(cx)}" cy="${round(cy)}" r="${round(r)}" fill="${fill}" stroke="${stroke}" stroke-width="${width}" opacity="${opacity}"${filter}/>`;
}

function line(x1, y1, x2, y2, { stroke = BRAND.ink, width = 2, cap = "butt", opacity = 1 } = {}) {
  const base = `<line x1="${round(x1)}" y1="${round(y1)}" x2="${round(x2)}" y2="${round(y2)}" stroke="${stroke}" stroke-width="${width}" stroke-linecap="${cap}" opacity="${opacity}"/>`;
  const length = Math.hypot(x2 - x1, y2 - y1);
  if (width < 3 || opacity < 0.35 || length < 70) return base;
  const secondary = path(wavyLine(x1, y1 + 1.5, x2, y2 + 1.5, Math.max(4, Math.round(length / 130)), 1.3), {
    stroke,
    width: Math.max(1, width * 0.22),
    fill: "none",
    cap,
    opacity: Math.min(0.34, opacity * 0.32),
  });
  return group([base, secondary]);
}

function path(d, { fill = "none", stroke = BRAND.ink, width = 2, cap = "butt", opacity = 1, markerEnd = "" } = {}) {
  const marker = markerEnd ? ` marker-end="${markerEnd}"` : "";
  const filter = shouldTextureFill(fill) ? ` filter="url(#pencilTexture)"` : "";
  return `<path d="${d}" fill="${fill}" stroke="${stroke}" stroke-width="${width}" stroke-linecap="${cap}" stroke-linejoin="round" opacity="${opacity}"${marker}${filter}/>`;
}

function text(x, y, value, { size = 22, fill = BRAND.ink, weight = 600, mono = false, anchor = "start", rotate } = {}) {
  const family = mono ? "IBM Plex Mono, Menlo, monospace" : "Inter, Helvetica, sans-serif";
  const jitter = !mono && size >= 18 ? Math.sin(hashNumber(`${value}|${x}|${y}`) * 6.283) : 0;
  const finalY = y + jitter * 0.9;
  const finalRotate = rotate ?? (!mono && size >= 18 ? round(jitter * 0.85) : 0);
  const transform = finalRotate ? ` transform="rotate(${finalRotate} ${round(x)} ${round(finalY)})"` : "";
  return `<text x="${round(x)}" y="${round(finalY)}" fill="${fill}" font-family="${family}" font-size="${size}" font-weight="${weight}" text-anchor="${anchor}"${transform}>${escapeText(value)}</text>`;
}

function wrappedText(x, y, value, maxWidth, lineHeight, { size = 16, fill = BRAND.ink, weight = 600, mono = false, anchor = "middle" } = {}) {
  const approx = size * 0.55;
  const words = String(value).split(/\s+/);
  const lines = [];
  let current = "";
  for (const word of words) {
    const next = current ? `${current} ${word}` : word;
    if (next.length * approx > maxWidth && current) {
      lines.push(current);
      current = word;
    } else {
      current = next;
    }
  }
  if (current) lines.push(current);
  return group(lines.map((lineValue, index) => text(x, y + index * lineHeight, lineValue, { size, fill, weight, mono, anchor })));
}

function group(parts) {
  return `<g>${parts.filter(Boolean).join("")}</g>`;
}

function wavyLine(x1, y1, x2, y2, segments, amp) {
  const dx = (x2 - x1) / segments;
  const parts = [`M ${x1} ${y1}`];
  for (let i = 1; i <= segments; i += 1) {
    const x = x1 + dx * i;
    const y = y1 + Math.sin(i * 1.7) * amp;
    parts.push(`L ${round(x)} ${round(y)}`);
  }
  return parts.join(" ");
}

function qFill(q) {
  if (q < 24) return BRAND.cream;
  if (q < 31) return BRAND.peach;
  return BRAND.creamsicle;
}

function escapeText(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function round(value) {
  return Math.round(value * 10) / 10;
}

function shouldTextureFill(fill) {
  return String(fill).startsWith("#") && fill !== BRAND.cream;
}

function hashNumber(value) {
  let hash = 2166136261;
  for (const char of String(value)) {
    hash ^= char.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) / 4294967295;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const outArg = process.argv.find((arg) => arg.startsWith("--out-dir="));
  const outDir = outArg ? resolve(outArg.slice("--out-dir=".length)) : defaultOutDir();
  const outputs = await generateAll({ outDir });
  for (const output of outputs) {
    console.log(`${output.id}: ${output.png}`);
  }
}
