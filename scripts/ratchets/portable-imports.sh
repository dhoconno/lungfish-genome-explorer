#!/usr/bin/env python3
"""portable-imports.sh - Ratchet on what the portable layer and the Linux executor may name (CHTC program C3, lane K1).

LungfishPortable (Sources/LungfishPortable), the Linux executor LungfishExecutor (Sources/LungfishExecutor) and its C
wrapper CLungfishExecutor (Sources/CLungfishExecutor) build for macOS and for static Linux. So they import no
Apple-only module, read no bundle and no host probe, and know no scheduler. The executor resolves every path under the
plan file's folder, and HTCondor facts reach its run record only as --site-fact arguments. Counts:
    forbidden_imports     imports in the scanned Swift files of Darwin, os, os.log, CryptoKit, Compression,
                          Security, MachO, AppKit or SQLite3 outside an #if block
    forbidden_tokens      code lines, outside comments, of the scanned Swift and C files that hold Bundle.main,
                          Bundle.module, #filePath, physicalMemory, activeProcessorCount, host_statistics64,
                          LUNGFISH_, _CONDOR_, condor_, HTCondor, ClassAd, APPTAINER_ or SINGULARITY_. Tokens match
                          case-sensitively, so lungfish_set_child_subreaper passes
    executor_dependents   targets other than LungfishExecutorTests whose dependencies name LungfishExecutor, products
                          other than .executable(name: "lungfish-executor", targets: ["LungfishExecutor"]) whose
                          targets name it, and Swift files outside Sources/LungfishExecutor/ and
                          Tests/LungfishExecutorTests/ that import it
    c_targets             targets whose folder holds a .c, .h, .m, .mm, .cc or .cpp file or a module.modulemap,
                          plus each .systemLibrary( or .binaryTarget( call in the manifest
    c_target_dependents   targets other than LungfishExecutor whose dependencies name CLungfishExecutor, and Swift
                          files under Sources/ or Tests/ other than Sources/LungfishExecutor/Process/ChildSubreaper.swift
                          that hold import CLungfishExecutor outside a comment
Each count may only fall. Besides the counts the script fails when Sources/CLungfishExecutor/ holds any file other
than include/CLungfishExecutor.h and ChildSubreaper.c, when the header declares anything but the two subreaper
functions, or when the target's manifest call carries any argument beyond its name and path. The posix_spawn rule
belongs to scripts/ratchets/process-spawn.sh, so one ratchet owns spawning. Targets are read with parse_package of
scripts/index/generate-module-map.py.

Baseline file: one "<name> <count>" line per count.

Usage:
    scripts/ratchets/portable-imports.sh                    # check against the recorded baseline
    scripts/ratchets/portable-imports.sh --print            # print each site and the counts, no pass/fail
    scripts/ratchets/portable-imports.sh --update           # rewrite the baseline to the current counts
                                                              (only to lower it)
    --root <path>       the repository root to scan, by default this checkout
    --manifest <path>   the Package.swift to read, by default <root>/Package.swift

Exit codes: 0 = every count at or under baseline and the C folder as named, 1 otherwise.
"""
import importlib.util
import re
import sys
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parents[2]
BASELINE_FILE = Path(__file__).resolve().with_suffix(".baseline")
GENERATOR_PATH = SCRIPT_ROOT / "scripts/index/generate-module-map.py"

SCANNED = ("Sources/LungfishPortable", "Sources/LungfishExecutor", "Sources/CLungfishExecutor")
FORBIDDEN_MODULES = ("Darwin", "os", "os.log", "CryptoKit", "Compression", "Security", "MachO", "AppKit", "SQLite3")
TOKENS = (
    "Bundle.main", "Bundle.module", "#filePath", "physicalMemory", "activeProcessorCount", "host_statistics64",
    "LUNGFISH_", "_CONDOR_", "condor_", "HTCondor", "ClassAd", "APPTAINER_", "SINGULARITY_",
)
C_SUFFIXES = (".c", ".h", ".m", ".mm", ".cc", ".cpp")

EXECUTOR = "LungfishExecutor"
EXECUTOR_TESTS = "LungfishExecutorTests"
EXECUTOR_PRODUCT = ("executable", "lungfish-executor", [EXECUTOR])
C_TARGET = "CLungfishExecutor"
C_DIR = "Sources/CLungfishExecutor"
C_FILES = ("ChildSubreaper.c", "include/CLungfishExecutor.h")
C_HEADER = "include/CLungfishExecutor.h"
C_DECLARATIONS = ("int lungfish_set_child_subreaper(void);", "int lungfish_get_child_subreaper(int *out);")
C_CALLER = "Sources/LungfishExecutor/Process/ChildSubreaper.swift"
C_REFUSED_ARGUMENTS = (
    "dependencies", "exclude", "sources", "resources", "publicHeadersPath", "cSettings", "cxxSettings",
    "swiftSettings", "linkerSettings", "plugins",
)

