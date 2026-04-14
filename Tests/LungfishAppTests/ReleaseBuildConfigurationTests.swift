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

    @Test("Release tools sanitizer preserves wrappers and strips resource executables")
    func releaseToolsSanitizerPreservesWrappersAndStripsResourceExecutables() throws {
        let repositoryRoot = Self.repositoryRoot()
        let sanitizerURL = repositoryRoot.appendingPathComponent("scripts/sanitize-bundled-tools.sh")
        #expect(FileManager.default.fileExists(atPath: sanitizerURL.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolsRoot = tempRoot.appendingPathComponent("Tools", isDirectory: true)
        let bbtoolsDir = toolsRoot.appendingPathComponent("bbtools", isDirectory: true)
        let scrubberScriptsDir = toolsRoot
            .appendingPathComponent("scrubber/scripts", isDirectory: true)
        let configDir = bbtoolsDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scrubberScriptsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bbdukURL = bbtoolsDir.appendingPathComponent("bbduk.sh")
        try "#!/bin/bash\nexit 0\n".write(to: bbdukURL, atomically: true, encoding: .utf8)
        try Self.makeExecutable(bbdukURL)

        let scrubberHelperURL = scrubberScriptsDir.appendingPathComponent("cut_spots_fastq.py")
        try "#!/usr/bin/env python3\nprint('ok')\n".write(to: scrubberHelperURL, atomically: true, encoding: .utf8)
        try Self.makeExecutable(scrubberHelperURL)

        let configURL = configDir.appendingPathComponent("histograms.txt")
        try "histogram=true\n".write(to: configURL, atomically: true, encoding: .utf8)
        try Self.makeExecutable(configURL)

        let machOURL = toolsRoot.appendingPathComponent("samtools")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: machOURL)
        try Self.makeExecutable(machOURL)

        try Self.runScript(sanitizerURL, arguments: [toolsRoot.path])

        #expect(FileManager.default.isExecutableFile(atPath: bbdukURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: scrubberHelperURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: machOURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: configURL.path) == false)
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

    @Test("Release smoke test script exercises bundled tools")
    func releaseSmokeTestScriptExercisesBundledTools() throws {
        let script = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("scripts/smoke-test-release-tools.sh"),
            encoding: .utf8
        )

        #expect(script.contains("bbduk.sh"))
        #expect(script.contains("reformat.sh"))
        #expect(script.contains("clumpify.sh"))
        #expect(script.contains("bbmerge.sh"))
        #expect(script.contains("repair.sh"))
        #expect(script.contains("tadpole.sh"))
        #expect(script.contains("scrub.sh"))
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
        #expect(script.contains("notarytool submit"))
        #expect(script.contains("stapler staple"))
        #expect(script.contains("hdiutil create"))
        #expect(script.contains("DMG_PATH"))
        #expect(script.contains("release-metadata.txt"))
    }

    @Test("Release agent is tracked in repo")
    func releaseAgentIsTrackedInRepo() throws {
        let agent = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent(".codex/agents/release-agent.md"),
            encoding: .utf8
        )

        #expect(agent.contains("name: release-agent"))
        #expect(agent.contains("scripts/release/build-notarized-dmg.sh"))
        #expect(agent.contains("scripts/smoke-test-release-tools.sh"))
        #expect(agent.contains("notarytool"))
        #expect(agent.contains(".dmg"))
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

    private static func buildConfigurationBlock(named marker: String, in project: String) throws -> String {
        guard let markerRange = project.range(of: marker),
              let blockEnd = project[markerRange.lowerBound...].range(of: "\n\t\t};")
        else {
            throw NSError(domain: "ReleaseBuildConfigurationTests", code: 1)
        }

        return String(project[markerRange.lowerBound..<blockEnd.upperBound])
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
