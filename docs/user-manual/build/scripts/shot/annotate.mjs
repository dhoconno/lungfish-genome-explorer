import sharp from "sharp";
import { readFile } from "node:fs/promises";

const CREAMSICLE = "#EE8B4F";
const DEEP_INK = "#1F1A17";

export async function compose({ imagePath, annotations }) {
  const img = sharp(await readFile(imagePath));
  const { width, height } = await img.metadata();
  const svg = buildSVG({ width, height, annotations });
  return img.composite([{ input: Buffer.from(svg), top: 0, left: 0 }]).png().toBuffer();
}

function buildSVG({ width, height, annotations }) {
  const parts = [];
  for (const a of annotations) {
    if (a.type === "bracket" && a.region) {
      const [x, y, w, h] = a.region;
      parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="none" stroke="${CREAMSICLE}" stroke-width="2" rx="4"/>`);
    } else if (a.type === "box" && a.region) {
      const [x, y, w, h] = a.region;
      parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="none" stroke="${CREAMSICLE}" stroke-width="2"/>`);
    } else if (a.type === "callout" && a.target) {
      const [tx, ty] = a.target;
      const text = escapeXml(a.text ?? "");
      parts.push(`<circle cx="${tx}" cy="${ty}" r="6" fill="${CREAMSICLE}"/>`);
      parts.push(`<text x="${tx + 12}" y="${ty + 4}" fill="${DEEP_INK}" font-family="Inter" font-size="14" font-weight="600">${text}</text>`);
    } else if (a.type === "arrow" && a.from && a.to) {
      const [x1, y1] = a.from;
      const [x2, y2] = a.to;
      parts.push(`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${CREAMSICLE}" stroke-width="2"/>`);
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${parts.join("")}</svg>`;
}

function escapeXml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
