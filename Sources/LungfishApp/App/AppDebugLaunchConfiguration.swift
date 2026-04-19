import Foundation

struct AppDebugLaunchConfiguration: Equatable, Sendable {
    let bypassRequiredSetup: Bool

    init(environment: [String: String]) {
        #if DEBUG
        bypassRequiredSetup = environment["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP"] == "1"
        #else
        bypassRequiredSetup = false
        #endif
    }

    static let current = AppDebugLaunchConfiguration(
        environment: ProcessInfo.processInfo.environment
    )
}
