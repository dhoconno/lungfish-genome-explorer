"""Cheap structural checks for the shared CLI package/Xcode compiler graph."""
from pathlib import Path
import json
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class ReleaseBuildGraphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(ROOT / "Lungfish.xcodeproj/project.pbxproj")],
            check=True, capture_output=True, text=True,
        )
        cls.project = json.loads(result.stdout)
        cls.objects = cls.project["objects"]
        cls.targets = {value["name"]: value for value in cls.objects.values() if value["isa"] == "PBXNativeTarget"}

    def test_native_cli_links_library_and_shared_wrapper(self):
        cli = self.targets["LungfishCLIExecutable"]
        self.assertEqual(cli["productType"], "com.apple.product-type.tool")
        products = [self.objects[key]["productName"] for key in cli["packageProductDependencies"]]
        self.assertEqual(products, ["LungfishCLILibrary"])
        sources = [self.objects[key] for key in cli["buildPhases"] if self.objects[key]["isa"] == "PBXSourcesBuildPhase"]
        files = [self.objects[self.objects[key]["fileRef"]]["path"] for key in sources[0]["files"]]
        self.assertEqual(files, ["Sources/LungfishCLIExecutable/EntryPoint.swift"])
        configs = self.objects[cli["buildConfigurationList"]]["buildConfigurations"]
        for config in configs:
            settings = self.objects[config]["buildSettings"]
            self.assertEqual(settings["SKIP_INSTALL"], "YES")
            self.assertEqual(settings["CREATE_INFOPLIST_SECTION_IN_BINARY"], "YES")
            self.assertEqual(settings["INFOPLIST_FILE"], "$(LUNGFISH_CLI_INFOPLIST_FILE)")
            self.assertEqual(settings["EXECUTABLE_NAME"], "lungfish-cli")

    def test_app_depends_on_and_copies_native_cli_product(self):
        app = self.targets["Lungfish"]
        dependencies = [self.objects[self.objects[key]["target"]]["name"] for key in app["dependencies"]]
        self.assertIn("LungfishCLIExecutable", dependencies)
        copy_phases = [self.objects[key] for key in app["buildPhases"] if self.objects[key]["isa"] == "PBXCopyFilesBuildPhase"]
        self.assertEqual(len(copy_phases), 1)
        self.assertEqual(str(copy_phases[0]["dstSubfolderSpec"]), "6")  # Executables (Contents/MacOS)
        refs = [self.objects[key]["fileRef"] for key in copy_phases[0]["files"]]
        self.assertEqual(refs, [self.targets["LungfishCLIExecutable"]["productReference"]])
        for value in self.objects.values():
            if value["isa"] == "PBXShellScriptBuildPhase":
                self.assertNotIn("swift build", value["shellScript"])

    def test_archive_scheme_and_builder_use_only_native_graph(self):
        scheme = ET.parse(ROOT / "Lungfish.xcodeproj/xcshareddata/xcschemes/Lungfish.xcscheme")
        names = {entry.find("BuildableReference").attrib["BlueprintName"] for entry in scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry") if entry.attrib["buildForArchiving"] == "YES"}
        self.assertEqual(names, {"Lungfish", "LungfishCLIExecutable"})
        builder = (ROOT / "scripts/release/build-notarized-dmg.sh").read_text()
        self.assertNotIn("xcrun swift build", builder)
        self.assertNotIn("LUNGFISH_SKIP_EMBED_LUNGFISH_CLI", builder)
        self.assertIn('if [ ! -x "$CLI_DEST" ]', builder)

    def test_package_keeps_cli_product_and_module_names(self):
        manifest = (ROOT / "Package.swift").read_text()
        self.assertRegex(manifest, r'name: "lungfish-cli",\s*targets: \["LungfishCLIExecutable"\]')
        self.assertIn('.library(name: "LungfishCLILibrary", targets: ["LungfishCLI"])', manifest)
        self.assertRegex(manifest, r'\.target\(\s*name: "LungfishCLI"')
        self.assertIn("public static func main() async", (ROOT / "Sources/LungfishCLI/LungfishCLI.swift").read_text())
        self.assertIn("await LungfishCLIMain.main()", (ROOT / "Sources/LungfishCLIExecutable/EntryPoint.swift").read_text())


if __name__ == "__main__":
    unittest.main()
