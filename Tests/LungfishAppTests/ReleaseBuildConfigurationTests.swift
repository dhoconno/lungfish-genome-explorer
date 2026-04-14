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

        #expect(project.contains("ARCHS = arm64;"))
        #expect(project.contains("EXCLUDED_ARCHS = x86_64;"))
        #expect(project.contains("ONLY_ACTIVE_ARCH = YES;"))
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
}
