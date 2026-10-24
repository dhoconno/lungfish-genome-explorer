"""Tests for scripts/chtc/image/build-image.sh, the build script of the CHTC tool image (program C4, lane I IMAGE).

The tests never build an image, never reach the network and never need Apptainer. ``--print-pins`` gives the pins of
the script (the base digest, the two repository locks, the order of the steps). A stand-in ``apptainer`` then lets the
script run from end to end in a temporary folder, so the tests read what the script does. They read the commands it
runs and their order, whether the executor is gone from the sandbox before the SIF is built, what it prints, and what
it leaves for HTCondor to transfer after a good build and after a failed one.
"""

import functools
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "chtc" / "image" / "build-image.sh"
SUBMIT = ROOT / "scripts" / "chtc" / "image" / "build-image.sub"
TOOLS_FOLDER = ROOT / "Sources" / "LungfishWorkflow" / "Resources" / "ManagedTools"
LINUX_LOCK = TOOLS_FOLDER / "third-party-tools-lock.linux-64.json"
# The linux/amd64 manifest of mambaorg/micromamba 2.9.0-debian12-slim, the base C0 built from (C0-SLICE0.md:13).
C0_BASE_DIGEST = "sha256:bba1fff35268813383cb9f92816e862b7580ae2e9493a5ea2d824938c060fe98"
STAGING_IMAGES = "file:///staging/groups/oconnor_group/32748/lge-chtc-test/images/"
TIMEOUT_SECONDS = 30

# A stand-in for apptainer. It keeps the sandbox and the image in plain folders and files, logs each call to
# $FAKE_STATE/calls.log, and runs the few commands the script gives it. FAKE_MISSING names base image utilities to
# leave out, FAKE_MANIFEST_OMIT a tool id to leave out of the manifest, and FAKE_STRAY_EXECUTOR leaves a copy of the
# executor in the sandbox after the manifest step.
FAKE_APPTAINER = r'''#!@PYTHON@
import hashlib
import json
import os
import shutil
import subprocess
import sys

state = os.environ["FAKE_STATE"]
args = sys.argv[1:]
snapshot = os.path.join(state, "snapshot")
missing = os.environ.get("FAKE_MISSING", "").split(",")


def note(text):
    with open(os.path.join(state, "calls.log"), "a") as handle:
        handle.write(text + "\n")


note("apptainer " + " ".join(args))

if args[0] == "--version":
    print("apptainer version 1.5.4-fake")
    sys.exit(0)

if args[0] == "build" and args[1] == "--sandbox":
    root = args[2]
    for folder in ("usr/bin", "opt", ".singularity.d/env", "etc"):
        os.makedirs(os.path.join(root, folder))
    os.symlink("usr/bin", os.path.join(root, "bin"))
    for name in ("dirname", "basename", "readlink", "sha256sum", "micromamba"):
        if name in missing:
            continue
        path = os.path.join(root, "usr", "bin", name)
        with open(path, "w") as handle:
            handle.write("fake " + name + "\n")
        os.chmod(path, 0o755)
    sys.exit(0)

if args[0] == "build":
    sif, root = args[1], args[2]
    stray = [name for _, _, names in os.walk(root) for name in names if name.startswith("lungfish-executor")]
    note("sif-build executor_in_sandbox=" + ("yes" if stray else "no"))
    if os.path.exists(snapshot):
        shutil.rmtree(snapshot)
    shutil.copytree(root, snapshot, symlinks=True)
    with open(os.path.join(root, "opt", "lungfish", "image-manifest.json"), "rb") as handle:
        manifest = handle.read()
    with open(sif, "wb") as handle:
        handle.write(b"fake sif\n" + manifest)
    sys.exit(0)

if args[0] == "exec":
    index = 1
    while args[index].startswith("--"):
        index += 2 if args[index] == "--env" else 1
    image, command = args[index], args[index + 1:]
    root = image if os.path.isdir(image) else snapshot
    program = command[0]

    def inside(path):
        return os.path.join(root, path.lstrip("/"))

    if os.path.dirname(program) in ("/usr/bin", "/bin") and os.path.basename(program) in ("dirname", "basename", "readlink"):
        if not os.path.exists(inside(program)):
            sys.stderr.write("FATAL: " + program + ": no such file or directory\n")
            sys.exit(255)
        sys.exit(subprocess.call(["/usr/bin/" + os.path.basename(program)] + command[1:]))

    if program == "/usr/bin/micromamba":
        if command[1] == "create":
            prefix = command[command.index("-p") + 1]
            lock = command[command.index("--file") + 1]
            if not os.path.isfile(inside(lock)):
                sys.stderr.write("critical libmamba lock file not found\n")
                sys.exit(1)
            os.makedirs(inside(prefix + "/conda-meta"))
            os.makedirs(inside(prefix + "/bin"))
        elif command[1] == "list":
            print("# fake explicit list of " + command[command.index("-p") + 1])
        sys.exit(0)

    if program == "/opt/lungfish/lungfish-executor.build-only":
        path = inside(program)
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            sys.stderr.write("FATAL: " + program + ": no such file or directory\n")
            sys.exit(255)
        prefixes = [command[k + 1] for k, word in enumerate(command) if word == "--conda-prefix"]
        output = command[command.index("--output") + 1]
        tools = []
        for name in os.environ["FAKE_REQUIRED_IDS"].split():
            if name == os.environ.get("FAKE_MANIFEST_OMIT"):
                continue
            prefix = prefixes[-1] if name == "trim_galore" else prefixes[0]
            tools.append({"build": "b0", "condaPackage": "fake", "id": name, "path": prefix + "/bin/" + name, "version": "1.0"})
        document = {"platform": "linux-64", "schemaVersion": 1, "tools": tools}
        data = (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()
        descriptor = os.open(inside(output), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.write(descriptor, data)
        os.close(descriptor)
        if os.environ.get("FAKE_STRAY_EXECUTOR"):
            shutil.copy(path, inside("/usr/bin/lungfish-executor"))
        print("sha256 %s size %d tools %d" % (hashlib.sha256(data).hexdigest(), len(data), len(tools)))
        sys.exit(0)

    if program == "/opt/lge/env/bin/python3":
        mapped = [inside(word) if os.path.isfile(inside(word)) else word for word in command[1:]]
        sys.exit(subprocess.call([sys.executable] + mapped))

    if program == "/usr/bin/sha256sum":
        with open(inside(command[1]), "rb") as handle:
            print("%s  %s" % (hashlib.sha256(handle.read()).hexdigest(), command[1]))
        sys.exit(0)

    if os.path.basename(program) == "bash":
        print("fake tool versions")
        sys.exit(0)

    sys.stderr.write("the fake apptainer cannot run " + program + "\n")
    sys.exit(127)

sys.stderr.write("the fake apptainer cannot run " + " ".join(args) + "\n")
sys.exit(127)
'''


