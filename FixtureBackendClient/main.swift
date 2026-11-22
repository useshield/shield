import Foundation
import Darwin

guard CommandLine.arguments.count >= 3,
      ["submit", "snapshot", "tick", "recover"].contains(CommandLine.arguments[1]) else {
    fputs("Usage: fixture-client submit|snapshot|tick|recover <mach-service> [request-file]\n", stderr)
    exit(64)
}

do {
    let client = FixtureBackendXPCClient(serviceName: CommandLine.arguments[2],
        privileged: ProcessInfo.processInfo.environment["SHIELD_CI_PRIVILEGED_XPC"] == "1",
        serviceRequirement: ProcessInfo.processInfo.environment["SHIELD_XPC_SERVICE_REQUIREMENT"])
    let result: Data
    switch CommandLine.arguments[1] {
    case "submit":
        guard CommandLine.arguments.count == 4 else {
            throw FixtureBackendError.invalidRequest("Request path required.")
        }
        let request = try JSONDecoder().decode(BackendRequest.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        result = try JSONEncoder().encode(client.submit(request))
    case "snapshot":
        let snapshot = try client.snapshot()
        result = try JSONEncoder().encode(FixtureSnapshotEnvelope(
            generation: snapshot.generation,
            restrictions: snapshot.committedRestrictions,
            schedules: snapshot.committedSchedules,
            pendingReleases: snapshot.pendingReleases,
            authority: snapshot.authority,
            enforcement: snapshot.enforcement,
            enforcementSource: snapshot.enforcementSource,
            receipt: snapshot.receipt,
            nextTransition: snapshot.nextTransition))
    case "tick": result = try JSONEncoder().encode(client.tick())
    default: result = try JSONEncoder().encode(client.recover())
    }
    FileHandle.standardOutput.write(result)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fputs("fixture-client: \(error.localizedDescription)\n", stderr)
    exit(1)
}
