"""Tests for the provenance ratchets (Phase 2.4, lane W1D).

Every test builds a throwaway repo layout in tmp_path and copies the script under test into it,
so nothing mutates the real repository. The one exception reads the real checkout and runs the
script against it, as test_ratchets_phase0.py does.

Each count is tested for the same behaviors. It passes at its baseline, fails on a new site in a
new file, ignores comments and its exempt files, passes under baseline with the --update hint and
lists its sites with --print.

The hook tests run scripts/install-git-hooks.sh only inside a throwaway git repo. The hook file is
shared by every worktree of the real repository, so nothing here may run the installer against it.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
RATCHETS = SCRIPTS / "ratchets"
REPO = SCRIPTS.parent


class Ratchet(NamedTuple):
    script: Path
    names: tuple  # every count name, in the order the script reports them
    fix_mentions: tuple  # text that every failure message must carry


class Spec(NamedTuple):
    ratchet: Ratchet
    name: str  # the count this row tests
    site: str  # one line of Swift that adds exactly one to this count and to no other
    exempt: tuple = ()  # files where the site is not counted
    lookalikes: tuple = ()  # files close to an exempt one, where the site still counts


def make_repo(tmp_path, script, files):
    """Copy `script` (a Path under scripts/) into tmp_path at the same relative place."""
    dest_dir = tmp_path / "scripts" / script.parent.name
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(script, dest_dir / script.name)
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return dest_dir / script.name


def run(script_path, *args):
    return subprocess.run(
        [sys.executable, str(script_path), *args], capture_output=True, text=True
    )


def swift(*lines):
    """A Swift file whose first line is an import, so a site on the next line is line 2."""
    return "import Foundation\n" + "".join(line + "\n" for line in lines)


def write(tmp_path, rel, text):
    path = tmp_path / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def baseline_of(tmp_path, ratchet):
    """The recorded baseline of `ratchet` in the throwaway repo, as {name: count}."""
    text = (tmp_path / "scripts/ratchets" / ratchet.script.with_suffix(".baseline").name).read_text()
    entries = {}
    for line in text.splitlines():
        if line.strip() and not line.startswith("#"):
            name, _, number = line.rpartition(" ")
            entries[name] = int(number)
    return entries


# ------------------------------------------------------------------ the specs

PROVENANCE = "Sources/LungfishWorkflow/Provenance/"
INSPECTOR_VIEW_MODEL = "Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift"

WRITERS = Ratchet(
    script=RATCHETS / "provenance-writers.sh",
    names=(
        "write_provenance_functions",
        "bare_workflow_run_writes",
        "legacy_run_embeds",
        "envelope_encodes_outside_writer",
        "provenance_filename_literals",
    ),
    fix_mentions=(
        "docs/contracts/RECORDING-PROVENANCE.md",
        "rule 6 of docs/contracts/ADDING-AN-OPERATION.md",
    ),
)

WRITER_SPECS = (
    Spec(WRITERS, "write_provenance_functions", "func writeProvenance(to url: URL) throws {}"),
    Spec(WRITERS, "bare_workflow_run_writes", "try run.writeSidecar(to: url)"),
    Spec(
        WRITERS,
        "legacy_run_embeds",
        'let e = ProvenanceEnvelope(workflowName: "x", legacyWorkflowRun: run)',
        exempt=(
            PROVENANCE + "ProvenanceEnvelope.swift",
            PROVENANCE + "ProvenanceEnvelope+RunLevelFiles.swift",
            PROVENANCE + "ProvenanceRecord.swift",
            PROVENANCE + "ProvenanceRecorder.swift",
            PROVENANCE + "ProvenanceRecorder+SidecarLookup.swift",
            PROVENANCE + "ProvenanceRunBuilder.swift",
            PROVENANCE + "ProvenanceWriter.swift",
        ),
        lookalikes=(
            # Exempt for the encoder count only.
            PROVENANCE + "ProvenanceEnvelopeReader.swift",
            # The same file name outside the Provenance folder.
            "Sources/LungfishCLI/Support/ProvenanceWriter.swift",
            PROVENANCE + "Archive/ProvenanceRecord.swift",
            # A longer name is not the exempt name.
            PROVENANCE + "ProvenanceWriterExtras.swift",
            PROVENANCE + "ProvenanceRecords.swift",
        ),
    ),
    Spec(
        WRITERS,
        "envelope_encodes_outside_writer",
        "let data = try ProvenanceJSON.encoder.encode(envelope)",
        exempt=(
            PROVENANCE + "ProvenanceWriter.swift",
            PROVENANCE + "ProvenanceEnvelopeReader.swift",
            INSPECTOR_VIEW_MODEL,
        ),
        lookalikes=(
            # Exempt for the legacy run count only.
            PROVENANCE + "ProvenanceEnvelope.swift",
            PROVENANCE + "ProvenanceExporter.swift",
            # The same file name in another module.
            "Sources/LungfishCLI/Support/ProvenanceWriter.swift",
            "Sources/LungfishKit/ProvenanceInspectorViewModel.swift",
            # A longer name is not the exempt name.
            INSPECTOR_VIEW_MODEL.replace(".swift", "+Display.swift"),
        ),
    ),
    Spec(
        WRITERS,
        "provenance_filename_literals",
        'let name = "run.lungfish-provenance.json"',
    ),
)

PATHS = Ratchet(
    script=RATCHETS / "path-helpers.sh",
    names=(
        "relative_path_definitions",
        "relative_path_relatives",
        "directory_checksum_copies",
    ),
    fix_mentions=("docs/contracts/RECORDING-PROVENANCE.md",),
)

PATH_SPECS = (
    Spec(PATHS, "relative_path_definitions", 'func relativePath(of url: URL) -> String { "" }'),
    Spec(PATHS, "relative_path_relatives", 'func storedPath(for url: URL) -> String { "" }'),
    Spec(
        PATHS,
        "directory_checksum_copies",
        'private func directoryChecksum(from manifest: Manifest) -> String { "" }',
    ),
)

SPECS = WRITER_SPECS + PATH_SPECS
RATCHETS_UNDER_TEST = (WRITERS, PATHS)

EXEMPT_CASES = [(spec, path) for spec in SPECS for path in spec.exempt]
LOOKALIKE_CASES = [(spec, path) for spec in SPECS for path in spec.lookalikes]


def case_id(case):
    spec, path = case
    return f"{spec.name}:{Path(path).name}"


def repo_with_one_site(tmp_path, spec):
    """A throwaway repo whose only site for `spec` is in Sources/A/A.swift, with its baseline recorded."""
    script = make_repo(tmp_path, spec.ratchet.script, {"Sources/A/A.swift": swift(spec.site)})
    assert run(script, "--update").returncode == 0
    return script


# ------------------------------------------------- one count at a time (all specs)

@pytest.mark.parametrize("spec", SPECS, ids=lambda spec: spec.name)
def test_count_passes_at_its_baseline(tmp_path, spec):
    script = repo_with_one_site(tmp_path, spec)
    entries = baseline_of(tmp_path, spec.ratchet)
    assert entries[spec.name] == 1
    assert all(n == 0 for name, n in entries.items() if name != spec.name)
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "at the recorded baseline" in result.stdout


@pytest.mark.parametrize("spec", SPECS, ids=lambda spec: spec.name)
def test_new_site_in_a_new_file_fails_with_its_own_fix_text(tmp_path, spec):
    script = repo_with_one_site(tmp_path, spec)
    write(tmp_path, "Sources/B/B.swift", swift(spec.site))
    result = run(script)
    assert result.returncode == 1
    assert f"2 for {spec.name}, up from the recorded baseline of 1" in result.stderr
    for name in spec.ratchet.names:
        if name != spec.name:
            assert f"for {name}," not in result.stderr
    for mention in spec.ratchet.fix_mentions:
        assert mention in result.stderr
    assert "--print" in result.stderr


@pytest.mark.parametrize("spec", SPECS, ids=lambda spec: spec.name)
def test_a_second_site_in_the_same_file_fails(tmp_path, spec):
    script = repo_with_one_site(tmp_path, spec)
    write(tmp_path, "Sources/A/A.swift", swift(spec.site, spec.site))
    result = run(script)
    assert result.returncode == 1
    assert f"2 for {spec.name}" in result.stderr


@pytest.mark.parametrize("spec", SPECS, ids=lambda spec: spec.name)
def test_comments_are_ignored(tmp_path, spec):
    script = repo_with_one_site(tmp_path, spec)
    write(
        tmp_path,
        "Sources/B/B.swift",
        swift(
            f"// {spec.site}",
            f"/// {spec.site}",
            f"    // {spec.site}",
            f"let a = 1 // {spec.site}",
        ),
    )
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "at the recorded baseline" in result.stdout
    listing = run(script, "--print").stdout
    assert "Sources/B/B.swift" not in listing


@pytest.mark.parametrize("case", EXEMPT_CASES, ids=case_id)
def test_exempt_files_are_ignored(tmp_path, case):
    spec, exempt = case
    script = repo_with_one_site(tmp_path, spec)
    write(tmp_path, exempt, swift(spec.site, spec.site))
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "at the recorded baseline" in result.stdout
    assert exempt not in run(script, "--print").stdout


NO_EXEMPT_FILE_SPECS = [spec for spec in SPECS if not spec.exempt]


@pytest.mark.parametrize("spec", NO_EXEMPT_FILE_SPECS, ids=lambda spec: spec.name)
def test_a_count_with_no_exempt_files_counts_the_provenance_core_too(tmp_path, spec):
    script = repo_with_one_site(tmp_path, spec)
    for core in (
        PROVENANCE + "ProvenanceWriter.swift",
        PROVENANCE + "ProvenanceRecorder.swift",
        "Sources/LungfishCore/Process/ToolProcess.swift",
    ):
        write(tmp_path, core, swift(spec.site))
    result = run(script)
    assert result.returncode == 1
    assert f"4 for {spec.name}, up from the recorded baseline of 1" in result.stderr


@pytest.mark.parametrize("case", LOOKALIKE_CASES, ids=case_id)
def test_files_that_only_look_exempt_are_counted(tmp_path, case):
    spec, lookalike = case
    script = repo_with_one_site(tmp_path, spec)
    write(tmp_path, lookalike, swift(spec.site))
    result = run(script)
    assert result.returncode == 1
    assert f"2 for {spec.name}, up from the recorded baseline of 1" in result.stderr
    assert f"{lookalike}:2: {spec.name}" in run(script, "--print").stdout


@pytest.mark.parametrize("spec", SPECS, ids=lambda spec: spec.name)
def test_under_baseline_passes_and_suggests_update(tmp_path, spec):
    script = repo_with_one_site(tmp_path, spec)
    write(tmp_path, "Sources/A/A.swift", swift("let a = 1"))
    result = run(script)
    assert result.returncode == 0, result.stderr
    assert "--update" in result.stdout
    assert f"Down from baseline for {spec.name}" in result.stdout
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path, spec.ratchet)[spec.name] == 0
    assert "at the recorded baseline" in run(script).stdout


@pytest.mark.parametrize("spec", SPECS, ids=lambda spec: spec.name)
def test_print_lists_the_sites(tmp_path, spec):
    script = make_repo(
        tmp_path,
        spec.ratchet.script,
        {"Sources/A/A.swift": swift(spec.site), "Sources/A/B.swift": swift("let a = 1", spec.site)},
    )
    result = run(script, "--print")
    assert result.returncode == 0
    assert f"Sources/A/A.swift:2: {spec.name}" in result.stdout
    assert f"Sources/A/B.swift:3: {spec.name}" in result.stdout
    assert f"TOTAL {spec.name} 2" in result.stdout
    for name in spec.ratchet.names:
        assert f"TOTAL {name} " in result.stdout


# ----------------------------------------------- one ratchet at a time (all scripts)

@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_missing_baseline_fails(tmp_path, ratchet):
    script = make_repo(tmp_path, ratchet.script, {"Sources/A/A.swift": swift("let a = 1")})
    result = run(script)
    assert result.returncode == 1
    assert "no baseline recorded" in result.stderr


@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_update_records_every_count_in_order(tmp_path, ratchet):
    script = make_repo(tmp_path, ratchet.script, {"Sources/A/A.swift": swift("let a = 1")})
    result = run(script, "--update")
    assert result.returncode == 0
    text = (tmp_path / "scripts/ratchets" / ratchet.script.with_suffix(".baseline").name).read_text()
    lines = text.splitlines()
    assert lines[0].startswith("#")
    assert [line.rpartition(" ")[0] for line in lines[1:]] == list(ratchet.names)
    assert all(line.rpartition(" ")[2] == "0" for line in lines[1:])


@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_an_empty_sources_folder_counts_zero(tmp_path, ratchet):
    script = make_repo(tmp_path, ratchet.script, {})
    assert run(script, "--update").returncode == 0
    assert set(baseline_of(tmp_path, ratchet).values()) == {0}
    assert run(script).returncode == 0


@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_every_site_counts_only_its_own_count(tmp_path, ratchet):
    specs = [spec for spec in SPECS if spec.ratchet is ratchet]
    files = {f"Sources/A/Site{index}.swift": swift(spec.site) for index, spec in enumerate(specs)}
    script = make_repo(tmp_path, ratchet.script, files)
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path, ratchet) == {name: 1 for name in ratchet.names}


@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_print_never_fails_even_over_the_baseline(tmp_path, ratchet):
    spec = next(spec for spec in SPECS if spec.ratchet is ratchet)
    script = repo_with_one_site(tmp_path, spec)
    write(tmp_path, "Sources/B/B.swift", swift(spec.site))
    assert run(script).returncode == 1
    assert run(script, "--print").returncode == 0


@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_each_count_has_its_own_fix_text(tmp_path, ratchet):
    messages = {}
    for spec in (spec for spec in SPECS if spec.ratchet is ratchet):
        repo = tmp_path / spec.name
        repo.mkdir()
        script = repo_with_one_site(repo, spec)
        write(repo, "Sources/B/B.swift", swift(spec.site))
        stderr = run(script).stderr
        messages[spec.name] = stderr.splitlines()[1]
    assert set(messages) == set(ratchet.names)
    assert len(set(messages.values())) == len(messages)
    for message in messages.values():
        for mention in ratchet.fix_mentions:
            assert mention in message


# ----------------------------------------------- the writers ratchet in particular

WRITERS_SCRIPT = WRITERS.script


def test_a_nil_legacy_run_is_not_an_embed(tmp_path):
    script = make_repo(
        tmp_path,
        WRITERS_SCRIPT,
        {
            "Sources/A/A.swift": swift(
                "let a = ProvenanceEnvelope(workflowName: \"x\", legacyWorkflowRun: nil)",
                "let b = ProvenanceEnvelope(workflowName: \"x\", legacyWorkflowRun:nil)",
                "let c = builder.complete(exitStatus: 0, startedAt: s, endedAt: e, legacyWorkflowRun: nil)",
            )
        },
    )
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path, WRITERS)["legacy_run_embeds"] == 0
    write(tmp_path, "Sources/B/B.swift", swift("let d = make(legacyWorkflowRun: nilRun)", "let e = make(legacyWorkflowRun:run)"))
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path, WRITERS)["legacy_run_embeds"] == 2


def test_a_slash_pair_inside_a_string_literal_does_not_start_a_comment(tmp_path):
    script = make_repo(
        tmp_path,
        WRITERS_SCRIPT,
        {
            "Sources/A/A.swift": swift(
                'let url = "https://example.com/provenance.json"',
                'let name = "provenance.json" // the sidecar name',
            )
        },
    )
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path, WRITERS)["provenance_filename_literals"] == 2


@pytest.mark.parametrize(
    ("line", "counted"),
    [
        ('let a = "provenance.json"', 1),
        ('let a = "Provenance.json"', 1),
        ('let a = "run.lungfish-provenance.json"', 1),
        ('let a = "\\(stem).lungfish-provenance.json"', 1),
        ('let a = "bundle/provenance/steps.json"', 1),
        ('let a = "provenance.txt"', 0),
        ('let a = "notes.json"', 0),
        ('let a = "PROVENANCE.json"', 0),
        ("let a = provenanceFilename", 0),
        ('let a = "provenance" + ".json"', 0),
    ],
)
def test_filename_literals_need_provenance_and_a_json_name_in_one_literal(tmp_path, line, counted):
    script = make_repo(tmp_path, WRITERS_SCRIPT, {"Sources/A/A.swift": swift(line)})
    assert run(script, "--update").returncode == 0
    assert baseline_of(tmp_path, WRITERS)["provenance_filename_literals"] == counted


# A line of Swift and the one count it adds to, or None when it adds to none. The None rows are
# neighbors of a counted spelling, such as a call where the count wants a definition.
NEIGHBOR_CASES = [
    (WRITERS, "func writeProvenance(", "write_provenance_functions"),
    (WRITERS, "private static func writeProvenance<T>(_ value: T) {}", "write_provenance_functions"),
    (WRITERS, "func writeProvenanceRecord(", None),
    (WRITERS, "func rewriteProvenance(", None),
    (WRITERS, "let f = writeProvenance", None),
    (WRITERS, "try run.writeSidecar(to: url)", "bare_workflow_run_writes"),
    (WRITERS, "try writeSidecar(to: url)", None),
    (WRITERS, "func writeSidecar(to url: URL) throws {", None),
    (WRITERS, "let e = try ProvenanceJSON.encoder.encode(x)", "envelope_encodes_outside_writer"),
    (WRITERS, "let e = try ProvenanceJSON.decoder.decode(T.self, from: d)", None),
    (WRITERS, "let e = try MyProvenanceJSON.encoder.encode(x)", None),
    (PATHS, "func relativePath(of url: URL) -> String {", "relative_path_definitions"),
    (PATHS, "static func relativePath<T>(_ value: T) -> String {", "relative_path_definitions"),
    (PATHS, "private static func projectRelativePath(_ url: URL, projectRoot: URL) -> String? {", "relative_path_definitions"),
    (PATHS, "func relativePathComponents(of url: URL) -> [String] {", None),
    (PATHS, "func projectRelativePaths() -> [String] {", None),
    (PATHS, "let p = relativePath(of: url)", None),
    (PATHS, "func appRelativePath(from base: URL, to target: URL) -> String {", "relative_path_relatives"),
    (PATHS, "func bundleRelativePath(for url: URL, in bundle: URL) -> String {", "relative_path_relatives"),
    (PATHS, "func storedPath(for url: URL, relativeTo directory: URL) -> String {", "relative_path_relatives"),
    (PATHS, "func relativeDescendantPath(from ancestor: URL, to descendant: URL) -> String? {", "relative_path_relatives"),
    (PATHS, "func filesystemRelativePath(from base: URL, to target: URL) -> String {", "relative_path_relatives"),
    (PATHS, "static func relativePathForMigrationProvenance(_ url: URL, root: URL) -> String {", "relative_path_relatives"),
    (PATHS, "static func relative(_ url: URL, to root: URL) -> String {", "relative_path_relatives"),
    (PATHS, "public static func relative(path: String, toAny prefixes: [String]) -> String? {", "relative_path_relatives"),
    (PATHS, "func relative(to base: URL) -> String {", None),
    (PATHS, "func relativeURL(_ url: URL) -> URL {", None),
    (PATHS, "func storedPaths() -> [String] {", None),
    (PATHS, "private func directoryChecksum(from manifest: Manifest) -> String {", "directory_checksum_copies"),
    (PATHS, "private static func directoryChecksum(at url: URL) throws -> String {", "directory_checksum_copies"),
    (PATHS, "func directoryChecksums() -> [String] {", None),
    (PATHS, "let c = directoryChecksum(from: manifest)", None),
]


@pytest.mark.parametrize(
    ("ratchet", "line", "name"),
    NEIGHBOR_CASES,
    ids=[f"{ratchet.script.stem}:{line}" for ratchet, line, _ in NEIGHBOR_CASES],
)
def test_each_pattern_matches_the_spelling_it_names_and_not_its_neighbors(tmp_path, ratchet, line, name):
    script = make_repo(tmp_path, ratchet.script, {"Sources/A/A.swift": swift(line)})
    assert run(script, "--update").returncode == 0
    expected = {count: 0 for count in ratchet.names}
    if name is not None:
        expected[name] = 1
    assert baseline_of(tmp_path, ratchet) == expected


# ------------------------------------------------------------ the real repository

@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_real_repo_is_at_or_under_its_baseline(ratchet):
    result = subprocess.run(
        [sys.executable, str(ratchet.script)], capture_output=True, text=True, cwd=REPO
    )
    assert result.returncode == 0, f"{ratchet.script.name}: {result.stderr}"


@pytest.mark.parametrize("ratchet", RATCHETS_UNDER_TEST, ids=lambda ratchet: ratchet.script.stem)
def test_real_baseline_names_every_count_once(ratchet):
    text = ratchet.script.with_suffix(".baseline").read_text()
    entries = [line.rpartition(" ") for line in text.splitlines() if line.strip() and not line.startswith("#")]
    assert [name for name, _, _ in entries] == list(ratchet.names)
    assert all(re.fullmatch(r"[0-9]+", number) for _, _, number in entries)


# ------------------------------------------------------------------ hook wiring

def installed_hook(tmp_path):
    """Run the real installer in a throwaway git repo and return (pre-push hook text, installer output).

    The installer writes into the git directory of the repo it sits in, so its copy lives in tmp_path
    and runs with tmp_path as the working directory. The environment loses every GIT_ variable and the
    global and system git configuration, so nothing can point it at the real repository's hooks.
    """
    assert REPO not in (tmp_path, *tmp_path.parents)
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, env=env)
    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir()
    shutil.copy(SCRIPTS / "install-git-hooks.sh", scripts_dir / "install-git-hooks.sh")
    result = subprocess.run(
        ["/bin/bash", str(scripts_dir / "install-git-hooks.sh")],
        cwd=tmp_path, env=env, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    hook = tmp_path / ".git" / "hooks" / "pre-push"
    assert hook.is_file()
    return hook.read_text(), result.stdout


def test_installed_hook_runs_both_ratchets_right_after_process_spawn(tmp_path):
    hook, _ = installed_hook(tmp_path)
    calls = re.findall(r'python3 "\$REPO_ROOT/scripts/((?:ratchets|checks)/[^"]+)"', hook)
    start = calls.index("ratchets/process-spawn.sh")
    assert calls[start + 1 : start + 3] == ["ratchets/provenance-writers.sh", "ratchets/path-helpers.sh"]
    gate = hook.index('"$REPO_ROOT/scripts/full-suite-gate.sh"')
    assert hook.index('"$REPO_ROOT/scripts/ratchets/path-helpers.sh"') < gate


@pytest.mark.parametrize("name", ["process-spawn", "provenance-writers", "path-helpers"])
def test_each_new_block_has_the_message_style_of_the_process_spawn_block(tmp_path, name):
    hook, _ = installed_hook(tmp_path)
    block = (
        rf'echo "pre-push: checking the {name} ratchet \(use --no-verify to skip\)\.\.\."\n'
        rf'if ! python3 "\$REPO_ROOT/scripts/ratchets/{name}\.sh"; then\n'
        rf'    echo "pre-push: {name} ratchet FAILED \([^"]+\) \u2014 push aborted\. Use --no-verify to bypass\." >&2\n'
        r"    exit 1\n"
        r"fi\n"
    )
    assert re.search(block, hook)


def test_closing_summary_names_every_ratchet_the_hook_runs(tmp_path):
    hook, output = installed_hook(tmp_path)
    ratchets = re.findall(r'python3 "\$REPO_ROOT/scripts/ratchets/([^"]+)\.sh"', hook)
    assert {"volume-portability", "provenance-writers", "path-helpers"} <= set(ratchets)
    summary = next(line for line in output.splitlines() if line.startswith("It runs the "))
    named = summary[len("It runs the "):].split(" ratchets,")[0]
    assert sorted(re.split(r", | and ", named)) == sorted(ratchets)