@functools.lru_cache(maxsize=None)
def pins():
    """The script's pins, read through --print-pins with no build tool on PATH."""
    result = subprocess.run(
        ["/bin/bash", str(SCRIPT), "--print-pins"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=TIMEOUT_SECONDS,
        cwd=str(ROOT),
        env={"PATH": "/usr/bin:/bin"},
    )
    if result.returncode != 0:
        raise AssertionError("--print-pins exited %d: %s" % (result.returncode, result.stderr))
    values = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def parse_record(stdout):
    """The LGE_IMAGE_<KEY>=<value> lines of the script's stdout, as a later lane parses them."""
    record = {}
    for line in stdout.splitlines():
        match = re.fullmatch(r"LGE_IMAGE_([A-Z0-9_]+)=(.*)", line)
        if match:
            record[match.group(1)] = match.group(2)
    return record


def submit_values():
    values = {}
    for line in SUBMIT.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip().lower()] = value.strip()
    return values


def transfer_outputs():
    return [name.strip() for name in submit_values()["transfer_output_files"].split(",")]


class Harness:
    """A temporary job scratch folder, input folder and fake apptainer, and one way to run the script in them."""

    def __init__(self, case):
        folder = tempfile.TemporaryDirectory()
        case.addCleanup(folder.cleanup)
        self.root = pathlib.Path(folder.name)
        self.work = self.root / "work"
        self.inputs = self.root / "inputs"
        self.state = self.root / "state"
        for path in (self.work, self.inputs, self.state):
            path.mkdir()
        shutil.copy(TOOLS_FOLDER / "lge-tools-linux-64-explicit.txt", self.inputs)
        shutil.copy(TOOLS_FOLDER / "trim_galore-linux-64-explicit.txt", self.inputs)
        (self.inputs / "lungfish-executor").write_bytes(b"\x7fELF a stand-in executor\n")
        self.fake = self.root / "apptainer"
        self.fake.write_text(FAKE_APPTAINER.replace("@PYTHON@", sys.executable))
        self.fake.chmod(0o755)

    def run(self, production=False, **fake_environment):
        """Runs the script. With production=True it finds its folder as the CHTC job does, by _CONDOR_SCRATCH_DIR."""
        environment = dict(os.environ)
        for name in ("LGE_BUILD_DIR", "LGE_INPUT_DIR", "_CONDOR_SCRATCH_DIR"):
            environment.pop(name, None)
        environment.update(
            LGE_APPTAINER=str(self.fake),
            FAKE_STATE=str(self.state),
            FAKE_REQUIRED_IDS=pins()["required_tool_ids"],
        )
        if production:
            for source in self.inputs.iterdir():
                shutil.copy(source, self.work)
            environment["_CONDOR_SCRATCH_DIR"] = str(self.work)
        else:
            environment.update(LGE_BUILD_DIR=str(self.work), LGE_INPUT_DIR=str(self.inputs))
        environment.update(fake_environment)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=TIMEOUT_SECONDS,
            cwd=str(self.root),
            env=environment,
        )

    def calls(self):
        log = self.state / "calls.log"
        return log.read_text().splitlines() if log.exists() else []

    def sif_builds(self):
        return [line for line in self.calls() if line.startswith("apptainer build ") and "--sandbox" not in line]


