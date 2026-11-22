import Foundation
import Darwin
import os

// Development-only embedded service. RC is rejected: App Sandbox grants broad
// outbound networking, not the still-required production destination authority.
final class WorkerDelegate: NSObject, NSXPCListenerDelegate {
    private let log = Logger(subsystem: StudyWorkerIdentity.identifier, category: "authentication")
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(),
              let requirement = try? StudyWorkerIdentity.clientRequirement(in: Bundle.main.bundleURL) else {
            log.error("Rejecting peer: UID or sealed client requirement is invalid")
            return false
        }
        // libxpc evaluates the peer's live signature. Reading the enclosing app
        // here is forbidden by App Sandbox and previously rejected every peer.
        // The pinned certificate survives resource sealing and relocation.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ShieldStudyWorkerWire.self)
        let session = StudyWorkerSession()
        connection.exportedObject = session
        connection.invalidationHandler = { session.disconnect() }
        connection.interruptionHandler = { session.disconnect() }
        connection.resume()
        return true
    }
}

let delegate = WorkerDelegate()
StudyWorkerSession.recoverAbandonedStaging()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
