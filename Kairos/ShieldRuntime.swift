import Foundation

// Debug is a separately identifiable development product. Its simulated hosts
// and authority are never the machine's enforcement files.
enum ShieldRuntime {
    #if SHIELD_RC
    static let isDevelopment = false
    static let isUIReview = false
    static let serviceName = "com.kairos.ShieldAuthority"
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
        .appendingPathComponent("ShieldRC", isDirectory: true)
    static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldDevelopmentBackend", isDirectory: true)
    static let authorityURL = supportDirectory.appendingPathComponent("unused-authority.plist")
    static let hostsURL = URL(fileURLWithPath: "/etc/hosts")
    #elseif UI_REVIEW
    static let isDevelopment = true
    static let isUIReview = true
    static let serviceName = "com.kairos.ShieldUIReview.simulated"
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
        .appendingPathComponent("ShieldUIReview", isDirectory: true)
    // Preview-only: per-launch isolated authority files for deterministic
    // screenshots. This remains beneath the UI Review sandbox allowlist.
    static let fixtureDirectory = supportDirectory.appendingPathComponent(
        ProcessInfo.processInfo.environment["SHIELD_UI_POLISH_FIXTURE"] == "1"
            ? "SimulatedBackend-\(ProcessInfo.processInfo.processIdentifier)" : "SimulatedBackend",
        isDirectory: true)
    static let authorityURL = fixtureDirectory.appendingPathComponent("authority.plist")
    static let hostsURL = fixtureDirectory.appendingPathComponent("hosts")
    #elseif DEBUG
    static let isDevelopment = true
    static let isUIReview = false
    static let serviceName = "com.kairos.ShieldDevelopment.backend"
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
        .appendingPathComponent("ShieldDevelopment", isDirectory: true)
    static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldDevelopmentBackend", isDirectory: true)
    static let authorityURL = fixtureDirectory.appendingPathComponent("authority.plist")
    static let hostsURL = fixtureDirectory.appendingPathComponent("hosts")
    #else
    static let isDevelopment = false
    static let isUIReview = false
    static let serviceName = "com.kairos.backend"
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
        .appendingPathComponent("Kairos", isDirectory: true)
    static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldDevelopmentBackend", isDirectory: true)
    static let authorityURL = URL(fileURLWithPath: "/usr/local/etc/kairos-policy-state.plist")
    static let hostsURL = URL(fileURLWithPath: "/etc/hosts")
    #endif

    // An unsandboxed third-party downloader cannot be trusted with production
    // Shield files or unrelated user data. Only disposable Debug fixture tests
    // opt into the executable path until a sandboxed downloader helper exists.
    #if SHIELD_STUDY_WORKER
    static let allowsExternalTools = true // Only the App Sandbox worker executes tools.
    #elseif DEBUG
    static let allowsExternalTools = !isUIReview &&
        ProcessInfo.processInfo.environment["SHIELD_UNCONFINED_TOOL_FIXTURE"] == "1" &&
        FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/StudyToolLauncher").path)
    #else
    static let allowsExternalTools = false
    #endif
    // Explicitly selected local files can be inspected with AVFoundation
    // without starting an unsandboxed third-party downloader.
    #if SHIELD_RC
    static let allowsLocalMediaImport = true
    #elseif DEBUG
    static let allowsLocalMediaImport = !isUIReview
    #else
    static let allowsLocalMediaImport = false
    #endif
    #if DEBUG
    static let allowsSimulatedPolicyChanges = !isUIReview
    static var serviceSigningRequirement: String? {
        ProcessInfo.processInfo.environment["SHIELD_XPC_SERVICE_REQUIREMENT"]
    }
    #else
    #if SHIELD_RC
    static let allowsSimulatedPolicyChanges = true
    #else
    static let allowsSimulatedPolicyChanges = false
    #endif
    static var serviceSigningRequirement: String? {
        // Production trust is embedded in the signed app by the release build;
        // a user's launch environment cannot choose an authoritative service.
        Bundle.main.object(forInfoDictionaryKey: "ShieldServiceSigningRequirement") as? String
    }
    #endif

    static func permitsStateRead(from url: URL) -> Bool {
        if isUIReview { return permitsWrite(to: url) }
        return url.isFileURL
    }

    static func requireIsolatedStateRead(from url: URL) throws {
        guard permitsStateRead(from: url) else {
            throw DevelopmentWriteError.productionReadPath(url.path)
        }
    }

    static func permitsWrite(to url: URL) -> Bool {
        #if UI_REVIEW
        guard url.isFileURL else { return false }
        let allowed = supportDirectory.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(allowed + "/") &&
            url.standardizedFileURL.path.hasPrefix(allowed + "/")
        #elseif DEBUG
        guard url.isFileURL else { return false }
        let productionSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                          in: .userDomainMask)[0]
            .appendingPathComponent("Kairos", isDirectory: true).standardizedFileURL.path
        let productionPreferences = FileManager.default.urls(for: .libraryDirectory,
                                                              in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/com.kairos.Kairos.plist").standardizedFileURL.path
        let protectedFiles = [productionPreferences, "/etc/hosts",
            "/usr/local/etc/kairos-policy-state.plist",
            "/Library/LaunchDaemons/com.kairos.scheduler.plist",
            "/usr/local/libexec/kairos-reconcile"]
        let aliases = Set(protectedFiles.flatMap { path in
            let file = URL(fileURLWithPath: path)
            return [file.standardizedFileURL.path,
                    file.resolvingSymlinksInPath().standardizedFileURL.path]
        })
        let resolvedSupport = URL(fileURLWithPath: productionSupport)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let protectedTrees = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ShieldRC").path,
            "/Library/Application Support/ShieldAuthority", "/Applications/Shield RC.app"
        ].flatMap { path in [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] }
        let currentAuthorityFiles = Set([
            "/Library/PrivilegedHelperTools/com.kairos.ShieldAuthority",
            "/Library/LaunchDaemons/com.kairos.ShieldAuthority.plist"
        ])
        func blocked(_ path: String) -> Bool {
            path == productionSupport || path.hasPrefix(productionSupport + "/") ||
                path == resolvedSupport || path.hasPrefix(resolvedSupport + "/") ||
                protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) ||
                currentAuthorityFiles.contains(path) ||
                aliases.contains(path)
        }
        return !blocked(url.standardizedFileURL.path) &&
            !blocked(url.resolvingSymlinksInPath().standardizedFileURL.path)
        #else
        return true
        #endif
    }

    static func requireIsolatedWrite(to url: URL) throws {
        guard permitsWrite(to: url) else { throw DevelopmentWriteError.productionPath(url.path) }
    }
}

enum DevelopmentWriteError: Error, LocalizedError {
    case productionPath(String)
    case productionReadPath(String)

    var errorDescription: String? {
        switch self {
        case .productionPath: "A development build cannot write an installed Shield path."
        case .productionReadPath: "UI review cannot read policy state outside its sandboxed storage."
        }
    }
}
