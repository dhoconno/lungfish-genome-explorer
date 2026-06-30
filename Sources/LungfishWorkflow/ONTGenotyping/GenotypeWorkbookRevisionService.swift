import Foundation
import LungfishIO

public enum GenotypeWorkbookRevisionError: Error, LocalizedError, Equatable, Sendable {
    case invalidWorkbook(String)
    case missingRevision(String)
    case missingCurrentWorkbook(String)
    case workbookOverrideFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkbook(let path):
            return "The selected file is not a readable .xlsx workbook: \(path)"
        case .missingRevision(let id):
            return "Workbook revision \(id) does not exist."
        case .missingCurrentWorkbook(let path):
            return "Current workbook does not exist: \(path)"
        case .workbookOverrideFailed(let message):
            return "Could not update current.xlsx from haplotype overrides: \(message)"
        }
    }
}

public struct GenotypeWorkbookHaplotypeCall: Codable, Equatable, Sendable {
    public let sample: String
    public let locus: String
    public let haplotype1: String
    public let haplotype2: String
    public let status: String
    public let notes: String

    public init(
        sample: String,
        locus: String,
        haplotype1: String,
        haplotype2: String,
        status: String,
        notes: String
    ) {
        self.sample = sample
        self.locus = locus
        self.haplotype1 = haplotype1
        self.haplotype2 = haplotype2
        self.status = status
        self.notes = notes
    }

    public static func isWritableCurrentWorkbookLocus(_ locus: String) -> Bool {
        switch canonicalCurrentWorkbookLocus(locus) {
        case "MHC-A", "MHC-B", "MHC-DQ", "MHC-DP":
            return true
        default:
            return false
        }
    }

    public static func canonicalCurrentWorkbookLocus(_ locus: String) -> String {
        let trimmed = locus.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "MHC-DQA" || trimmed == "MHC-DQB" {
            return "MHC-DQ"
        }
        if trimmed == "MHC-DPA" || trimmed == "MHC-DPB" {
            return "MHC-DP"
        }
        return trimmed
    }
}

public struct GenotypeWorkbookRevisionProvenanceContext: Equatable, Sendable {
    public let toolName: String
    public let toolKind: String
    public let argv: [String]
    public let durableReplayArgv: [String]

    public init(
        toolName: String,
        toolKind: String,
        argv: [String],
        durableReplayArgv: [String]? = nil
    ) {
        self.toolName = toolName
        self.toolKind = toolKind
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv ?? argv
    }
}

public struct GenotypeWorkbookRevisionService {
    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private let userProvider: @Sendable () -> String
    private let pythonExecutableURL: URL?

    public init(
        fileManager: FileManager = .default,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        userProvider: @escaping @Sendable () -> String = { NSUserName() },
        pythonExecutableURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.userProvider = userProvider
        self.pythonExecutableURL = pythonExecutableURL
    }

    public func ensureCurrentWorkbook(
        in bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        if let currentWorkbookPath = manifest.currentWorkbookPath {
            let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentWorkbookPath, in: bundle)
            if fileManager.fileExists(atPath: currentURL.path) {
                return manifest
            }
        }