class PinTests(unittest.TestCase):
    def test_script_parses_and_is_executable(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(SCRIPT)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=TIMEOUT_SECONDS,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.access(SCRIPT, os.X_OK), "the submit file runs build-image.sh directly, so it must be executable")

    def test_print_pins_needs_no_build_tool_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "--print-pins"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=TIMEOUT_SECONDS,
                cwd=folder,
                env={"PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(os.listdir(folder), [])

    def test_unknown_argument_exits_64_and_builds_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "--bogus"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=TIMEOUT_SECONDS,
                cwd=folder,
            )
            self.assertEqual(result.returncode, 64)
            self.assertIn("unknown argument --bogus", result.stderr)
            self.assertEqual(os.listdir(folder), [])

    def test_image_build_pins_base_digest_and_repository_locks(self):
        values = pins()
        self.assertEqual(values["base_digest"], C0_BASE_DIGEST)
        self.assertEqual(values["base_image"], "mambaorg/micromamba@" + C0_BASE_DIGEST)
        self.assertEqual(values["base_uri"], "docker://mambaorg/micromamba@" + C0_BASE_DIGEST)
        self.assertEqual(values["build_route"], "sandbox")
        for lock, digest in (("lock_tools", "lock_tools_sha256"), ("lock_trim_galore", "lock_trim_galore_sha256")):
            path = ROOT / values[lock]
            self.assertTrue(path.is_file(), "the pinned lock %s does not exist" % values[lock])
            self.assertTrue(values[lock].startswith("Sources/LungfishWorkflow/Resources/ManagedTools/"))
            self.assertEqual(values[digest], hashlib.sha256(path.read_bytes()).hexdigest(), values[lock] + " changed, so rebuild the image")
        self.assertEqual(os.path.basename(values["lock_tools"]), "lge-tools-linux-64-explicit.txt")
        self.assertEqual(os.path.basename(values["lock_trim_galore"]), "trim_galore-linux-64-explicit.txt")
        self.assertNotEqual(values["lock_tools_prefix"], values["lock_trim_galore_prefix"])

    def test_pinned_lock_digests_match_the_linux_lock_file(self):
        values = pins()
        entries = {entry["resource"]: entry["sha256"] for entry in json.loads(LINUX_LOCK.read_text())["explicitLocks"]}
        self.assertEqual(values["lock_tools_sha256"], entries[os.path.basename(values["lock_tools"])])
        self.assertEqual(values["lock_trim_galore_sha256"], entries[os.path.basename(values["lock_trim_galore"])])

    def test_required_tool_ids_are_the_executables_of_the_linux_lock(self):
        listed = pins()["required_tool_ids"].split()
        executables = {name for tool in json.loads(LINUX_LOCK.read_text())["tools"] for name in tool["executables"]}
        self.assertEqual(set(listed), executables)
        self.assertEqual(len(listed), len(set(listed)))

    def test_executor_is_removed_right_after_the_manifest_step(self):
        steps = pins()["steps"].split()
        manifest = steps.index("image_manifest")
        self.assertEqual(steps[manifest - 1], "executor_copy")
        self.assertEqual(steps[manifest + 1], "executor_remove")
        self.assertLess(steps.index("executor_remove"), steps.index("sif"))
        self.assertEqual(pins()["executor_build_only_path"], "/opt/lungfish/lungfish-executor.build-only")
        self.assertEqual(pins()["manifest_path"], "/opt/lungfish/image-manifest.json")

    def test_utility_check_names_the_wrapper_utilities_and_both_folders(self):
        values = pins()
        self.assertEqual(values["utilities"].split(), ["dirname", "basename", "readlink"])
        self.assertEqual(values["utility_directories"].split(), ["/usr/bin", "/bin"])
        self.assertLess(values["steps"].split().index("utilities"), values["steps"].split().index("install_tools"))

    def test_submit_file_is_a_build_job_that_moves_what_the_script_reads_and_writes(self):
        values = submit_values()
        self.assertEqual(values["+isbuildjob"], "true")
        self.assertEqual(values["executable"], "build-image.sh")
        self.assertIn("haschtcstaging", values["requirements"].lower())
        inputs = {name.strip() for name in values["transfer_input_files"].split(",")}
        # The two locks travel by plain name from the submit folder. The executor is over 100 MB, so CHTC's rule is to keep
        # it on /staging and name it by a file:/// path, and it arrives under the last name of that path, which is the name
        # the script reads.
        locks = {os.path.basename(pins()["lock_tools"]), os.path.basename(pins()["lock_trim_galore"])}
        executor = STAGING_IMAGES + pins()["executor_input"]
        self.assertEqual(inputs, locks | {executor})
        self.assertEqual(os.path.basename(executor), pins()["executor_input"])
        self.assertIn(pins()["sif_scratch_name"], transfer_outputs())
        remap = values["transfer_output_remaps"].strip('"')
        self.assertTrue(remap.startswith(pins()["sif_scratch_name"] + " = " + STAGING_IMAGES), remap)


