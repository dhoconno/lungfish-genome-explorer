import Foundation
import Testing

@Suite("Release Build Configuration")
struct ReleaseBuildConfigurationTests {

    @Test("Xcode Release configuration pins arm64 only")
    func xcodeReleaseConfigurationPinsArm64Only() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let releaseBlock = try Self.buildConfigurationBlock(
            named: "F1E2D3C4B5A6978877665559 /* Release */",
            in: project
        )

        #expect(releaseBlock.contains("ARCHS = arm64;"))
        #expect(releaseBlock.contains("EXCLUDED_ARCHS = x86_64;"))
        #expect(releaseBlock.contains("ONLY_ACTIVE_ARCH = YES;"))
        #expect(releaseBlock.contains("ENABLE_HARDENED_RUNTIME = YES;"))
    }

    @Test("Xcode app bundle metadata uses 2026 Dave O'Connor copyright")
    func xcodeAppBundleMetadataUsesDaveOConnorCopyright() throws {
        // The copyright (and the rest of the static Info.plist content) now lives
        // in the shared source Info.plist that the xcodeproj consumes via
        // INFOPLIST_FILE, rather than in per-config INFOPLIST_KEY_* settings.
        let plist = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish-Info.plist"),
            encoding: .utf8
        )
        #expect(plist.contains("Copyright © 2026 Dave O'Connor. MIT License."))

        // Both app build configurations must point at the shared plist with
        // generation disabled, so the document types reach the notarized build.
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let releaseBlock = try Self.buildConfigurationBlock(
            named: "F1E2D3C4B5A6978877665559 /* Release */",
            in: project
        )
        let debugBlock = try Self.buildConfigurationBlock(
            named: "F1E2D3C4B5A6978877665558 /* Debug */",
            in: project
        )
        for block in [releaseBlock, debugBlock] {
            #expect(block.contains("INFOPLIST_FILE = \"Lungfish-Info.plist\";"))
            #expect(block.contains("GENERATE_INFOPLIST_FILE = NO;"))
        }
    }

    @Test("Fallback build-app script builds arm64 release binary")
    func buildAppScriptBuildsArm64ReleaseBinary() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("swift build -c release --arch arm64"))
        #expect(script.contains(".build/arm64-apple-macosx/release"))
    }

    @Test("Fallback build-app script uses the Xcode app bundle identifiers")
    func buildAppScriptUsesXcodeAppBundleIdentifiers() throws {
        let repositoryRoot = Self.repositoryRoot()
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let releaseBlock = try Self.buildConfigurationBlock(
            named: "F1E2D3C4B5A6978877665559 /* Release */",
            in: project
        )

        #expect(releaseBlock.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lungfish.browser;"))
        #expect(script.contains(#"BUNDLE_ID="com.lungfish.browser""#))
        #expect(script.contains(#"DEBUG_BUNDLE_ID="com.lungfish.browser.debug""#))
        #expect(script.contains("org.lungfish.genome-browser") == false)
    }

    @Test("Fallback build-app script supports debug app bundles")
    func buildAppScriptSupportsDebugConfiguration() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("--configuration"))
        #expect(script.contains(".build/arm64-apple-macosx/debug"))
        #expect(script.contains("build/Debug/$APP_NAME.app"))
        #expect(script.contains("swift build --arch arm64"))
    }

    @Test("Fallback build-app script can reuse an existing SwiftPM build")
    func buildAppScriptCanReuseExistingSwiftPMBuild() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("--skip-build"))
        #expect(script.contains("SKIP_BUILD=0"))
        #expect(script.contains("SKIP_BUILD=1"))
        #expect(script.contains(#"if [ "$SKIP_BUILD" -eq 1 ]"#))
        #expect(script.contains("Reusing existing Apple Silicon"))
    }

    @Test("Fallback build-app script copies SwiftPM runtime resource bundles")
    func buildAppScriptCopiesSwiftPMRuntimeResourceBundles() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("find \"$BUILD_DIR\" -maxdepth 1 -type d -name '*.bundle'"))
        #expect(script.contains("sanitize-bundled-tools.sh"))
        #expect(script.contains("lungfish-cli"))
    }

    @Test("Fallback build-app script embeds Sparkle framework for local launch")
    func buildAppScriptEmbedsSparkleFrameworkForLocalLaunch() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("FRAMEWORKS_DIR=\"$CONTENTS_DIR/Frameworks\""))
        #expect(script.contains("Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"))
        #expect(script.contains(#"/usr/bin/ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework""#))
        #expect(script.contains(#"install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Lungfish""#))
    }

    @Test("Fallback build-app script ad-hoc signs bundles for local launch")
    func buildAppScriptAdHocSignsBundlesForLocalLaunch() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains(#"codesign --force --deep --sign - "$APP_DIR""#))
        #expect(script.contains(#"codesign --verify --deep --strict --verbose=4 "$APP_DIR""#))
    }

    @Test("Fallback build-app script signs embedded CLI with CLI entitlements before app bundle")
    func buildAppScriptSignsEmbeddedCLIWithCLIEntitlementsBeforeAppBundle() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let cliSignMarker = #"codesign --force --sign - --options runtime --entitlements "$CLI_ENTITLEMENTS" "$MACOS_DIR/lungfish-cli""#

        #expect(script.contains(#"CLI_ENTITLEMENTS="$PROJECT_ROOT/lungfish-cli.entitlements""#))
        #expect(script.contains(cliSignMarker))

        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard let cliSignIndex = lines.firstIndex(where: { $0.contains(cliSignMarker) }),
              let appSignIndex = lines.firstIndex(where: {
                  $0.contains(#"codesign --force --deep --sign - "$APP_DIR""#)
              })
        else {
            Issue.record("expected fallback build to sign lungfish-cli before signing the app bundle")
            return
        }

        #expect(cliSignIndex < appSignIndex)
    }

    @Test("Fallback build-app script sanitizes copied workflow tools from flat SwiftPM bundles")
    func buildAppScriptSanitizesCopiedWorkflowToolsFromFlatBundleLayout() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains("WORKFLOW_BUNDLE_DIR=\"$RESOURCES_DIR/LungfishGenomeBrowser_LungfishWorkflow.bundle\""))
        #expect(script.contains("WORKFLOW_TOOLS_DIR=\"$WORKFLOW_BUNDLE_DIR/Tools\""))
        #expect(script.contains("WORKFLOW_TOOLS_DIR=\"$WORKFLOW_BUNDLE_DIR/Contents/Resources/Tools\""))
        #expect(script.contains("sanitize-bundled-tools.sh"))
    }

    @Test("Fallback build-app script sanitizes release MacOS executables and workflow tools")
    func buildAppScriptSanitizesReleaseMacOSExecutablesAndWorkflowTools() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(script.contains(#"if [ "$CONFIGURATION" = "release" ]"#))
        #expect(script.contains(#"sanitize-bundled-tools.sh" "$MACOS_DIR" "$WORKFLOW_TOOLS_DIR""#))
        #expect(script.contains(#"sanitize-bundled-tools.sh" "$WORKFLOW_TOOLS_DIR""#))
    }

    @Test("Native tool bundler defaults to arm64")
    func nativeToolBundlerDefaultsToArm64() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/bundle-native-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains("TARGET_ARCH=\"arm64\""))
        #expect(script.contains("default: arm64"))
    }

    @Test("Native tool bundler stages only micromamba")
    func nativeToolBundlerStagesOnlyMicromamba() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/bundle-native-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains("download_micromamba"))
        #expect(script.contains("create_universal_micromamba"))
        #expect(script.contains("remove_retired_bundle_entries"))
        #expect(script.contains("curl --fail --location --silent --show-error"))
        #expect(script.contains("--retry-all-errors"))
        #expect(script.contains("SOURCE_DATE_EPOCH"))
        #expect(script.contains("LUNGFISH_BUILD_TIMESTAMP"))
        #expect(script.contains("RESOLVED_BUILD_TIMESTAMP_ISO"))
        #expect(script.contains("RESOLVED_BUILD_TIMESTAMP_DISPLAY"))
        #expect(script.contains("tool-versions.json"))
        #expect(script.contains("%Y-%m-%dT%H:%M:%SZ"))
        #expect(script.contains("build_samtools") == false)
        #expect(script.contains("build_bcftools") == false)
        #expect(script.contains("build_htslib") == false)
        #expect(script.contains("download_ucsc_tools") == false)
    }

    @Test("Retired standalone cutadapt bundler is removed")
    func retiredStandaloneCutadaptBundlerIsRemoved() {
        let scriptURL = Self.repositoryRoot().appendingPathComponent("scripts/build-cutadapt.sh")

        #expect(FileManager.default.fileExists(atPath: scriptURL.path) == false)
    }

    @Test("CLI signing helper resolves release binary through SwiftPM")
    func cliSigningHelperResolvesReleaseBinaryThroughSwiftPM() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot().appendingPathComponent("sign-cli.sh"),
            encoding: .utf8
        )

        #expect(script.contains("--configuration release"))
        #expect(script.contains("--show-bin-path"))
        #expect(script.contains(".build/release/lungfish-cli") == false)
    }

    @Test("Shared CLI locator avoids hardcoded SwiftPM executable paths")
    func sharedCLILocatorAvoidsHardcodedSwiftPMExecutablePaths() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sources = [
            "Sources/LungfishKit/CLIBinaryLocator.swift",
            "Sources/LungfishKit/LungfishCLIRunner.swift",
            "Sources/LungfishApp/Services/CLIImportRunner.swift",
        ]

        for sourcePath in sources {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(sourcePath),
                encoding: .utf8
            )
            #expect(source.contains(".build/release/lungfish-cli") == false)
            #expect(source.contains(".build/arm64-apple-macosx/debug/lungfish-cli") == false)
            #expect(source.contains(".build/debug/lungfish-cli") == false)
        }

        let locatorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/LungfishKit/CLIBinaryLocator.swift"),
            encoding: .utf8
        )
        #expect(locatorSource.contains("--show-bin-path"))
    }

    @Test("CLI subprocess tests resolve binaries through SwiftPM bin path")
    func cliSubprocessTestsResolveBinariesThroughSwiftPMBinPath() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sources = [
            "Tests/LungfishCLITests/ApplicationExportImportE2ETests.swift",
            "Tests/LungfishCLITests/CLIExitCodeProcessTests.swift",
            "Tests/LungfishCLITests/ExtractContigsCommandTests.swift",
            "Tests/LungfishCLITests/ImportFastqE2ETests.swift",
            "Tests/LungfishCLITests/ImportMSATreeE2ETests.swift",
            "Tests/LungfishCLITests/MarkdupCommandTests.swift",
            "Tests/LungfishIntegrationTests/CLIBAMFilteringIntegrationTests.swift",
            "Tests/LungfishXCUITests/TestSupport/AssemblyRobot.swift",
            "Tests/LungfishXCUITests/TestSupport/BundleBrowserRobot.swift",
            "Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift",
            "Tests/LungfishXCUITests/TestSupport/MappingRobot.swift",
        ]

        for sourcePath in sources {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(sourcePath),
                encoding: .utf8
            )
            #expect(source.contains(".build/release/lungfish-cli") == false)
            #expect(source.contains(".build/arm64-apple-macosx/debug/lungfish-cli") == false)
            #expect(source.contains(".build/x86_64-apple-macosx/debug/lungfish-cli") == false)
            #expect(source.contains(".build/debug/lungfish-cli") == false)
        }
    }

    @Test("Primer-trim GUI integration locates CLI through SwiftPM bin path")
    func primerTrimGUIIntegrationLocatesCLIThroughSwiftPMBinPath() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimGUIIntegrationTests.swift"),
            encoding: .utf8
        )

        #expect(source.contains("--show-bin-path"))
        #expect(source.contains(".build/release/lungfish-cli") == false)
        #expect(source.contains(".build/debug/lungfish-cli") == false)
    }

    @Test("Bundled tool manifest keeps only micromamba")
    func bundledToolManifestKeepsOnlyMicromamba() throws {
        let manifest = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"),
            encoding: .utf8
        )

        #expect(manifest.contains(#""name": "micromamba""#))
        #expect(manifest.contains(#""name": "samtools""#) == false)
        #expect(manifest.contains(#""name": "bcftools""#) == false)
        #expect(manifest.contains(#""name": "fastp""#) == false)
        #expect(manifest.contains(#""name": "seqkit""#) == false)
        #expect(manifest.contains(#""name": "vsearch""#) == false)
        #expect(manifest.contains(#""name": "cutadapt""#) == false)
    }

    @Test("Release tools sanitizer preserves Mach-O binaries and strips non-executables")
    func releaseToolsSanitizerPreservesMachOBinariesAndStripsNonExecutables() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sanitizerURL = repositoryRoot.appendingPathComponent("scripts/sanitize-bundled-tools.sh")
        #expect(FileManager.default.fileExists(atPath: sanitizerURL.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolsRoot = tempRoot.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let micromambaURL = toolsRoot.appendingPathComponent("micromamba")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: micromambaURL)
        let scriptURL = toolsRoot.appendingPathComponent("wrapper.sh")
        try "#!/bin/bash\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try Self.makeExecutable(scriptURL)
        let textURL = toolsRoot.appendingPathComponent("VERSIONS.txt")
        try "micromamba only\n".write(to: textURL, atomically: true, encoding: .utf8)

        let repoRootString = repositoryRoot.path
        let binaryEmbeddedPaths = [
            "prefix\0\(repoRootString)/.build/tools/build\0",
            "prefix\0/opt/homebrew/bin\0",
        ].joined()
        let binaryHandle = try FileHandle(forWritingTo: micromambaURL)
        try binaryHandle.seekToEnd()
        try binaryHandle.write(contentsOf: Data(binaryEmbeddedPaths.utf8))
        try binaryHandle.close()

        // Scripts (non-Mach-O) are intentionally left untouched by the sanitizer.
        // Keep the historical "browser" path literal here to prove that.
        let scriptEmbeddedPaths = """
        /Users/dho/Documents/lungfish-genome-browser/.build/tools/build
        /opt/homebrew/bin
        """
        let scriptHandle = try FileHandle(forWritingTo: scriptURL)
        try scriptHandle.seekToEnd()
        try scriptHandle.write(contentsOf: Data(scriptEmbeddedPaths.utf8))
        try scriptHandle.close()

        try Self.runScript(sanitizerURL, arguments: [toolsRoot.path])

        #expect(FileManager.default.isExecutableFile(atPath: micromambaURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: scriptURL.path) == false)
        #expect(FileManager.default.isExecutableFile(atPath: textURL.path) == false)

        let sanitizedBinary = String(decoding: try Data(contentsOf: micromambaURL), as: UTF8.self)
        let sanitizedScript = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(sanitizedBinary.contains("/Users/dho") == false)
        #expect(sanitizedBinary.contains("/opt/homebrew") == false)
        #expect(sanitizedScript.contains("/Users/dho/Documents/lungfish-genome-browser/.build/tools/build"))
        #expect(sanitizedScript.contains("/opt/homebrew/bin"))
    }

    @Test("Xcode Release build runs tools sanitizer")
    func xcodeReleaseBuildRunsToolsSanitizer() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        #expect(project.contains("Sanitize bundled tools"))
        #expect(project.contains("sanitize-bundled-tools.sh"))
        #expect(project.contains(#"if [ \"$CONFIGURATION\" = \"Release\" ]"#))
        #expect(project.contains("INSTALLATION_BUILD_PRODUCTS_LOCATION"))
        #expect(project.contains("UninstalledProducts/macosx"))
        #expect(project.contains("EXECUTABLE_FOLDER_PATH"))
        #expect(
            project.contains(
                """
                F1E2D3C4B5A6978877665567 /* Embed lungfish-cli */,
                \t\t\t\tF1E2D3C4B5A6978877665566 /* Index Help Book */,
                \t\t\t\tF1E2D3C4B5A6978877665568 /* Sanitize bundled tools */,
                """
            )
        )
    }

    @Test("Embed lungfish-cli phase signs CLI with hardened runtime")
    func embedLungfishCLIPhaseSignsCLIWithHardenedRuntime() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        #expect(project.contains("Embed lungfish-cli"))
        #expect(project.contains("EXPANDED_CODE_SIGN_IDENTITY"))
        #expect(project.contains("codesign --force --sign"))
        #expect(project.contains("--options runtime"))
        #expect(project.contains("lungfish-cli.entitlements"))
    }

    @Test("Embed lungfish-cli phase always refreshes bundled CLI")
    func embedLungfishCLIPhaseAlwaysRefreshesBundledCLI() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        let embedBlock = try Self.buildPhaseBlock(
            named: "F1E2D3C4B5A6978877665567 /* Embed lungfish-cli */",
            in: project
        )
        #expect(embedBlock.contains("alwaysOutOfDate = 1;"))
        #expect(embedBlock.contains("--product lungfish-cli"))
        #expect(embedBlock.contains(".build/xcode-cli"))
        #expect(embedBlock.contains("install -m 755"))
    }

    @Test("Embed lungfish-cli phase supports scripted release skip override")
    func embedLungfishCLIPhaseSupportsScriptedReleaseSkipOverride() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        let embedBlock = try Self.buildPhaseBlock(
            named: "F1E2D3C4B5A6978877665567 /* Embed lungfish-cli */",
            in: project
        )
        #expect(embedBlock.contains("LUNGFISH_SKIP_EMBED_LUNGFISH_CLI"))
    }

    @Test("Xcode project compiles every checked-in XCUITest file reference")
    func xcodeProjectCompilesEveryCheckedInXCUITestFileReference() throws {
        let repositoryRoot = Self.repositoryRoot()
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let xcuiRoot = repositoryRoot.appendingPathComponent("Tests/LungfishXCUITests", isDirectory: true)
        let checkedInSwiftFiles = try Self.swiftFiles(in: xcuiRoot, relativeTo: repositoryRoot)

        #expect(!checkedInSwiftFiles.isEmpty)
        for relativePath in checkedInSwiftFiles {
            let filename = URL(fileURLWithPath: relativePath).lastPathComponent
            #expect(project.contains("path = \(relativePath);"), "\(relativePath) should be referenced by the Xcode project")
            #expect(project.contains("\(filename) in Sources"), "\(relativePath) should be compiled by LungfishXCUITests")
        }
    }

    @Test("Sanitize bundled tools phase supports scripted release skip override")
    func sanitizeBundledToolsPhaseSupportsScriptedReleaseSkipOverride() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        let sanitizeBlock = try Self.buildPhaseBlock(
            named: "F1E2D3C4B5A6978877665568 /* Sanitize bundled tools */",
            in: project
        )
        #expect(sanitizeBlock.contains("LUNGFISH_SKIP_SANITIZE_BUNDLED_TOOLS"))
    }

    @Test("Release smoke test asserts micromamba remains bundled and retired tools are absent")
    func releaseSmokeTestAssertsMicromambaRemainsBundledAndRetiredToolsAreAbsent() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/smoke-test-release-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains(#"if [ ! -x "$TOOLS_DIR/micromamba" ]"#))
        #expect(script.contains("retired tool should not be bundled:"))
        #expect(script.contains(#"$TOOLS_DIR/bbtools"#))
        #expect(script.contains(#"$TOOLS_DIR/jre"#))
        #expect(script.contains(#"$TOOLS_DIR/fastp"#))
        #expect(script.contains(#"$TOOLS_DIR/samtools"#))
        #expect(script.contains(#"$TOOLS_DIR/bgzip"#))
        #expect(script.contains(#"$TOOLS_DIR/tabix"#))
        #expect(script.contains(#"$TOOLS_DIR/bedToBigBed"#))
        #expect(script.contains(#"$TOOLS_DIR/bedGraphToBigWig"#))
        #expect(script.contains(#"$TOOLS_DIR/seqkit"#))
        #expect(script.contains(#"$TOOLS_DIR/scrubber/bin/aligns_to"#))
        #expect(script.contains("unexpected bundled tool entry"))
        #expect(script.contains("tool metadata still references retired tool"))
        #expect(script.contains("version summary still references retired tool"))
        #expect(script.contains("bcftools \\\n    tabix \\\n    htslib"))
        #expect(script.contains("run_test micromamba "))
        #expect(script.contains(#"CLI_BIN="$APP_PATH/Contents/MacOS/lungfish-cli""#))
        #expect(script.contains("run_test lungfish-cli-version "))
        #expect(script.contains("run_test lungfish-cli-tools "))
        #expect(script.contains("run_test lungfish-cli-qc-summary "))
        #expect(script.contains(#"$QC_OUTPUT.lungfish-provenance.json"#))
        #expect(script.contains("run_test samtools ") == false)
        #expect(script.contains("run_test seqkit ") == false)
    }

    @Test("Update tool versions script refreshes micromamba metadata only")
    func updateToolVersionsScriptRefreshesMicromambaMetadataOnly() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/update-tool-versions.sh"),
            encoding: .utf8
        )

        #expect(script.contains("micromamba is pinned at"))
        #expect(script.contains("tool-versions.json"))
        #expect(script.contains("VERSIONS.txt"))
        #expect(script.contains("%Y-%m-%dT%H:%M:%SZ"))
        #expect(script.contains(#"--arch "$target_arch""#))
        #expect(script.contains("SOURCE_DATE_EPOCH"))
        #expect(script.contains("LUNGFISH_BUILD_TIMESTAMP"))
        #expect(script.contains("RESOLVED_BUILD_TIMESTAMP_ISO"))
        #expect(script.contains("RESOLVED_BUILD_TIMESTAMP_DISPLAY"))
        #expect(script.contains(#"export LUNGFISH_BUILD_TIMESTAMP="$RESOLVED_BUILD_TIMESTAMP_ISO""#))
        #expect(script.contains("samtools") == false)
        #expect(script.contains("bcftools") == false)
        #expect(script.contains("htslib") == false)
        #expect(script.contains("seqkit") == false)
    }

    @Test("Notarized DMG release script no longer signs retired bundled payloads")
    func notarizedDMGReleaseScriptNoLongerSignsRetiredBundledPayloads() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("sign_jre_launcher") == false)
        #expect(script.contains("jre/bin/java") == false)
        #expect(script.contains("scrubber/bin/aligns_to") == false)
        #expect(script.contains("fastp") == false)
    }

    @Test("Notarized DMG release script fails early if ripgrep is unavailable")
    func notarizedDMGReleaseScriptFailsEarlyIfRipgrepIsUnavailable() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("require_command rg"))
    }

    @Test("Release smoke test resolves ripgrep from PATH instead of /usr/bin")
    func releaseSmokeTestResolvesRipgrepFromPath() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/smoke-test-release-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains("command -v rg"))
        #expect(script.contains("/usr/bin/rg") == false)
    }

    @Test("Release smoke test scans for Homebrew path leaks")
    func releaseSmokeTestScansForHomebrewPathLeaks() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/smoke-test-release-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains(#""/opt/homebrew""#))
        #expect(script.contains(#""/usr/local/Cellar""#))
        #expect(script.contains(#""/usr/local/Homebrew""#))
    }

    @Test("Production sources avoid hardcoded Homebrew path fallbacks")
    func productionSourcesAvoidHardcodedHomebrewPathFallbacks() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sourcesRoot = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(source.contains("/opt/homebrew") == false, "\(fileURL.lastPathComponent) still hardcodes /opt/homebrew")
            #expect(source.contains("/usr/local/Cellar") == false, "\(fileURL.lastPathComponent) still hardcodes /usr/local/Cellar")
        }
    }

    @Test("Notarized DMG release script archives signs notarizes and staples")
    func notarizedDMGReleaseScriptArchivesSignsNotarizesAndStaples() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("xcodebuild -project Lungfish.xcodeproj"))
        #expect(script.contains("--product lungfish-cli"))
        #expect(script.contains("Contents/MacOS/lungfish-cli"))
        #expect(script.contains("WORKFLOW_TOOLS_DIR"))
        #expect(script.contains("notarytool submit"))
        #expect(script.contains("stapler staple"))
        #expect(script.contains("hdiutil create"))
        #expect(script.contains("DMG_PATH"))
        #expect(script.contains("release-metadata.txt"))
    }

    @Test("Notarized DMG release script installs app icon before signing and DMG staging")
    func notarizedDMGReleaseScriptInstallsAppIconBeforeSigningAndDMGStaging() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains(#"APP_ICON_SOURCE="${PROJECT_ROOT}/Sources/Lungfish/AppIcon.icns""#))
        #expect(script.contains(#"APP_ICON_DEST="${APP_PATH}/Contents/Resources/AppIcon.icns""#))
        #expect(script.contains(#"/usr/bin/install -m 644 "$APP_ICON_SOURCE" "$APP_ICON_DEST""#))
        #expect(script.contains(#"Set :CFBundleIconFile AppIcon"#))
        #expect(script.contains(#"Set :CFBundleIconName AppIcon"#))

        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard let installIndex = lines.firstIndex(where: {
            $0.contains(#"/usr/bin/install -m 644 "$APP_ICON_SOURCE" "$APP_ICON_DEST""#)
        }) else {
            Issue.record("expected AppIcon.icns installation in release script")
            return
        }

        guard let firstCodesignIndex = lines.firstIndex(where: {
            $0.contains(#"/usr/bin/codesign --force --sign "$SIGNING_IDENTITY""#)
        }) else {
            Issue.record("expected codesign invocation in release script")
            return
        }

        guard let dmgStageIndex = lines.firstIndex(where: {
            $0.contains(#"/usr/bin/ditto "$APP_PATH" "${DMG_STAGING_DIR}/Lungfish.app""#)
        }) else {
            Issue.record("expected DMG staging copy in release script")
            return
        }

        #expect(installIndex < firstCodesignIndex)
        #expect(installIndex < dmgStageIndex)
    }

    @Test("Notarized DMG release script signs outer app with app entitlements")
    func notarizedDMGReleaseScriptSignsOuterAppWithAppEntitlements() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        guard let appSigningBlock = Self.commandBlock(containing: #""$APP_PATH""#, in: script) else {
            Issue.record("expected outer app codesign block in release script")
            return
        }

        #expect(appSigningBlock.contains(#"--entitlements "${PROJECT_ROOT}/lungfish-cli.entitlements""#))
        #expect(appSigningBlock.contains("--generate-entitlement-der"))
        #expect(appSigningBlock.contains(#""$APP_PATH""#))
    }

    @Test("Shared Info.plist declares Lungfish workflow bundle type")
    func sharedInfoPlistDeclaresWorkflowBundleType() throws {
        // The document-type and exported-UTI declarations live in the single
        // shared source Info.plist consumed by both build paths (the xcodeproj
        // via INFOPLIST_FILE and scripts/build-app.sh via cp + plutil).
        let plist = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish-Info.plist"),
            encoding: .utf8
        )

        #expect(plist.contains("<string>org.lungfish.workflow</string>"))
        #expect(plist.contains("<string>lungfishflow</string>"))
        #expect(plist.contains("<string>com.apple.package</string>"))

        // build-app.sh must consume the shared plist rather than embed its own.
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        #expect(script.contains("Lungfish-Info.plist"))
    }

    @Test("Notarized DMG release script builds CLI with prefix maps")
    func notarizedDMGReleaseScriptBuildsCLIWithPrefixMaps() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("-debug-prefix-map"))
        #expect(script.contains("-file-compilation-dir"))
        #expect(script.contains("ffile-prefix-map"))
        #expect(script.contains("OTHER_SWIFT_FLAGS"))
        #expect(script.contains("OTHER_CFLAGS"))
        #expect(script.contains("OTHER_CPLUSPLUSFLAGS"))
        #expect(script.contains("LUNGFISH_BUILD_TIMESTAMP"))
        #expect(script.contains("SOURCE_DATE_EPOCH"))
    }

    @Test("Notarized DMG release script preserves inherited archive Swift flags")
    func notarizedDMGReleaseScriptPreservesInheritedArchiveSwiftFlags() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("OTHER_SWIFT_FLAGS=\"\\$(inherited) $XCODE_OTHER_SWIFT_FLAGS\""))
    }

    @Test("Notarized DMG release script preserves derived data cache across runs")
    func notarizedDMGReleaseScriptPreservesDerivedDataCacheAcrossRuns() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("${RELEASE_DIR}/DerivedData") == false)
        #expect(script.contains("$PROJECT_ROOT/.build") || script.contains("${PROJECT_ROOT}/.build"))
    }

    @Test("Notarized DMG release script supports explicit build reuse")
    func notarizedDMGReleaseScriptSupportsExplicitBuildReuse() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("--reuse-archive"))
        #expect(script.contains("--reuse-built-cli"))
        #expect(script.contains("REUSE_ARCHIVE=0"))
        #expect(script.contains("REUSE_BUILT_CLI=0"))
        #expect(script.contains(#"if [ "$REUSE_ARCHIVE" -eq 1 ]"#))
        #expect(script.contains(#"if [ "$REUSE_BUILT_CLI" -eq 1 ]"#))
    }

    @Test("Notarized DMG release metadata redacts local signing details")
    func notarizedDMGReleaseMetadataRedactsLocalSigningDetails() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("signing_identity=<redacted>"))
        #expect(script.contains("team_id=<redacted>"))
        #expect(script.contains("notary_profile=<redacted>"))
        #expect(script.contains("signing_identity=${SIGNING_IDENTITY}") == false)
        #expect(script.contains("team_id=${TEAM_ID}") == false)
        #expect(script.contains("notary_profile=${NOTARY_PROFILE}") == false)
    }

    @Test("Notarized DMG release metadata avoids absolute project paths")
    func notarizedDMGReleaseMetadataAvoidsAbsoluteProjectPaths() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("relative_to_project_root"))
        #expect(script.contains("archive_path=$(relative_to_project_root \"$ARCHIVE_PATH\")"))
        #expect(script.contains("app_path=$(relative_to_project_root \"$APP_PATH\")"))
        #expect(script.contains("release_app_path=$(relative_to_project_root \"$RELEASE_APP_PATH\")"))
        #expect(script.contains("DMG_PATH=$(relative_to_project_root \"$DMG_PATH\")"))
    }

    @Test("Notarized DMG release script disables duplicate Xcode CLI embed and sanitize phases")
    func notarizedDMGReleaseScriptDisablesDuplicateXcodeCLIEmbedAndSanitizePhases() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("LUNGFISH_SKIP_EMBED_LUNGFISH_CLI=1"))
        #expect(script.contains("LUNGFISH_SKIP_SANITIZE_BUNDLED_TOOLS=1"))
    }

    @Test("Notarized DMG release script sanitizes embedded CLI before signing")
    func notarizedDMGReleaseScriptSanitizesEmbeddedCLIBeforeSigning() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        let sanitizeMarker = #"scripts/sanitize-bundled-tools.sh "$APP_PATH/Contents/MacOS""#

        #expect(script.contains(sanitizeMarker))
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard let sanitizeIndex = lines.firstIndex(where: { $0.contains(sanitizeMarker) }),
              let codesignIndex = lines.enumerated().first(where: { index, line in
                  index > sanitizeIndex
                      && line.contains(#"/usr/bin/codesign --force --sign "$SIGNING_IDENTITY""#)
              })?.offset
        else {
            Issue.record("expected CLI sanitizer to run before CLI codesign")
            return
        }

        #expect(sanitizeIndex < codesignIndex)
    }

    @Test("Notarized DMG release script no longer removes aligns_to")
    func notarizedDMGReleaseScriptNoLongerRemovesAlignsTo() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        let removalMarker = #"rm -f "$WORKFLOW_TOOLS_DIR/scrubber/bin/aligns_to""#
        #expect(script.contains(removalMarker) == false)
    }

    @Test("Notarized DMG release script runs portability scan before signing")
    func notarizedDMGReleaseScriptRunsPortabilityScanBeforeSigning() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        let scanMarker = #"scripts/smoke-test-release-tools.sh "$APP_PATH" --portability-only"#
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard let scanIndex = lines.firstIndex(where: { $0.contains(scanMarker) }),
              let codesignIndex = lines.enumerated().first(where: { _, line in
                  line.contains(#"/usr/bin/codesign --force --sign "$SIGNING_IDENTITY""#)
              })?.offset
        else {
            Issue.record("expected pre-sign portability scan before first codesign")
            return
        }

        #expect(scanIndex < codesignIndex)
    }

    @Test("Notarized DMG release script omits JRE launcher entitlements")
    func notarizedDMGReleaseScriptOmitsJRELauncherEntitlements() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("jre-launcher.entitlements") == false)
        #expect(script.contains("jre/bin/java") == false)
        #expect(script.contains("jre/bin/keytool") == false)
        #expect(script.contains("jre/lib/jspawnhelper") == false)
    }

    @Test("JRE launcher entitlements file is removed")
    func jreLauncherEntitlementsFileIsRemoved() throws {
        let entitlementsURL = Self.repositoryRoot()
            .appendingPathComponent("scripts/release/jre-launcher.entitlements")

        #expect(FileManager.default.fileExists(atPath: entitlementsURL.path) == false)
    }

    @Test("Release agent is tracked in repo")
    func releaseAgentIsTrackedInRepo() throws {
        let agent = try Self.releaseAgentCanonicalContents()

        #expect(agent.contains("name: release-agent"))
        #expect(agent.contains("scripts/release/build-notarized-dmg.sh"))
        #expect(agent.contains("scripts/smoke-test-release-tools.sh"))
        #expect(agent.contains("notarytool"))
        #expect(agent.contains(".dmg"))
    }

    @Test("Release agent mirror matches canonical definition")
    func releaseAgentMirrorMatchesCanonicalDefinition() throws {
        let root = Self.repositoryRoot()
        let canonical = try Self.releaseAgentCanonicalContents()
        let mirror = try String(
            contentsOf: root.appendingPathComponent(".codex/agents/release-agent.md"),
            encoding: .utf8
        )

        #expect(mirror == canonical)
    }

    @Test("Release agent documents versioning release notes and GitHub publication")
    func releaseAgentDocumentsVersioningReleaseNotesAndGitHubPublication() throws {
        let agent = try Self.releaseAgentCanonicalContents()
        let requiredPhrases = [
            "Determine the next version",
            "CFBundleShortVersionString",
            "lungfish-cli --version",
            "docs/release-notes/v",
            "git tag",
            "gh release create",
            "gh release view",
            "git status --short --branch"
        ]

        for phrase in requiredPhrases {
            #expect(agent.contains(phrase), "release agent is missing: \(phrase)")
        }
    }

    @Test("Release agent documents independent post build verification")
    func releaseAgentDocumentsIndependentPostBuildVerification() throws {
        let agent = try Self.releaseAgentCanonicalContents()
        let requiredPhrases = [
            "codesign --verify --deep --strict",
            "xcrun stapler validate",
            "spctl -a -vv -t open",
            "notary-app-log.json",
            "notary-dmg-log.json",
            "shasum -a 256",
            "release-metadata.txt"
        ]

        for phrase in requiredPhrases {
            #expect(agent.contains(phrase), "release agent is missing: \(phrase)")
        }
    }

    @Test("Production runtime resource lookups avoid SwiftPM Bundle.module accessors")
    func productionRuntimeResourceLookupsAvoidSwiftPMBundleModuleAccessors() throws {
        let repositoryRoot = Self.repositoryRoot()
        let runtimeSources = [
            "Sources/LungfishWorkflow/Native/NativeToolRunner.swift",
            "Sources/LungfishWorkflow/Native/ToolVersionsManifest.swift",
            "Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift",
            "Sources/LungfishWorkflow/Conda/CondaManager.swift",
            "Sources/LungfishWorkflow/Conda/ManagedToolLock.swift",
            "Sources/LungfishWorkflow/Engines/AppleContainerRuntime.swift",
            "Sources/LungfishWorkflow/Metagenomics/NaoMgsSamplePartitioner.swift",
            "Sources/LungfishWorkflow/Recipes/RecipeRegistry.swift",
            "Sources/LungfishWorkflow/Recipes/Recipe.swift",
            "Sources/LungfishApp/Views/Help/HelpWindowController.swift",
            "Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift",
            "Sources/LungfishApp/App/AppIcon.swift",
            "Sources/LungfishApp/App/AboutWindowController.swift",
        ]

        for relativePath in runtimeSources {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(source.contains("Bundle.module") == false, "\(relativePath) still references Bundle.module")
        }
    }

    @Test("CI installs Python dependencies required by script tests")
    func ciInstallsPythonDependenciesRequiredByScriptTests() throws {
        let workflow = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        #expect(workflow.contains(".ci-python/bin/python -m pip install Pillow openpyxl"))
    }

    @Test("CI fast gate runs scientific CLI provenance coverage")
    func ciFastGateRunsScientificCLIProvenanceCoverage() throws {
        let workflow = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        #expect(workflow.contains("ScientificCLIProvenanceCoverageTests"))
    }

    @Test("CI fast gate runs native scientific provenance policy coverage")
    func ciFastGateRunsNativeScientificProvenancePolicyCoverage() throws {
        let workflow = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        #expect(workflow.contains("ScientificProvenancePolicyTests"))
    }

    @Test("CI fast gate builds the Xcode project path used for release packaging")
    func ciFastGateBuildsXcodeProjectPathUsedForReleasePackaging() throws {
        let workflow = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        #expect(workflow.contains("xcodebuild -project Lungfish.xcodeproj -scheme Lungfish"))
        #expect(workflow.contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(workflow.contains("LUNGFISH_SKIP_EMBED_LUNGFISH_CLI=1"))
        #expect(workflow.contains("LUNGFISH_SKIP_SANITIZE_BUNDLED_TOOLS=1"))
    }

    @Test("Git ignore rules do not hide tracked files")
    func gitIgnoreRulesDoNotHideTrackedFiles() throws {
        let result = try Self.runCommand(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["ls-files", "-ci", "--exclude-standard"],
            currentDirectory: Self.repositoryRoot()
        )

        #expect(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Tracked files hidden by .gitignore:\n\(result.stdout)"
        )
    }

    @Test("Release GUI runtime avoids compile-time source path fallbacks")
    func releaseGUIRuntimeAvoidsCompileTimeSourcePathFallbacks() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Services/CLIImportRunner.swift"),
            encoding: .utf8
        )

        #expect(source.contains("#filePath") == false)
    }

    @Test("Release tools sanitizer scrubs builder paths from bundled executables")
    func releaseToolsSanitizerScrubsBuilderPathsFromBundledExecutables() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sanitizerURL = repositoryRoot.appendingPathComponent("scripts/sanitize-bundled-tools.sh")
        #expect(FileManager.default.fileExists(atPath: sanitizerURL.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolsRoot = tempRoot.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vendoredBinaryURL = toolsRoot.appendingPathComponent("prefetch")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: vendoredBinaryURL)
        let repoRootString = repositoryRoot.path
        let embeddedPaths = [
            "prefix\0\(repoRootString)/.build/xcode-cli-release/checkouts/test\0",
            "prefix\0/Users/dho/Documents/ncbi-vdb/libs/vfs/resolver.c\0",
            "prefix\0/usr/local/Cellar/openssl@3/3.4.0/lib/engines-3\0",
            "prefix\0/usr/local/etc/openssl@3\0",
            "prefix\0/opt/homebrew/bin\0",
        ].joined()
        let handle = try FileHandle(forWritingTo: vendoredBinaryURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(embeddedPaths.utf8))
        try handle.close()
        try Self.makeExecutable(vendoredBinaryURL)

        try Self.runScript(sanitizerURL, arguments: [toolsRoot.path])

        let sanitized = String(decoding: try Data(contentsOf: vendoredBinaryURL), as: UTF8.self)
        #expect(sanitized.contains("/Users/dho") == false)
        #expect(sanitized.contains(".build/xcode-cli-release") == false)
        #expect(sanitized.contains("/usr/local/Cellar") == false)
        #expect(sanitized.contains("/usr/local/etc/openssl@3") == false)
        #expect(sanitized.contains("/opt/homebrew") == false)
    }

    @Test("Release tools sanitizer scans registered worktrees only when requested")
    func releaseToolsSanitizerScansRegisteredWorktreesOnlyWhenRequested() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/sanitize-bundled-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains("LUNGFISH_SANITIZE_INCLUDE_WORKTREES"))
        #expect(script.contains("return"))
        #expect(script.contains("worktree list --porcelain"))
    }

    @Test("Release tools sanitizer scrubs builder paths from standalone executables")
    func releaseToolsSanitizerScrubsBuilderPathsFromStandaloneExecutables() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sanitizerURL = repositoryRoot.appendingPathComponent("scripts/sanitize-bundled-tools.sh")
        #expect(FileManager.default.fileExists(atPath: sanitizerURL.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cliBinaryURL = tempRoot.appendingPathComponent("lungfish-cli")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: cliBinaryURL)
        let embeddedPaths = [
            "prefix\0\(repositoryRoot.path)/.build/xcode-cli-release/arm64-apple-macosx/release/LungfishCLI.build/Main.swift.o\0",
            "prefix\0/workspace/.build/xcode-cli-release/checkouts/swift-nio/Sources/CNIOAtomics/src\0",
        ].joined()
        let handle = try FileHandle(forWritingTo: cliBinaryURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(embeddedPaths.utf8))
        try handle.close()
        try Self.makeExecutable(cliBinaryURL)

        try Self.runScript(sanitizerURL, arguments: [cliBinaryURL.path])

        let sanitized = String(decoding: try Data(contentsOf: cliBinaryURL), as: UTF8.self)
        #expect(sanitized.contains(repositoryRoot.path) == false)
        #expect(sanitized.contains("/Users/dho") == false)
        #expect(sanitized.contains(".build/xcode-cli-release") == false)
    }

    private static func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let package = candidate.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: package.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        fatalError("Cannot locate repository root from \(#filePath)")
    }

    private struct CommandResult {
        let stdout: String
        let stderr: String
    }

    private static func runCommand(
        _ executableURL: URL,
        arguments: [String],
        currentDirectory: URL
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let result = CommandResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ReleaseBuildConfigurationTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: """
                    Command failed: \(executableURL.path) \(arguments.joined(separator: " "))
                    \(result.stderr)
                    """
                ]
            )
        }

        return result
    }

    private static func releaseAgentCanonicalContents() throws -> String {
        try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("agents/definitions/codex/release-agent.md"),
            encoding: .utf8
        )
    }

    private static func buildConfigurationBlock(named marker: String, in project: String) throws -> String {
        guard let markerRange = project.range(of: marker),
              let blockEnd = project[markerRange.lowerBound...].range(of: "\n\t\t};")
        else {
            throw NSError(domain: "ReleaseBuildConfigurationTests", code: 1)
        }

        return String(project[markerRange.lowerBound..<blockEnd.upperBound])
    }

    private static func buildPhaseBlock(named marker: String, in project: String) throws -> String {
        let phaseMarker = "\t\t\(marker) = {"
        guard let markerRange = project.range(of: phaseMarker),
              let blockEnd = project[markerRange.lowerBound...].range(of: "\n\t\t};")
        else {
            throw NSError(domain: "ReleaseBuildConfigurationTests", code: 2)
        }

        return String(project[markerRange.lowerBound..<blockEnd.upperBound])
    }

    private static func swiftFiles(in directory: URL, relativeTo repositoryRoot: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let repositoryPath = repositoryRoot.standardizedFileURL.path + "/"
        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(repositoryPath) else { continue }
            files.append(String(path.dropFirst(repositoryPath.count)))
        }
        return files.sorted()
    }

    private static func commandBlock(containing marker: String, in script: String) -> String? {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            guard line.contains("/usr/bin/codesign ") else {
                index = lines.index(after: index)
                continue
            }

            var block = [line]
            var cursor = index
            while lines[cursor].trimmingCharacters(in: .whitespaces).hasSuffix("\\") {
                cursor = lines.index(after: cursor)
                guard cursor < lines.endIndex else { break }
                block.append(lines[cursor])
            }

            let joined = block.joined(separator: "\n")
            if joined.contains(marker) {
                return joined
            }
            index = lines.index(after: cursor)
        }
        return nil
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func runScript(_ scriptURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "script failed: \(stderrString)")
    }
}
