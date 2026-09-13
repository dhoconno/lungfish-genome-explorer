#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';

const root = process.argv[2];
if (!root) {
  console.error('usage: source-tree-witness.mjs <directory>');
  process.exit(2);
}

const files = [];
async function walk(relative = '') {
  const entries = await fs.readdir(path.join(root, relative), { withFileTypes: true });
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const name = path.join(relative, entry.name);
    if (entry.isSymbolicLink()) {
      files.push({ path: name, link: await fs.readlink(path.join(root, name)) });
    } else if (entry.isDirectory()) {
      await walk(name);
    } else if (entry.isFile()) {
      const bytes = await fs.readFile(path.join(root, name));
      files.push({
        path: name,
        size: bytes.length,
        sha256: createHash('sha256').update(bytes).digest('hex'),
      });
    }
  }
}

await walk();
console.log(JSON.stringify({
  root,
  files,
  treeSHA256: createHash('sha256').update(JSON.stringify(files)).digest('hex'),
}, null, 2));