class StubbedBuildTests(unittest.TestCase):
    def test_good_build_prints_parseable_digests_and_names_the_sif_by_its_hash(self):
        harness = Harness(self)
        result = harness.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = parse_record(result.stdout)
        sif = harness.work / "lge-tools.sif"
        manifest = harness.work / "image-manifest.json"
        sif_sha = hashlib.sha256(sif.read_bytes()).hexdigest()
        self.assertEqual(record["SIF_SHA256"], sif_sha)
        self.assertEqual(record["SIF_SIZE"], str(sif.stat().st_size))
        self.assertEqual(record["SIF_NAME"], "lge-tools-" + sif_sha[:12] + ".sif")
        self.assertEqual(record["MANIFEST_SHA256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
        self.assertEqual(record["MANIFEST_SIZE"], str(manifest.stat().st_size))
        self.assertEqual(record["MANIFEST_TOOLS"], str(len(pins()["required_tool_ids"].split())))
        self.assertEqual(record["BASE"], pins()["base_image"])
        self.assertEqual(result.stdout.strip().splitlines()[-1], "LGE_IMAGE_STATUS=ok")
        for name in transfer_outputs():
            self.assertTrue((harness.work / name).is_file(), name + " is listed in transfer_output_files and is missing")
        self.assertFalse((harness.work / "sandbox").exists(), "the sandbox is removed when the build ends")

    def test_build_finds_its_folder_by_the_condor_scratch_variable(self):
        harness = Harness(self)
        result = harness.run(production=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(parse_record(result.stdout)["STATUS"], "ok")
        self.assertTrue((harness.work / "lge-tools.sif").stat().st_size > 0)

    def test_sandbox_is_built_from_the_pinned_digest_and_nothing_else(self):
        harness = Harness(self)
        self.assertEqual(harness.run().returncode, 0)
        sandboxes = [line for line in harness.calls() if line.startswith("apptainer build --sandbox ")]
        self.assertEqual(len(sandboxes), 1)
        self.assertTrue(sandboxes[0].endswith(" " + pins()["base_uri"]), sandboxes[0])
        self.assertEqual(len(harness.sif_builds()), 1)

    def test_tools_install_from_the_two_locks_with_no_solve(self):
        harness = Harness(self)
        self.assertEqual(harness.run().returncode, 0)
        creates = [line for line in harness.calls() if "/usr/bin/micromamba create" in line]
        self.assertEqual(len(creates), 2)
        self.assertIn("-p /opt/lge/env --file /opt/lge/lge-tools-linux-64-explicit.txt", creates[0])
        self.assertIn("-p /opt/lge/trim_galore --file /opt/lge/trim_galore-linux-64-explicit.txt", creates[1])
        for line in creates:
            for flag in (" -c ", " --channel", " -n ", " --name", " --dry-run", " --override-channels"):
                self.assertNotIn(flag, line)

    def test_manifest_step_names_both_prefixes_and_the_image_path(self):
        harness = Harness(self)
        self.assertEqual(harness.run().returncode, 0)
        manifest_calls = [line for line in harness.calls() if "lungfish-executor.build-only image-manifest" in line]
        self.assertEqual(len(manifest_calls), 1)
        self.assertTrue(
            manifest_calls[0].endswith(
                "image-manifest --conda-prefix /opt/lge/env --conda-prefix /opt/lge/trim_galore --output /opt/lungfish/image-manifest.json"
            ),
            manifest_calls[0],
        )

    def test_executor_is_gone_from_the_sandbox_before_the_sif_is_built(self):
        harness = Harness(self)
        self.assertEqual(harness.run().returncode, 0)
        calls = harness.calls()
        manifest_call = next(i for i, line in enumerate(calls) if "lungfish-executor.build-only image-manifest" in line)
        self.assertLess(manifest_call, calls.index("sif-build executor_in_sandbox=no"))
        self.assertNotIn("sif-build executor_in_sandbox=yes", calls)
        snapshot = harness.state / "snapshot"
        self.assertTrue((snapshot / "opt" / "lungfish" / "image-manifest.json").is_file())
        self.assertEqual([path for path in snapshot.rglob("*") if path.name.startswith("lungfish-executor")], [])
        self.assertEqual((harness.inputs / "lungfish-executor").read_bytes(), b"\x7fELF a stand-in executor\n")

    def test_executor_left_in_the_sandbox_fails_the_build(self):
        harness = Harness(self)
        result = harness.run(FAKE_STRAY_EXECUTOR="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(parse_record(result.stdout)["STATUS"], "failed step=executor_remove")
        self.assertIn("the image would hold the executor", result.stdout)
        self.assertEqual(harness.sif_builds(), [])

    def test_missing_wrapper_utility_fails_the_build_before_any_install(self):
        for utility in ("dirname", "basename", "readlink"):
            with self.subTest(utility=utility):
                harness = Harness(self)
                result = harness.run(FAKE_MISSING=utility)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(parse_record(result.stdout)["STATUS"], "failed step=utilities")
                self.assertIn("no working " + utility, result.stdout)
                self.assertFalse(any("/usr/bin/micromamba" in line for line in harness.calls()))
                self.assertEqual(harness.sif_builds(), [])

    def test_lock_that_differs_from_its_pin_is_refused_before_any_build(self):
        harness = Harness(self)
        lock = harness.inputs / "trim_galore-linux-64-explicit.txt"
        lock.write_text(lock.read_text() + "# edited after the pin\n")
        result = harness.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(parse_record(result.stdout)["STATUS"], "failed step=inputs")
        self.assertIn("trim_galore-linux-64-explicit.txt has SHA-256", result.stdout)
        self.assertFalse(any(line.startswith("apptainer build") for line in harness.calls()))

    def test_missing_executor_input_is_refused_before_any_build(self):
        harness = Harness(self)
        (harness.inputs / "lungfish-executor").unlink()
        result = harness.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(parse_record(result.stdout)["STATUS"], "failed step=inputs")
        self.assertFalse(any(line.startswith("apptainer build") for line in harness.calls()))

    def test_manifest_missing_a_lock_tool_fails_the_build(self):
        harness = Harness(self)
        result = harness.run(FAKE_MANIFEST_OMIT="trim_galore")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(parse_record(result.stdout)["STATUS"], "failed step=manifest_check")
        self.assertIn("the manifest lists no tool trim_galore", result.stdout)
        self.assertEqual(harness.sif_builds(), [])

    def test_failed_build_leaves_every_transfer_output_in_place_and_the_sif_empty(self):
        harness = Harness(self)
        result = harness.run(FAKE_MISSING="dirname")
        self.assertNotEqual(result.returncode, 0)
        for name in transfer_outputs():
            self.assertTrue((harness.work / name).is_file(), name + " is listed in transfer_output_files and is missing")
        self.assertEqual((harness.work / "lge-tools.sif").stat().st_size, 0)
        self.assertNotIn("SIF_SHA256", parse_record(result.stdout))
        self.assertEqual(result.stdout.strip().splitlines()[-1], "LGE_IMAGE_STATUS=failed step=utilities")


if __name__ == "__main__":
    unittest.main()
