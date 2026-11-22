import Darwin
import Foundation
import Testing
@testable import Shield

struct WorkerTransferTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldWorkerTransfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func chunkTransferWritesExactBytesAndNeverOverwritesAnExistingOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("media.mp4")
        let bytes = Data((0..<150_000).map { UInt8($0 % 251) })
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        try await StudyWorkerOutputTransfer.copy(count: Int64(bytes.count), to: file, deadline: deadline,
                                                 policyAllows: { true }) { offset in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + 65_536))
        }
        #expect(try Data(contentsOf: file) == bytes)
        await #expect(throws: StudyDownloadError.self) {
            try await StudyWorkerOutputTransfer.copy(count: 1, to: file, deadline: deadline,
                policyAllows: { true }, read: { _ in Data([0]) })
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func policyRevocationDuringTransferRemovesPartialOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("partial.mp4")
        let permission = TransferPermission()
        await #expect(throws: StudyDownloadError.self) {
            try await StudyWorkerOutputTransfer.copy(count: 131_072, to: file,
                deadline: ProcessInfo.processInfo.systemUptime + 10,
                policyAllows: { await permission.allowed }) { offset in
                    if offset > 0 { await permission.revoke() }
                    return Data(repeating: 7, count: 65_536)
                }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func invalidChunkSizesAndInterruptedTransferCannotPublishOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, chunk) in [Data(), Data(repeating: 1, count: 65_537), Data(repeating: 2, count: 11)].enumerated() {
            let file = root.appendingPathComponent("invalid-\(index)")
            await #expect(throws: StudyDownloadError.self) {
                try await StudyWorkerOutputTransfer.copy(count: 10, to: file,
                    deadline: ProcessInfo.processInfo.systemUptime + 10, policyAllows: { true }, read: { _ in chunk })
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        let file = root.appendingPathComponent("interrupted")
        await #expect(throws: StudyWorkerChannelError.self) {
            try await StudyWorkerOutputTransfer.copy(count: 100_000, to: file,
                deadline: ProcessInfo.processInfo.systemUptime + 10, policyAllows: { true }) { offset in
                    if offset > 0 { throw StudyWorkerChannelError.transport("Controlled interruption") }
                    return Data(repeating: 1, count: 65_536)
                }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func expiredTransferCannotReadOrCreateOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("expired")
        await #expect(throws: StudyDownloadError.self) {
            try await StudyWorkerOutputTransfer.copy(count: 1, to: file,
                deadline: ProcessInfo.processInfo.systemUptime - 1, policyAllows: { true }) { _ in
                    Issue.record("Expired transfer called the worker.")
                    return Data([1])
                }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func outputSnapshotRejectsLinksSizeChangesAndInvalidOffsets() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("media")
        let bytes = Data(repeating: 9, count: 100_000)
        try bytes.write(to: file)
        let output = try StudyOutputSnapshot(file: file, expectedSize: 100_000, maximumSize: 100_000)
        #expect(try output.read(offset: 0) == bytes.prefix(65_536))
        #expect(try output.read(offset: 65_536) == bytes.suffix(34_464))
        #expect(try output.read(offset: 100_000).isEmpty)
        #expect(throws: StudyDownloadError.self) { try output.read(offset: -1) }
        #expect(throws: StudyDownloadError.self) { try output.read(offset: 100_001) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: StudyDownloadError.self) { try StudyOutputSnapshot(file: link, expectedSize: 100_000, maximumSize: 100_000) }
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: 1)
        try writer.close()
        #expect(throws: StudyDownloadError.self) { try output.read(offset: 0) }
    }

    @Test func outputReplacementAndFailedInstallPreserveGoodMedia() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("staged")
        try Data("original".utf8).write(to: file)
        let output = try StudyOutputSnapshot(file: file, expectedSize: 8, maximumSize: 100)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old"))
        try Data("tampered".utf8).write(to: file)
        // A rename changes ctime. It must never redirect the opened descriptor.
        do { #expect(try output.read(offset: 0) == Data("original".utf8)) }
        catch { #expect(error is StudyDownloadError) }
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let saved = library.appendingPathComponent("abcdefghijk.mp4")
        try Data("known good media".utf8).write(to: saved)
        let validation = MediaValidation(duration: 1, hasVideo: true, hasAudio: true, fileSize: 9, transcriptPresent: false)
        #expect(throws: StudyDownloadError.self) {
            try ValidatedMediaInstaller(libraryRoot: library).install(stagedMedia: file, validation: validation, videoID: "abcdefghijk")
        }
        let nonfinite = MediaValidation(duration: .infinity, hasVideo: true, hasAudio: true, fileSize: 8, transcriptPresent: false)
        #expect(throws: StudyDownloadError.self) {
            try ValidatedMediaInstaller(libraryRoot: library).install(stagedMedia: file, validation: nonfinite, videoID: "abcdefghijk")
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == "known good media")
    }

    @Test func inspectionOutputBeyondPipeCapacityIsDrainedWithoutDeadlock() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        process.arguments = ["-c", "60000", "/dev/zero"]
        process.standardError = FileHandle.nullDevice
        let bytes = try await StudyProcessRunner().captureOutput(process, timeout: 5)
        #expect(process.terminationStatus == 0)
        #expect(bytes == Data(repeating: 0, count: 60_000))
    }

    @Test func excessiveInspectionOutputTerminatesToolAndFails() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardError = FileHandle.nullDevice
        await #expect(throws: StudyDownloadError.self) {
            try await StudyProcessRunner().captureOutput(process, timeout: 5)
        }
        #expect(!process.isRunning)
    }
}

private actor TransferPermission {
    private(set) var allowed = true
    func revoke() { allowed = false }
}