IMPORT_RX = re.compile(
    r"^\s*(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)*import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][\w.]*)"
)
TARGET_CALL_RX = re.compile(r"\.(target|testTarget|executableTarget)\s*\(")
PRODUCT_CALL_RX = re.compile(r"\.(library|executable)\s*\(")
SYSTEM_CALL_RX = re.compile(r"\.(systemLibrary|binaryTarget)\s*\(")

NAMES = ("forbidden_imports", "forbidden_tokens", "executor_dependents", "c_targets", "c_target_dependents")


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_module_map_for_portable_imports", GENERATOR_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


gen = load_generator()


def code_lines(gen, text):
    """The lines of a Swift or C file with // and /* */ comments removed."""
    return gen.strip_comments(text).splitlines()


def imported_module(line):
    m = IMPORT_RX.match(line)
    return m.group(1) if m else None


def names_module(imported, module):
    return imported == module or imported.startswith(module + ".")


def files_under(root, rel_dir, suffixes):
    base = root / rel_dir
    if not base.is_dir():
        return []
    return sorted(p for p in base.rglob("*") if p.is_file() and p.name.endswith(suffixes))


def call_bodies(text, call_rx):
    """(kind, body) for each top-level call that call_rx matches in comment-stripped manifest text."""
    consumed_until = 0
    for m in call_rx.finditer(text):
        if m.start() < consumed_until:
            continue
        open_index = m.end() - 1
        end = gen.balanced_span(text, open_index)
        consumed_until = end
        yield m.group(1), text[open_index + 1 : end - 1]


def scan(root, manifest_path):
    counts = {name: 0 for name in NAMES}
    sites = []
    violations = []
    manifest = manifest_path.read_text(encoding="utf-8")
    stripped = gen.strip_comments(manifest)
    targets = gen.parse_package(manifest)

    # forbidden_imports and forbidden_tokens over the three scanned folders.
    for rel_dir in SCANNED:
        for path in files_under(root, rel_dir, (".swift",) + C_SUFFIXES):
            rel = path.relative_to(root).as_posix()
            swift = rel.endswith(".swift")
            depth = 0
            for lineno, code in enumerate(code_lines(gen, path.read_text(encoding="utf-8", errors="replace")), 1):
                directive = code.strip()
                if swift and directive.startswith("#if"):
                    depth += 1
                elif swift and directive.startswith("#endif"):
                    depth = max(0, depth - 1)
                imported = imported_module(code) if swift else None
                if imported and depth == 0 and any(names_module(imported, m) for m in FORBIDDEN_MODULES):
                    counts["forbidden_imports"] += 1
                    sites.append(f"{rel}:{lineno}: import {imported} outside #if")
                for token in TOKENS:
                    if token in code:
                        counts["forbidden_tokens"] += 1
                        sites.append(f"{rel}:{lineno}: {token}")

    # executor_dependents: targets, products and Swift imports.
    for t in targets:
        if t.name != EXECUTOR_TESTS and t.name != EXECUTOR and EXECUTOR in t.internal_deps:
            counts["executor_dependents"] += 1
            sites.append(f"Package.swift: target {t.name} depends on {EXECUTOR}")
    products_text = stripped
    for kind, body in call_bodies(products_text, PRODUCT_CALL_RX):
        name = gen.string_literal(gen.argument_value(body, "name"))
        raw_targets = gen.argument_value(body, "targets") or ""
        listed = re.findall(r'"([^"]+)"', raw_targets)
        if EXECUTOR in listed and (kind, name, listed) != EXECUTOR_PRODUCT:
            counts["executor_dependents"] += 1
            sites.append(f"Package.swift: .{kind} product {name} names {EXECUTOR}")

    # c_targets: folders with C-family files, plus system library and binary targets.
    for t in targets:
        base = root / t.path
        if base.is_dir() and any(
            p.is_file() and (p.name.endswith(C_SUFFIXES) or p.name == "module.modulemap") for p in base.rglob("*")
        ):
            counts["c_targets"] += 1
            sites.append(f"{t.path}: C target {t.name}")
    for kind, _ in call_bodies(stripped, SYSTEM_CALL_RX):
        counts["c_targets"] += 1
        sites.append(f"Package.swift: .{kind} call")

    # c_target_dependents: targets.
    for t in targets:
        if t.name != EXECUTOR and C_TARGET in t.internal_deps:
            counts["c_target_dependents"] += 1
            sites.append(f"Package.swift: target {t.name} depends on {C_TARGET}")

    # Swift imports of the executor and of its C wrapper anywhere under Sources/ and Tests/.
    for top in ("Sources", "Tests"):
        for path in files_under(root, top, (".swift",)):
            rel = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            if EXECUTOR not in text:
                continue  # Both module names hold the substring, so a file without it imports neither.
            for lineno, code in enumerate(code_lines(gen, text), 1):
                imported = imported_module(code)
                if not imported:
                    continue
                if names_module(imported, EXECUTOR) and not rel.startswith(
                    (f"Sources/{EXECUTOR}/", f"Tests/{EXECUTOR_TESTS}/")
                ):
                    counts["executor_dependents"] += 1
                    sites.append(f"{rel}:{lineno}: import {imported}")
                if names_module(imported, C_TARGET) and rel != C_CALLER:
                    counts["c_target_dependents"] += 1
                    sites.append(f"{rel}:{lineno}: import {imported}")

    # The C folder holds the two named files, the header the two declarations, the call no argument but name and path.
    c_dir = root / C_DIR
    if c_dir.is_dir():
        for path in sorted(c_dir.rglob("*")):
            rel = path.relative_to(c_dir).as_posix()
            if path.is_file() and not path.name.startswith(".") and rel not in C_FILES:
                violations.append(f"{C_DIR}/{rel} is not one of the two files the folder may hold")
        header = c_dir / C_HEADER
        if header.is_file():
            declared = [
                line.strip()
                for line in code_lines(gen, header.read_text(encoding="utf-8", errors="replace"))
                if line.strip() and not line.strip().startswith("#")
            ]
            if sorted(declared) != sorted(C_DECLARATIONS):
                violations.append(
                    f"{C_DIR}/{C_HEADER} declares {declared}, and only {list(C_DECLARATIONS)} are allowed"
                )
    for kind, body in call_bodies(stripped, TARGET_CALL_RX):
        if gen.string_literal(gen.argument_value(body, "name")) != C_TARGET:
            continue
        for label in C_REFUSED_ARGUMENTS:
            if gen.argument_value(body, label) is not None:
                violations.append(f"Package.swift: .{kind}(name: \"{C_TARGET}\") holds the refused argument {label}")
    return counts, sites, violations