        let primaryURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle)
        let currentURL = defaultCurrentWorkbookURL(in: bundle)
        try fileManager.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try replaceFile(at: currentURL, withCopyOf: primaryURL)

        let provenancePath = nextProvenancePath(action: "initial-current-copy", in: bundle)
        let revision = try makeRevision(
            role: .initialCurrentCopy,
            path: relativePath(from: bundle, to: currentURL),
            label: "Initial editable workbook",
            sourceFilename: primaryURL.lastPathComponent,
            predecessorID: nil,
            predecessorPath: relativePath(from: bundle, to: primaryURL),
            workbookURL: currentURL,
            provenancePath: provenancePath
        )
        let updated = manifestWithWorkbookFields(
            manifest,
            currentWorkbookPath: relativePath(from: bundle, to: currentURL),
            revisions: (manifest.workbookRevisions ?? []) + [revision]
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundle)
        try writeProvenance(
            action: "initial-current-copy",
            bundleURL: bundle,
            sourceWorkbookURL: primaryURL,
            previousCurrentURL: nil,
            snapshotURL: nil,
            importedSourceURL: nil,
            newCurrentURL: currentURL,
            manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
            provenancePath: provenancePath,
            startedAt: dateProvider(),
            additionalInputURLs: []
        )
        return updated
    }

    public func applyHaplotypeOverrides(
        _ calls: [GenotypeWorkbookHaplotypeCall],
        annotationSidecarURL: URL?,
        into bundleURL: URL,
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        _ = try ensureCurrentWorkbook(in: bundle)
        let currentURL = try ONTGenotypeResultBundle.currentWorkbookURL(for: bundle)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw GenotypeWorkbookRevisionError.missingCurrentWorkbook(currentURL.path)
        }

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LungfishCurrentWorkbookOverrides-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let callsURL = bundle
            .appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
            .appendingPathComponent("\(timestampSlug())-haplotype-calls-\(UUID().uuidString.prefix(8)).json")
        let patchedURL = bundle
            .appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
            .appendingPathComponent("\(timestampSlug())-current-overrides-\(UUID().uuidString.prefix(8)).xlsx")
        let scriptURL = tempDirectory.appendingPathComponent("apply-current-workbook-overrides.py")
        try fileManager.createDirectory(at: callsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(calls).write(to: callsURL)
        try workbookOverrideScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        var scriptArguments = [
            currentURL.path,
            patchedURL.path,
            callsURL.path,
        ]
        if let annotationSidecarURL, fileManager.fileExists(atPath: annotationSidecarURL.path) {
            scriptArguments.append(annotationSidecarURL.path)
        }
        try runPythonScript(scriptURL: scriptURL, arguments: scriptArguments)

        var additionalInputs = [callsURL]
        if let annotationSidecarURL, fileManager.fileExists(atPath: annotationSidecarURL.path) {
            additionalInputs.append(annotationSidecarURL)
        }
        return try importRevisedWorkbook(
            from: patchedURL,
            into: bundle,
            label: "Applied haplotype overrides",
            provenanceAction: "apply-haplotype-overrides",
            additionalInputURLs: additionalInputs,
            provenanceContext: provenanceContext
        )
    }

    public func importRevisedWorkbook(
        from sourceURL: URL,
        into bundleURL: URL,
        label: String? = nil,
        provenanceAction: String = "import",
        additionalInputURLs: [URL] = [],
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil
    ) throws -> ONTGenotypeResultBundleManifest {
        let source = sourceURL.standardizedFileURL
        try validateWorkbook(source)

        let bundle = bundleURL.standardizedFileURL
        let originalManifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        let originalCurrentData: Data?
        if let originalCurrentPath = originalManifest.currentWorkbookPath {
            originalCurrentData = try? Data(
                contentsOf: ONTGenotypeResultBundle.resolvedURL(for: originalCurrentPath, in: bundle)
            )
        } else {
            originalCurrentData = nil
        }
        let startedAt = dateProvider()
        var manifest = try ensureCurrentWorkbook(in: bundle)
        let currentPath = manifest.currentWorkbookPath ?? defaultCurrentWorkbookRelativePath
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw GenotypeWorkbookRevisionError.missingCurrentWorkbook(currentURL.path)
        }
        let previousCurrentRevision = latestCurrentWorkbookRevision(in: manifest)
        let provenancePath = nextProvenancePath(action: provenanceAction, in: bundle)

        do {
            let currentSHA256 = try ProvenanceFileHasher.sha256(of: currentURL)
            let snapshotRole: ONTGenotypeWorkbookRevisionRole = previousCurrentRevision?.sha256 == currentSHA256
                ? .externalEditSnapshot
                : .externalEditSnapshot
            let snapshotRevision = try snapshotCurrentWorkbook(
                currentURL: currentURL,
                bundleURL: bundle,
                label: previousCurrentRevision?.sha256 == currentSHA256
                    ? "Previous current workbook"
                    : "External workbook edit before import",
                role: snapshotRole,
                predecessor: previousCurrentRevision,
                provenancePath: provenancePath
            )
            try replaceFile(at: currentURL, withCopyOf: source)
            let importedRevision = try makeRevision(
                role: .imported,
                path: currentPath,
                label: normalizedLabel(label, fallback: "Imported workbook"),
                sourceFilename: source.lastPathComponent,
                predecessorID: snapshotRevision.id,
                predecessorPath: snapshotRevision.path,
                workbookURL: currentURL,
                provenancePath: provenancePath
            )
            manifest = manifestWithWorkbookFields(
                manifest,
                currentWorkbookPath: currentPath,
                revisions: (manifest.workbookRevisions ?? []) + [snapshotRevision, importedRevision]
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
            try writeProvenance(
                action: "import",
                bundleURL: bundle,
                sourceWorkbookURL: try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle),
                previousCurrentURL: currentURL,
                snapshotURL: ONTGenotypeResultBundle.resolvedURL(for: snapshotRevision.path, in: bundle),
                importedSourceURL: source,
                newCurrentURL: currentURL,
                manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
                provenancePath: provenancePath,
                startedAt: startedAt,
                additionalInputURLs: additionalInputURLs,
                provenanceContext: provenanceContext
            )
            return manifest
        } catch {
            if let originalCurrentData, let originalCurrentPath = originalManifest.currentWorkbookPath {
                let originalCurrentURL = ONTGenotypeResultBundle.resolvedURL(for: originalCurrentPath, in: bundle)
                try? fileManager.createDirectory(
                    at: originalCurrentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? originalCurrentData.write(to: originalCurrentURL, options: .atomic)
            } else if let originalCurrentData {
                try? originalCurrentData.write(to: currentURL, options: .atomic)
            } else if fileManager.fileExists(atPath: currentURL.path) && originalManifest.currentWorkbookPath == nil {
                try? fileManager.removeItem(at: currentURL)
            }
            try? ONTGenotypeResultBundle.writeManifest(originalManifest, to: bundle)
            throw error
        }
    }

    public func restoreWorkbookRevision(
        id revisionID: String,
        in bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        var manifest = try ensureCurrentWorkbook(in: bundle)
        guard let revision = manifest.workbookRevisions?.first(where: { $0.id == revisionID }) else {
            throw GenotypeWorkbookRevisionError.missingRevision(revisionID)
        }
        let sourceURL = ONTGenotypeResultBundle.resolvedURL(for: revision.path, in: bundle)
        try validateWorkbook(sourceURL)
        let currentPath = manifest.currentWorkbookPath ?? defaultCurrentWorkbookRelativePath
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
        let startedAt = dateProvider()
        let provenancePath = nextProvenancePath(action: "restore", in: bundle)
        let snapshotRevision = try snapshotCurrentWorkbook(
            currentURL: currentURL,
            bundleURL: bundle,
            label: "Previous current workbook before restore",
            role: .externalEditSnapshot,
            predecessor: latestCurrentWorkbookRevision(in: manifest),
            provenancePath: provenancePath
        )
        try replaceFile(at: currentURL, withCopyOf: sourceURL)
        let restoredRevision = try makeRevision(
            role: .restored,
            path: currentPath,
            label: "Restored \(revision.label)",
            sourceFilename: sourceURL.lastPathComponent,
            predecessorID: snapshotRevision.id,
            predecessorPath: snapshotRevision.path,
            workbookURL: currentURL,
            provenancePath: provenancePath
        )
        manifest = manifestWithWorkbookFields(
            manifest,
            currentWorkbookPath: currentPath,
            revisions: (manifest.workbookRevisions ?? []) + [snapshotRevision, restoredRevision]
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try writeProvenance(
            action: "restore",
            bundleURL: bundle,
            sourceWorkbookURL: try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle),
            previousCurrentURL: currentURL,
            snapshotURL: ONTGenotypeResultBundle.resolvedURL(for: snapshotRevision.path, in: bundle),
            importedSourceURL: sourceURL,
            newCurrentURL: currentURL,
            manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
            provenancePath: provenancePath,
            startedAt: startedAt,
            additionalInputURLs: []
        )
        return manifest
    }

    private func runPythonScript(scriptURL: URL, arguments: [String]) throws {
        let process = Process()
        if let pythonExecutableURL {
            process.executableURL = pythonExecutableURL
            process.arguments = [scriptURL.path] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path] + arguments
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? out.trimmingCharacters(in: .whitespacesAndNewlines)
                : err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GenotypeWorkbookRevisionError.workbookOverrideFailed(message)
        }
    }

    private var workbookOverrideScript: String {
        #"""
import json
import re
import sys
from copy import copy
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

input_path = sys.argv[1]
output_path = sys.argv[2]
calls_path = sys.argv[3]
sidecar_path = sys.argv[4] if len(sys.argv) > 4 else ""

with open(calls_path) as handle:
    call_rows = json.load(handle)

sidecar = {}
if sidecar_path:
    try:
        with open(sidecar_path) as handle:
            sidecar = json.load(handle)
    except FileNotFoundError:
        sidecar = {}

wb = load_workbook(input_path)

MCM_FAMILIES = ["M1", "M2", "M3", "M4", "M5", "M6", "M7"]
MCM_STYLES = {
    "M1": {"font": "000000"},
    "M2": {"font": "FF0000"},
    "M3": {"font": "0432FF"},
    "M4": {"font": "00B050"},
    "M5": {"font": "FFC000"},
    "M6": {"font": "595959"},
    "M7": {"font": "7030A0"},
}
SUMMARY_LOCI = [
    ("MHC-A", "MHC-A"),
    ("MHC-B", "MHC-B"),
    ("MHC-DQ", "MHC-DQA/B"),
    ("MHC-DP", "MHC-DPA/B"),
]
FULL_LOCI = ["MHC-A", "MHC-B", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
WRITABLE_LOCI = {"MHC-A", "MHC-B", "MHC-DQ", "MHC-DP"}


def clean(value):
    if value is None:
        return ""
    return str(value).strip()


def family(value):
    text = clean(value)
    if not text or text == "-" or text.startswith("ERR"):
        return None
    match = re.search(r"\b(M[1-7])", text)
    return match.group(1) if match else None


def display_family(value):
    return family(value) or clean(value) or "?"


def canonical_locus(locus):
    text = clean(locus)
    if text in ("MHC-DQA", "MHC-DQB"):
        return "MHC-DQ"
    if text in ("MHC-DPA", "MHC-DPB"):
        return "MHC-DP"
    return text


calls_by_sample_locus = {}
for call in call_rows:
    sample = clean(call.get("sample"))
    locus = canonical_locus(call.get("locus"))
    if not sample or not locus:
        continue
    if locus not in WRITABLE_LOCI:
        continue
    calls_by_sample_locus.setdefault(sample, {})[locus] = {
        "haplotype1": clean(call.get("haplotype1")),
        "haplotype2": clean(call.get("haplotype2")),
        "status": clean(call.get("status")),
        "notes": clean(call.get("notes")),
    }

call_overrides = sidecar.get("callOverrides") or []
audit_entries = sidecar.get("auditLog") or []
matrix_styles = sidecar.get("matrixStyles") or []
matrix_comments = sidecar.get("matrixComments") or []


def call_for(sample, locus):
    return calls_by_sample_locus.get(sample, {}).get(canonical_locus(locus), {})


def call_value(sample, locus, index):
    call = call_for(sample, locus)
    key = "haplotype1" if index == 1 else "haplotype2"
    value = call.get(key, "")
    if index == 2 and (not value or value == "-"):
        inferred = inferred_homozygous_family(sample)
        first = call.get("haplotype1", "")
        if inferred and family(first) == inferred:
            return first
    return value or "-"


def inferred_homozygous_family(sample):
    families = []
    for locus in [item[0] for item in SUMMARY_LOCI]:
        call = call_for(sample, locus)
        if not call:
            continue
        first = call.get("haplotype1", "")
        second = call.get("haplotype2", "")
        first_family = family(first)
        second_family = family(second)
        if first_family:
            families.append(first_family)
            if not second_family:
                continue
        if second_family:
            families.append(second_family)
    unique = []
    for item in families:
        if item not in unique:
            unique.append(item)
    return unique[0] if len(unique) == 1 else None


def whole_animal(sample, index):
    families = []
    for locus, _label in SUMMARY_LOCI:
        value = call_value(sample, locus, index)
        item = family(value)
        if item and item not in families:
            families.append(item)
    if not families:
        return "?"
    if len(families) == 1:
        return families[0]
    return "rec" + "".join(families)


def comments(sample):
    values = []
    for locus in sorted(calls_by_sample_locus.get(sample, {})):
        call = call_for(sample, locus)
        status = call.get("status", "")
        note = call.get("notes", "")
        h1 = call.get("haplotype1", "")
        h2 = call.get("haplotype2", "")
        if h1.startswith("ERR") or h2.startswith("ERR"):
            values.append(f"{locus}: {h1}/{h2}".strip("/"))
        elif status and status != "called":
            values.append(f"{locus}: {status}")
        if note:
            values.append(f"{locus}: {note}")
    return "; ".join(values) or None


def header_map(ws):
    values = {}
    for col in range(1, ws.max_column + 1):
        value = ws.cell(1, col).value
        if value is not None:
            values[str(value)] = col
    return values


def sample_row(ws, sample):
    for row in range(1, ws.max_row + 1):
        if clean(ws.cell(row, 1).value) == sample:
            return row
    return None


def sample_col(ws, sample):
    for col in range(1, ws.max_column + 1):
        for row in range(1, min(ws.max_row, 4) + 1):
            if clean(ws.cell(row, col).value) == sample:
                return col
    return None


def row_for(ws, label):
    for row in range(1, ws.max_row + 1):
        if clean(ws.cell(row, 1).value) == label:
            return row
    return None


def clear_fill(cell):
    cell.fill = PatternFill(fill_type=None)


def style_haplotype(cell, value):
    clear_fill(cell)
    item = family(value)
    if item:
        cell.font = Font(name="Calibri", size=11, color=MCM_STYLES[item]["font"], bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center")
    elif clean(value).startswith("ERR"):
        cell.font = Font(name="Calibri", size=11, color="9C0006", bold=True)
        cell.alignment = Alignment(horizontal="center", vertical="center")
    else:
        cell.font = Font(name="Calibri", size=11)


def set_cell(cell, value):
    cell.value = value
    style_haplotype(cell, value)


def patch_summary_sheet(sheet_name):
    if sheet_name not in wb.sheetnames:
        return
    ws = wb[sheet_name]
    headers = header_map(ws)
    for sample in calls_by_sample_locus:
        row = sample_row(ws, sample)
        if row is None:
            continue
        if "Haplotype 1" in headers:
            set_cell(ws.cell(row, headers["Haplotype 1"]), whole_animal(sample, 1))
        if "Haplotype 2" in headers:
            set_cell(ws.cell(row, headers["Haplotype 2"]), whole_animal(sample, 2))
        for locus, label in SUMMARY_LOCI:
            h1_header = f"{label} Haplotype 1"
            h2_header = f"{label} Haplotype 2"
            if h1_header in headers:
                set_cell(ws.cell(row, headers[h1_header]), call_value(sample, locus, 1))
            if h2_header in headers:
                set_cell(ws.cell(row, headers[h2_header]), call_value(sample, locus, 2))
        if "Comments" in headers:
            ws.cell(row, headers["Comments"]).value = comments(sample)


def patch_full_sheet():
    if "Full Sequencing Results 1" not in wb.sheetnames:
        return
    ws = wb["Full Sequencing Results 1"]
    for sample in calls_by_sample_locus:
        col = sample_col(ws, sample)
        if col is None:
            continue
        for locus in FULL_LOCI:
            for index in (1, 2):
                row = row_for(ws, f"{locus} Haplotype {index}")
                if row is not None:
                    set_cell(ws.cell(row, col), call_value(sample, locus, index))
        comment_row = row_for(ws, "Comments")
        if comment_row is not None:
            ws.cell(comment_row, col).value = comments(sample)


def upsert_guide_row(label, value):
    if "Interpretation Guide" not in wb.sheetnames:
        ws = wb.create_sheet("Interpretation Guide", 0)
        ws.append(["Field", "Interpretation"])
    ws = wb["Interpretation Guide"]
    target = row_for(ws, label)
    if target is None:
        target = ws.max_row + 1
    ws.cell(target, 1).value = label
    ws.cell(target, 2).value = value
    ws.cell(target, 1).font = Font(name="Calibri", size=11, bold=True)
    ws.cell(target, 2).font = Font(name="Calibri", size=11)


def replace_sheet(name):
    if name in wb.sheetnames:
        del wb[name]
    return wb.create_sheet(name)


def style_table_header(ws):
    fill = PatternFill(fill_type="solid", fgColor="D9EAF7")
    for cell in ws[1]:
        cell.font = Font(name="Calibri", size=11, bold=True)
        cell.fill = fill
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def style_table_body(ws):
    for row in ws.iter_rows(min_row=2):
        for cell in row:
            cell.font = Font(name="Calibri", size=11)
            cell.alignment = Alignment(vertical="top", wrap_text=True)


def autosize_columns(ws, max_width=64):
    for column_cells in ws.columns:
        width = 10
        for cell in column_cells:
            value = clean(cell.value)
            if value:
                width = max(width, min(max_width, len(value) + 2))
        ws.column_dimensions[column_cells[0].column_letter].width = width


def write_table_sheet(name, headers, rows):
    ws = replace_sheet(name)
    ws.append(headers)
    for row in rows:
        ws.append(row)
    style_table_header(ws)
    style_table_body(ws)
    autosize_columns(ws)
    ws.freeze_panes = "A2"


def write_override_sheets():
    override_headers = [
        "Sample",
        "Locus",
        "Slot",
        "Original Call",
        "Override Call",
        "Reason",
        "Rationale",
        "Author",
        "Timestamp",
    ]
    override_rows = []
    for entry in call_overrides:
        override_rows.append([
            clean(entry.get("sample")),
            clean(entry.get("locus")),
            clean(entry.get("slot")),
            clean(entry.get("originalCall")),
            clean(entry.get("overrideCall")),
            clean(entry.get("reasonTag")),
            clean(entry.get("rationale")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
        ])
    write_table_sheet("Overrides", override_headers, override_rows)

    audit_headers = [
        "Action",
        "Sample",
        "Locus",
        "Slot",
        "Before",
        "After",
        "Reason",
        "Rationale",
        "Author",
        "Timestamp",
    ]
    audit_rows = []
    for entry in audit_entries:
        audit_rows.append([
            clean(entry.get("action")),
            clean(entry.get("sample")),
            clean(entry.get("locus")),
            clean(entry.get("slot")),
            clean(entry.get("before")),
            clean(entry.get("after")),
            clean(entry.get("reason")),
            clean(entry.get("rationale")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
        ])
    write_table_sheet("Audit Log", audit_headers, audit_rows)


def matrix_target_parts(target):
    target = target or {}
    return (
        clean(target.get("kind")),
        clean(target.get("locus")),
        clean(target.get("genotype")),
        clean(target.get("sample")),
    )


def write_matrix_annotation_sheet():
    rows = []
    for entry in matrix_styles:
        target = entry.get("target") or {}
        kind, locus, genotype, sample = matrix_target_parts(target)
        style = entry.get("style") or {}
        rows.append([
            "style",
            kind,
            locus,
            genotype,
            sample,
            clean(style.get("fillColor")),
            clean(style.get("textColor")),
            clean(style.get("borderColor")),
            display_bool(style.get("isBold"), style.get("boldOverride")),
            display_bool(style.get("isItalic"), style.get("italicOverride")),
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            "",
        ])
    for entry in matrix_comments:
        target = entry.get("target") or {}
        kind, locus, genotype, sample = matrix_target_parts(target)
        rows.append([
            "comment",
            kind,
            locus,
            genotype,
            sample,
            "",
            "",
            "",
            "",
            "",
            clean(entry.get("author")),
            clean(entry.get("timestamp")),
            clean(entry.get("body")),
        ])
    if not rows:
        return
    write_table_sheet(
        "Matrix Annotations",
        [
            "Entry Type",
            "Target Kind",
            "Locus",
            "Genotype",
            "Sample",
            "Fill Color",
            "Text Color",
            "Border Color",
            "Bold",
            "Italic",
            "Author",
            "Timestamp",
            "Comment",
        ],
        rows,
    )


def display_bool(value, override):
    if override is not None:
        return str(bool(override)).lower()
    if value is None:
        return ""
    return str(bool(value)).lower()


def normalize_hex(value):
    text = clean(value).lstrip("#")
    if len(text) == 6 and all(char in "0123456789abcdefABCDEF" for char in text):
        return "FF" + text.upper()
    if len(text) == 8 and all(char in "0123456789abcdefABCDEF" for char in text):
        return text.upper()
    return None


def apply_matrix_style(cell, style):
    if not style:
        return
    font = copy(cell.font)
    text_color = normalize_hex(style.get("textColor"))
    if text_color:
        font.color = text_color
    if style.get("boldOverride") is not None:
        font.bold = bool(style.get("boldOverride"))
    elif style.get("isBold"):
        font.bold = True
    if style.get("italicOverride") is not None:
        font.italic = bool(style.get("italicOverride"))
    elif style.get("isItalic"):
        font.italic = True
    cell.font = font

    fill_color = normalize_hex(style.get("fillColor"))
    if fill_color:
        cell.fill = PatternFill(fill_type="solid", fgColor=fill_color)

    border_color = normalize_hex(style.get("borderColor"))
    if border_color:
        side = Side(style="thin", color=border_color)
        cell.border = Border(left=side, right=side, top=side, bottom=side)


def collect_matrix_style_maps():
    row_styles = {}
    column_styles = {}
    cell_styles = {}
    for entry in matrix_styles:
        target = entry.get("target") or {}
        style = entry.get("style") or {}
        kind, locus, genotype, sample = matrix_target_parts(target)
        if kind == "row" and genotype:
            row_styles[(locus, genotype)] = style
        elif kind == "column" and sample:
            column_styles[sample] = style
        elif kind == "cell" and genotype and sample:
            cell_styles[(locus, genotype, sample)] = style
    return row_styles, column_styles, cell_styles


def collect_matrix_comment_maps():
    row_comments = {}
    column_comments = {}
    cell_comments = {}
    for entry in matrix_comments:
        target = entry.get("target") or {}
        body = clean(entry.get("body"))
        if not body:
            continue
        author = clean(entry.get("author")) or "Lungfish"
        timestamp = clean(entry.get("timestamp"))
        line = f"{body} ({author}{', ' + timestamp if timestamp else ''})"
        kind, locus, genotype, sample = matrix_target_parts(target)
        if kind == "row" and genotype:
            row_comments.setdefault((locus, genotype), []).append(line)
        elif kind == "column" and sample:
            column_comments.setdefault(sample, []).append(line)
        elif kind == "cell" and genotype and sample:
            cell_comments.setdefault((locus, genotype, sample), []).append(line)
    return row_comments, column_comments, cell_comments


def known_matrix_samples():
    names = set(calls_by_sample_locus.keys())
    for entry in matrix_styles + matrix_comments:
        _kind, _locus, _genotype, sample = matrix_target_parts(entry.get("target") or {})
        if sample:
            names.add(sample)
    return names


def sample_columns_for_matrix(ws, sample_names):
    columns = {}
    if sample_names:
        for row in range(1, min(ws.max_row, 25) + 1):
            for col in range(1, ws.max_column + 1):
                value = clean(ws.cell(row, col).value)
                if value in sample_names and value not in columns:
                    columns[value] = (col, row)
        return columns

    for row in range(1, min(ws.max_row, 25) + 1):
        row_label = clean(ws.cell(row, 1).value).lower()
        if row_label not in {"animal id", "gs id", "genotype"}:
            continue
        for col in range(4, ws.max_column + 1):
            value = clean(ws.cell(row, col).value)
            if value and value not in columns:
                columns[value] = (col, row)
    return columns


def genotype_rows_for_matrix(ws):
    rows = {}
    for row in range(1, ws.max_row + 1):
        value = clean(ws.cell(row, 1).value)
        if value:
            rows.setdefault(value, []).append(row)
    return rows


def style_for_matrix_cell(genotype, sample, row_styles, column_styles, cell_styles):
    styles = []
    for (_locus, style_genotype), style in row_styles.items():
        if style_genotype == genotype:
            styles.append(style)
    if sample in column_styles:
        styles.append(column_styles[sample])
    for (_locus, style_genotype, style_sample), style in cell_styles.items():
        if style_genotype == genotype and style_sample == sample:
            styles.append(style)
    return styles


def append_lge_comment(pending, cell, lines):
    if lines:
        pending.setdefault(cell.coordinate, (cell, []))[1].extend(lines)


def set_lge_comments(comment_targets):
    marker = "[LGE Matrix Comments]"
    for cell, lines in comment_targets.values():
        unique = []
        for line in lines:
            if line and line not in unique:
                unique.append(line)
        existing = cell.comment.text if cell.comment else ""
        base = existing.split(marker, 1)[0].rstrip()
        lge_text = marker + "\n" + "\n".join(unique) if unique else ""
        combined = "\n\n".join(part for part in [base, lge_text] if part)
        cell.comment = Comment(combined, "Lungfish") if combined else None


def apply_matrix_annotations_to_workbook():
    if not matrix_styles and not matrix_comments:
        return
    row_styles, column_styles, cell_styles = collect_matrix_style_maps()
    row_comments, column_comments, cell_comments = collect_matrix_comment_maps()
    sample_names = known_matrix_samples()
    for ws in wb.worksheets:
        if ws.title in {"Matrix Annotations", "Overrides", "Audit Log"}:
            continue
        sample_columns = sample_columns_for_matrix(ws, sample_names)
        genotype_rows = genotype_rows_for_matrix(ws)
        if not sample_columns or not genotype_rows:
            continue

        pending_comments = {}
        for sample, (col, header_row) in sample_columns.items():
            append_lge_comment(pending_comments, ws.cell(header_row, col), column_comments.get(sample, []))

        target_genotypes = {
            genotype
            for _locus, genotype in list(row_styles.keys()) + list(row_comments.keys())
            if genotype
        }
        target_genotypes.update(
            genotype
            for _locus, genotype, _sample in list(cell_styles.keys()) + list(cell_comments.keys())
            if genotype
        )
        for genotype in target_genotypes:
            for row in genotype_rows.get(genotype, []):
                label_cell = ws.cell(row, 1)
                for (locus, row_genotype), lines in row_comments.items():
                    if row_genotype == genotype:
                        append_lge_comment(pending_comments, label_cell, lines)
                for sample, (col, _header_row) in sample_columns.items():
                    cell = ws.cell(row, col)
                    for style in style_for_matrix_cell(genotype, sample, row_styles, column_styles, cell_styles):
                        apply_matrix_style(cell, style)
                    for (locus, cell_genotype, cell_sample), lines in cell_comments.items():
                        if cell_genotype == genotype and cell_sample == sample:
                            append_lge_comment(pending_comments, cell, lines)

        set_lge_comments(pending_comments)


patch_summary_sheet("Abbreviated Haplotypes")
patch_summary_sheet("Custom Sort")
patch_full_sheet()
write_override_sheets()
write_matrix_annotation_sheet()
apply_matrix_annotations_to_workbook()
upsert_guide_row("Workbook update source", "Lungfish.app Review viewport")
upsert_guide_row("Workbook update note", "current.xlsx reflects sidecar haplotype overrides at the time this workbook revision was created.")
upsert_guide_row("Workbook updated haplotype calls", str(sum(len(calls) for calls in calls_by_sample_locus.values())))
upsert_guide_row("Workbook update overrides", str(len(call_overrides)))
upsert_guide_row("Workbook update matrix styles", str(len(matrix_styles)))
upsert_guide_row("Workbook update matrix comments", str(len(matrix_comments)))
upsert_guide_row("Workbook update audit entries", str(len(audit_entries)))
upsert_guide_row("Workbook update audit source", "annotations.json")

wb.save(output_path)
"""#
    }

    private var defaultCurrentWorkbookRelativePath: String {
        "artifacts/workbooks/current.xlsx"
    }

    private func defaultCurrentWorkbookURL(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    private func snapshotCurrentWorkbook(
        currentURL: URL,
        bundleURL: URL,
        label: String,
        role: ONTGenotypeWorkbookRevisionRole,
        predecessor: ONTGenotypeWorkbookRevision?,
        provenancePath: String
    ) throws -> ONTGenotypeWorkbookRevision {
        let snapshotURL = revisionsDirectory(in: bundleURL)
            .appendingPathComponent("\(timestampSlug())-\(safeFilenameStem(label))-\(UUID().uuidString.prefix(8)).xlsx")
        try fileManager.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: currentURL, to: snapshotURL)
        return try makeRevision(
            role: role,
            path: relativePath(from: bundleURL, to: snapshotURL),
            label: label,
            sourceFilename: currentURL.lastPathComponent,
            predecessorID: predecessor?.id,
            predecessorPath: predecessor?.path,
            workbookURL: snapshotURL,
            provenancePath: provenancePath
        )
    }

    private func makeRevision(
        role: ONTGenotypeWorkbookRevisionRole,
        path: String,
        label: String,
        sourceFilename: String?,
        predecessorID: String?,
        predecessorPath: String?,
        workbookURL: URL,
        provenancePath: String?
    ) throws -> ONTGenotypeWorkbookRevision {
        ONTGenotypeWorkbookRevision(
            id: "\(role.rawValue)-\(UUID().uuidString)",
            role: role,
            path: path,
            label: label,
            sourceFilename: sourceFilename,
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            user: userProvider(),
            predecessorID: predecessorID,
            predecessorPath: predecessorPath,
            sha256: try ProvenanceFileHasher.sha256(of: workbookURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: workbookURL)),
            provenancePath: provenancePath
        )
    }

    private func writeProvenance(
        action: String,
        bundleURL: URL,
        sourceWorkbookURL: URL,
        previousCurrentURL: URL?,
        snapshotURL: URL?,
        importedSourceURL: URL?,
        newCurrentURL: URL,
        manifestURL: URL,
        provenancePath: String,
        startedAt: Date,
        additionalInputURLs: [URL],
        provenanceContext: GenotypeWorkbookRevisionProvenanceContext? = nil
    ) throws {
        let completedAt = dateProvider()
        let inputURLs = ([sourceWorkbookURL, previousCurrentURL, importedSourceURL].compactMap { $0 } + additionalInputURLs)
        let outputURLs = [snapshotURL, newCurrentURL, manifestURL].compactMap { $0 }
        let inputs = try inputURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .input) }
        let outputs = try outputURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .output) }
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: bundleURL)
        let provenanceDescriptor = ProvenanceFileDescriptor(path: provenanceURL.path, role: .log)
        let defaultArgv = [
            "Lungfish.app",
            "genotype-workbook",
            action,
            "--bundle", bundleURL.path,
            "--current-workbook", newCurrentURL.path,
        ]
        let argv = provenanceContext?.argv ?? defaultArgv
        let durableReplayArgv = provenanceContext?.durableReplayArgv ?? argv
        let toolName = provenanceContext?.toolName ?? "Lungfish.app"
        let toolKind = provenanceContext?.toolKind ?? "app"
        var explicitOptions: [String: ParameterValue] = [
            "action": .string(action),
            "bundle": .file(bundleURL),
            "currentWorkbook": .file(newCurrentURL),
        ]
        if !additionalInputURLs.isEmpty {
            explicitOptions["additionalInputs"] = .array(additionalInputURLs.map { .file($0) })
        }
        let envelope = ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: "Genotype Workbook Revision",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: toolName, version: WorkflowRun.currentAppVersion, kind: toolKind),
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            options: ProvenanceOptions(
                explicit: explicitOptions,
                resolvedDefaults: [
                    "currentWorkbookPath": .string(defaultCurrentWorkbookRelativePath),
                    "historyDirectory": .string("artifacts/workbooks/revisions"),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputs + outputs + [provenanceDescriptor],
            output: ProvenanceFileDescriptor(path: bundleURL.path, role: .output),
            outputs: outputs + [provenanceDescriptor],
            steps: [
                ProvenanceStep(
                    toolName: "\(toolName) genotype workbook \(action)",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    inputs: inputs,
                    outputs: outputs,
                    exitStatus: 0,
                    wallTimeSeconds: completedAt.timeIntervalSince(startedAt)
                )
            ],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
    }

    private func validateWorkbook(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "xlsx",
              let handle = try? FileHandle(forReadingFrom: url) else {
            throw GenotypeWorkbookRevisionError.invalidWorkbook(url.path)
        }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        guard magic == Data([0x50, 0x4b, 0x03, 0x04])
            || magic == Data([0x50, 0x4b, 0x05, 0x06])
            || magic == Data([0x50, 0x4b, 0x07, 0x08]) else {
            throw GenotypeWorkbookRevisionError.invalidWorkbook(url.path)
        }
    }

    private func replaceFile(at destinationURL: URL, withCopyOf sourceURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func manifestWithWorkbookFields(
        _ manifest: ONTGenotypeResultBundleManifest,
        currentWorkbookPath: String,
        revisions: [ONTGenotypeWorkbookRevision]
    ) -> ONTGenotypeResultBundleManifest {
        ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt,
            activeHaplotypeAnalysisRevisionID: manifest.activeHaplotypeAnalysisRevisionID,
            haplotypeAnalysisRevisions: manifest.haplotypeAnalysisRevisions
        )
    }

    private func latestCurrentWorkbookRevision(
        in manifest: ONTGenotypeResultBundleManifest
    ) -> ONTGenotypeWorkbookRevision? {
        guard let currentPath = manifest.currentWorkbookPath else { return nil }
        return manifest.workbookRevisions?.last { $0.path == currentPath }
    }

    private func revisionsDirectory(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("artifacts/workbooks/revisions", isDirectory: true)
    }

    private func nextProvenancePath(action: String, in bundleURL: URL) -> String {
        let url = bundleURL
            .appendingPathComponent("artifacts/workbooks/provenance", isDirectory: true)
            .appendingPathComponent("\(timestampSlug())-\(safeFilenameStem(action))-\(UUID().uuidString.prefix(8)).lungfish-provenance.json")
        return relativePath(from: bundleURL, to: url)
    }

    private func timestampSlug() -> String {
        ISO8601DateFormatter()
            .string(from: dateProvider())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func normalizedLabel(_ label: String?, fallback: String) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func safeFilenameStem(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workbook" : collapsed
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }
}
