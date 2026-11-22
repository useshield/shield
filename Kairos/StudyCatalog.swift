import Foundation

/// Reads a collection file the user chose (Library ▸ Import Collection File…).
/// Shield ships no course of its own.
struct StudyCatalog: Sendable {
    func loadCourse(at url: URL) throws -> StudyManifest {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw StudyDownloadError.invalidManifest("Course manifest is empty or oversized.")
        }
        return try JSONDecoder().decode(StudyManifest.self, from: data).validated()
    }
}
