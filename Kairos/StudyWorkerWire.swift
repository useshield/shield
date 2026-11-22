import Foundation

@objc protocol ShieldStudyWorkerWire {
    func begin(_ request: NSData, reply: @escaping (NSString?) -> Void)
    func status(_ job: NSString, reply: @escaping (NSData?, NSString?) -> Void)
    func read(_ job: NSString, kind: NSString, offset: Int64, reply: @escaping (NSData?, NSString?) -> Void)
    func cancel(_ job: NSString, reply: @escaping () -> Void)
}

struct StudyWorkerRequest: Codable, Sendable {
    let version: Int
    let jobID: UUID
    let video: StudyVideo
    let approvedIDs: [String]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "jobID", "video", "approvedIDs"],
              let video = object["video"] as? [String: Any],
              Set(video.keys).isSubset(of: ["id", "title", "expectedDuration", "transcriptRequested"]) else {
            throw StudyDownloadError.invalidManifest("Invalid worker envelope.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, !value.approvedIDs.isEmpty, value.approvedIDs.count <= 100,
              Set(value.approvedIDs).count == value.approvedIDs.count,
              value.approvedIDs.allSatisfy(StudyYouTubeLinks.isValidID),
              value.approvedIDs.contains(value.video.id) else {
            throw StudyDownloadError.invalidManifest("Video is outside the exact approved set.")
        }
        _ = try StudyManifest(schemaVersion: 1, courseTitle: "Approved worker job", videos: [value.video]).validated()
        return value
    }
}

struct StudyWorkerStatus: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case starting, downloading, preparingMedia, validating, ready, failed, cancelled }
    let version: Int
    let jobID: UUID
    var phase: Phase
    var progress: Double?
    var title: String?
    var toolVersions: [String: String]?
    var mediaBytes: Int64 = 0
    var transcriptBytes: Int64 = 0
    var problem: String?
}
