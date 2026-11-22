import Foundation
import Darwin

// Launchd owns the named Mach service. This executable is limited to an
// existing temporary fixture and an explicitly pinned development client.
guard (5...7).contains(CommandLine.arguments.count),
      CommandLine.arguments[1] == "serve" else {
    fputs("Usage: fixture-service serve <mach-service> <existing-temp-root> <client-signing-requirement> [allowed-client-identifier] [allowed-client-uid]\n", stderr)
    exit(64)
}

do {
    let name = CommandLine.arguments[2]
    guard name == "com.kairos.ShieldDevelopment.backend" ||
          name.hasPrefix("com.kairos.ShieldDevelopment.backend.ci.") else {
        throw FixtureBackendError.invalidRequest("Only the isolated development namespace is permitted.")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let clientRequirement = CommandLine.arguments[4]
    try validateXPCSigningRequirement(clientRequirement)
    let clientIdentifier = CommandLine.arguments.count >= 6
        ? CommandLine.arguments[5] : "com.kairos.ShieldDevelopment.XPCClient"
    guard ["com.kairos.ShieldDevelopment", "com.kairos.ShieldDevelopment.XPCClient"]
        .contains(clientIdentifier) else {
        throw FixtureBackendError.invalidRequest("Unexpected development client identity.")
    }
    let prefix = "identifier \"\(clientIdentifier)\" and cdhash H\""
    guard clientRequirement.hasPrefix(prefix), clientRequirement.hasSuffix("\""),
          clientRequirement.dropFirst(prefix.count).dropLast().range(
            of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
        throw FixtureBackendError.invalidRequest("Development service requires an exact approved client code hash.")
    }
    let allowedUID: uid_t
    if CommandLine.arguments.count == 7 {
        guard geteuid() == 0, let value = uid_t(CommandLine.arguments[6]), value != 0 else {
            throw FixtureBackendError.invalidRequest("Only a root-owned CI service can authorize another UID.")
        }
        allowedUID = value
    } else {
        allowedUID = geteuid()
    }
    let fault: FixtureBackendFault? = ProcessInfo.processInfo.environment["SHIELD_CI_FAULT"] == "afterJournal"
        ? .afterJournal : nil
    let backend = try FixtureBackend(root: root, fault: fault)
    let useDisposableSystemHosts = geteuid() == 0 &&
        name.hasPrefix("com.kairos.ShieldDevelopment.backend.ci.root.") &&
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" &&
        ProcessInfo.processInfo.environment["SHIELD_CI_SYSTEM_HOSTS"] == "1"
    let externalEnforcer: (any FixtureExternalEnforcer)? = useDisposableSystemHosts
        ? DisposableHostsReconciler() : nil
    let service = try FixtureBackendXPCService(
        backend: backend,
        peerPolicy: .signedCode(requirement: clientRequirement, allowedUID: allowedUID),
        machServiceName: name,
        externalEnforcer: externalEnforcer,
        backgroundTransitions: fault == nil &&
            ProcessInfo.processInfo.environment["SHIELD_CI_MANUAL_RECOVERY"] != "1")
    service.resume()
    RunLoop.current.run()
    withExtendedLifetime(service) {}
} catch {
    fputs("fixture-service: \(error.localizedDescription)\n", stderr)
    exit(1)
}
