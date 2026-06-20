import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const files = process.argv.slice(2);
if (files.length === 0) {
  throw new Error("Usage: node verify_haplotyping_workbooks.mjs <workbook.xlsx> [...]");
}

const result = [];
for (const file of files) {
  const blob = await FileBlob.load(file);
  const workbook = await SpreadsheetFile.importXlsx(blob);
  const sheets = await workbook.inspect({ kind: "sheet", include: "id,name", maxChars: 2000 });
  const errors = await workbook.inspect({
    kind: "match",
    searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
    options: { useRegex: true, maxResults: 100 },
    maxChars: 3000,
  });
  const record = {
    file,
    sizeBytes: (await fs.stat(file)).size,
    sheets: sheets.ndjson,
    formulaErrors: errors.ndjson,
  };

  if (path.basename(file).includes("unresolved-inspection")) {
    record.summaryPreview = (await workbook.inspect({
      kind: "table",
      range: "Summary!A1:C30",
      include: "values,formulas",
      tableMaxRows: 30,
      tableMaxCols: 4,
      maxChars: 5000,
    })).ndjson;
    record.detailPreview = (await workbook.inspect({
      kind: "table",
      range: "Unresolved AI Review!A1:L12",
      include: "values,formulas",
      tableMaxRows: 12,
      tableMaxCols: 12,
      tableMaxCellChars: 80,
      maxChars: 7000,
    })).ndjson;
    const preview = await workbook.render({ sheetName: "Unresolved AI Review", range: "A1:L16", scale: 1, format: "png" });
    const previewBytes = new Uint8Array(await preview.arrayBuffer());
    const previewPath = `${file}.preview.png`;
    await fs.writeFile(previewPath, previewBytes);
    record.previewPath = previewPath;
    record.previewBytes = previewBytes.length;
  }
  result.push(record);
}

console.log(JSON.stringify(result, null, 2));
