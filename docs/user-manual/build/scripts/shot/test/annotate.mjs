import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFile, readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { compose } from "../annotate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const solidPath = resolve(here, "fixtures", "solid.png");

test("annotate compose emits PNG with Creamsicle pixels near callout target", async () => {
  // 400x300 Cream background
  await sharp({
    create: { width: 400, height: 300, channels: 4, background: "#FAF4EA" }
  }).png().toFile(solidPath);

  const out = await compose({
    imagePath: solidPath,
    annotations: [
      { type: "bracket", region: [50, 50, 150, 150] },
      { type: "callout", target: [200, 100], text: "Here" },
    ],
  });

  const { data, info } = await sharp(out).raw().toBuffer({ resolveWithObject: true });
  // Scan for any Creamsicle pixel (#EE8B4F approx rgb(238,139,79))
  let found = false;
  for (let i = 0; i < data.length; i += info.channels) {
    if (Math.abs(data[i] - 238) < 6 && Math.abs(data[i+1] - 139) < 6 && Math.abs(data[i+2] - 79) < 6) {
      found = true; break;
    }
  }
  assert.equal(found, true, "expected Creamsicle pixels from the overlay");
});
