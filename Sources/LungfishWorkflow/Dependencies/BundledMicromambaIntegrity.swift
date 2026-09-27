import Foundation
import LungfishIO
import Security

enum BundledMicromambaIntegrity {
    /// Accepts a transformed release binary only when it is an exact resource of the
    /// currently running, Apple-anchored Developer ID app and carries the same signer.
    static func validatesDeveloperIDPackage(
        executableURL: URL,
        runningExecutableURL: URL? = Bundle.main.executableURL
    ) -> Bool {
        let executable = executableURL.standardizedFileURL
        guard executable.resolvingSymlinksInPath() == executable,
              let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let app = enclosingApp(for: executable),
              let runningExecutableURL,
              enclosingApp(for: runningExecutableURL.standardizedFileURL) == app,
              isExpectedResource(executable, in: app),
              let appCode = staticCode(at: app),
              let toolCode = staticCode(at: executable),
              let developerIDRequirement = requirement(
                #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
              ),
              validates(
                appCode,
                flags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
                requirement: developerIDRequirement
              ),
              let teamID = signingTeamID(of: appCode),
              let sameTeamRequirement = requirement(
                #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\#(teamID)""#
              ),
              validates(
                toolCode,
                flags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                requirement: sameTeamRequirement
              ),
              signingTeamID(of: toolCode) == teamID else {
            return false
        }
        return true
    }

    private static func isExpectedResource(_ executable: URL, in app: URL) -> Bool {
        guard let relative = CanonicalFilePath.relativePath(of: executable, within: app) else { return false }
        return relative == "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools/micromamba"
            || relative == "Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Tools/micromamba"
    }

    private static func enclosingApp(for url: URL) -> URL? {
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                return resolved == candidate.standardizedFileURL ? resolved : nil
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func requirement(_ source: String) -> SecRequirement? {
        var result: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &result) == errSecSuccess else { return nil }
        return result
    }

    private static func validates(
        _ code: SecStaticCode,
        flags: SecCSFlags,
        requirement: SecRequirement
    ) -> Bool {
        SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func signingTeamID(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any],
              let teamID = dictionary[kSecCodeInfoTeamIdentifier] as? String,
              !teamID.isEmpty else {
            return nil
        }
        return teamID
    }
}