def read_baseline():
    if not BASELINE_FILE.exists():
        return None
    entries = {}
    for line in BASELINE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, num = line.rpartition(" ")
        try:
            entries[name] = int(num)
        except ValueError:
            continue
    return entries


def option(argv, flag):
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def main(argv):
    root = Path(option(argv, "--root") or SCRIPT_ROOT).resolve()
    manifest = Path(option(argv, "--manifest") or root / "Package.swift")
    counts, sites, violations = scan(root, manifest)

    if "--print" in argv:
        for s in sites:
            print(s)
        for v in violations:
            print(f"VIOLATION {v}")
        for name, n in counts.items():
            print(f"TOTAL {name} {n}")
        return 0

    if "--update" in argv:
        lines = [
            "# portable-imports baseline: counts over Sources/LungfishPortable, Sources/LungfishExecutor, "
            "Sources/CLungfishExecutor and the manifest. c_targets is 1, the executor's C wrapper. Counts may only fall."
        ]
        lines += [f"{name} {n}" for name, n in counts.items()]
        BASELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("Updated baseline: " + ", ".join(f"{n} {name}" for name, n in counts.items()) + ".")
        return 0

    baseline = read_baseline()
    if baseline is None:
        print(
            f"portable-imports: no baseline recorded at {BASELINE_FILE}. "
            f"Run with --update to record the current counts.",
            file=sys.stderr,
        )
        return 1

    over = [(name, n, baseline.get(name, 0)) for name, n in counts.items() if n > baseline.get(name, 0)]
    for name, n, base in over:
        print(f"portable-imports: {n} for {name}, up from the recorded baseline of {base}.", file=sys.stderr)
    for v in violations:
        print(f"portable-imports: {v}.", file=sys.stderr)
    if over or violations:
        for s in sites:
            print(f"  {s}", file=sys.stderr)
        print(
            "The portable layer, the Linux executor and its C wrapper build for static Linux and know no "
            "scheduler, and only LungfishExecutor may list CLungfishExecutor (see scripts/ratchets/portable-imports.sh).",
            file=sys.stderr,
        )
        return 1

    lower = [name for name, n in counts.items() if n < baseline.get(name, 0)]
    summary = ", ".join(f"{n} {name}" for name, n in counts.items())
    if lower:
        print(
            f"portable-imports: {summary}. Down from baseline for {', '.join(lower)}. "
            f"Run with --update to lower the baseline."
        )
    else:
        print(f"portable-imports: {summary}, at the recorded baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
