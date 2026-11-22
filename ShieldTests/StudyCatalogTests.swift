import Foundation
import Testing
@testable import Shield

struct StudyCatalogTests {
    /// No course is built into Shield.
    @Test func shieldShipsNoCourse() {
        #expect(Bundle(for: ShieldViewModel.self).url(forResource: "bundled-course.manifest", withExtension: "json") == nil)
        #expect(Bundle(for: ShieldViewModel.self).urls(forResourcesWithExtension: "json", subdirectory: nil)?
            .filter { $0.lastPathComponent.contains("manifest") }.isEmpty ?? true)
    }

    @Test func aChosenCollectionFileLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("catalog.json")
        let short = StudyManifest(schemaVersion: 1, courseTitle: "Incomplete",
                                  videos: [StudyVideo(id: "abcdefghijk", title: "Lesson #1 Test",
                                                      expectedDuration: 60, transcriptRequested: false)])
        try JSONEncoder().encode(short).write(to: url)
        #expect(try StudyCatalog().loadCourse(at: url).videos.count == 1)
    }
}
