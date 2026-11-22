import Foundation

/// One caption line and when it's said, saved next to a video's transcript
/// (`<id>.cues.json`) so the transcript can follow the video and captions
/// can show on it. Videos saved before this have the plain transcript only.
struct TranscriptCue: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String

    static let fileLimit = 4_000_000
    static let maximumCount = 50_000
    static let maximumText = 500

    private struct File: Codable { let version: Int; let cues: [TranscriptCue] }

    static func encode(_ cues: [TranscriptCue]) -> Data? {
        guard !cues.isEmpty, cues.count <= maximumCount,
              let data = try? JSONEncoder().encode(File(version: 1, cues: cues)),
              data.count <= fileLimit else { return nil }
        return data
    }

    /// Only well-formed timing is accepted: finite, in order, short lines.
    static func decode(_ data: Data) throws -> [TranscriptCue] {
        guard data.count <= fileLimit, let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1, file.cues.count <= maximumCount else {
            throw StudyDownloadError.invalidMedia("The saved transcript timing can't be read.")
        }
        var previous = -Double.infinity
        for cue in file.cues {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start,
                  cue.start >= previous, cue.text.count <= maximumText else {
                throw StudyDownloadError.invalidMedia("The saved transcript timing can't be read.")
            }
            previous = cue.start
        }
        return file.cues
    }

    /// The line being said at `time`: the last one started by then, while it
    /// lasts. Nil before the first line and in gaps between lines.
    static func index(at time: Double, in cues: [TranscriptCue]) -> Int? {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard index >= 0, time < cues[index].end else { return nil }
        return index
    }

    /// The last line started by `time`, even in a gap (keeps the transcript's
    /// place while nothing is being said).
    static func lastStarted(at time: Double, in cues: [TranscriptCue]) -> Int? {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}
