import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3,
      ["apply", "tick", "recover", "verify", "inspect-legacy"].contains(arguments[1]) else {
    fputs("Usage: fixture-backend apply|tick|recover|verify|inspect-legacy <existing-temp-fixture-root> [request-or-legacy-file]\n", stderr)
    exit(64)
}

do {
    let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let backend = try FixtureBackend(root: root)
    if arguments[1] == "inspect-legacy" {
        guard arguments.count == 4 else { throw FixtureBackendError.invalidRequest("Legacy file path is required.") }
        let file = URL(fileURLWithPath: arguments[3])
        guard file.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw FixtureBackendError.invalidRequest("Legacy inspection is limited to the fixture root.")
        }
        let report = LegacyAuthorityInspector().inspect(file)
        let data = try JSONEncoder().encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }
    let calendar = Calendar.autoupdatingCurrent
    let result: BackendAcknowledgment
    switch arguments[1] {
    case "apply":
        guard arguments.count == 4 else { throw FixtureBackendError.invalidRequest("Request path is required.") }
        let requestURL = URL(fileURLWithPath: arguments[3])
        guard requestURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw FixtureBackendError.invalidRequest("The request must be inside the fixture root.")
        }
        let data = try AtomicFixtureStore(allowedRoot: root).read(requestURL)
        guard data.count <= 1_048_576 else { throw FixtureBackendError.invalidRequest("Request is oversized.") }
        let request = try JSONDecoder().decode(BackendRequest.self, from: data)
        result = try backend.apply(request, now: .now, calendar: calendar)
    case "tick":
        result = try backend.tick(now: .now, calendar: calendar)
    case "recover":
        result = try backend.recover(now: .now, calendar: calendar)
    default:
        let receipt = try backend.verifiedReceipt()
        result = BackendAcknowledgment(version: 1, status: .unchanged,
                                       receipt: receipt, nextTransition: nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fputs("fixture-backend: \(error.localizedDescription)\n", stderr)
    exit(1)
}
