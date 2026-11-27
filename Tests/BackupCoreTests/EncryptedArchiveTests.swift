#if canImport(AppleArchive)
import XCTest
@testable import BackupCore

/// macOS uniquement (Apple Archive) : lancés par `swift test` via build.sh.
final class EncryptedArchiveTests: XCTestCase {
    var root: URL!
    var source: URL!
    var parts: URL!
    var restored: URL!
    let fm = FileManager.default
    let partSize: Int64 = 64 * 1024

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        parts = root.appendingPathComponent("morceaux")
        restored = root.appendingPathComponent("restauration")
        try fm.createDirectory(at: source.appendingPathComponent("sous"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("été"), withIntermediateDirectories: true)

        try Data("bonjour".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data().write(to: source.appendingPathComponent("vide.txt"))
        try Data("accents".utf8).write(to: source.appendingPathComponent("été/accentué.txt"))
        // Données aléatoires (incompressibles) : plusieurs morceaux garantis.
        var random = Data(count: 300 * 1024)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try random.write(to: source.appendingPathComponent("sous/b.bin"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("lien").path, withDestinationPath: "a.txt")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                             ofItemAtPath: source.appendingPathComponent("a.txt").path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func data(_ base: URL, _ rel: String) throws -> Data {
        try Data(contentsOf: base.appendingPathComponent(rel))
    }

    func testRoundTripAcrossSeveralParts() throws {
        var completed: [(URL, Int64)] = []
        let written = try EncryptedArchive.create(from: source, to: parts, password: "secret",
                                                  partSize: partSize,
                                                  onPartCompleted: { completed.append(($0, $1)) })
        XCTAssertGreaterThanOrEqual(written.count, 4)
        XCTAssertEqual(written, try EncryptedArchive.parts(in: parts))
        XCTAssertEqual(completed.map(\.0), written)
        XCTAssertTrue(completed.dropLast().allSatisfy { $0.1 == partSize })
        XCTAssertEqual(written.first?.lastPathComponent, "archive.aea.0001")

        // Le contenu n'apparaît pas en clair dans les morceaux.
        let firstPart = try Data(contentsOf: written[0])
        XCTAssertNil(firstPart.range(of: Data("bonjour".utf8)))

        try EncryptedArchive.extract(from: parts, to: restored, password: "secret")
        for rel in ["a.txt", "vide.txt", "été/accentué.txt", "sous/b.bin"] {
            XCTAssertEqual(try data(restored, rel), try data(source, rel), rel)
        }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: restored.appendingPathComponent("lien").path), "a.txt")
        let date = try fm.attributesOfItem(atPath: restored.appendingPathComponent("a.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_600_000_000, accuracy: 1)
    }

    func testWrongPasswordIsRejected() throws {
        try EncryptedArchive.create(from: source, to: parts, password: "bon", partSize: partSize)
        XCTAssertThrowsError(try EncryptedArchive.extract(from: parts, to: restored, password: "mauvais"))
        XCTAssertFalse(fm.fileExists(atPath: restored.appendingPathComponent("sous/b.bin").path))
    }

    func testMissingPartIsDetected() throws {
        let written = try EncryptedArchive.create(from: source, to: parts, password: "secret", partSize: partSize)
        try fm.removeItem(at: written[1])
        XCTAssertThrowsError(try EncryptedArchive.extract(from: parts, to: restored, password: "secret"))
    }

    func testBeforeNewPartIsCalledForEachPart() throws {
        var calls = 0
        let written = try EncryptedArchive.create(from: source, to: parts, password: "secret",
                                                  partSize: partSize, beforeNewPart: { calls += 1 })
        XCTAssertEqual(calls, written.count)
    }

    func testCancellationStopsAndLeavesOnlyCompleteParts() throws {
        var completedCount = 0
        XCTAssertThrowsError(try EncryptedArchive.create(
            from: source, to: parts, password: "secret", partSize: partSize,
            onPartCompleted: { _, _ in completedCount += 1 },
            isCancelled: { completedCount >= 1 }
        )) { error in
            XCTAssertEqual(error as? EncryptedArchive.Failure, .cancelled)
        }
        let remaining = (try? EncryptedArchive.parts(in: parts)) ?? []
        XCTAssertEqual(remaining.count, completedCount)
        for part in remaining {
            let size = try fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber
            XCTAssertEqual(size?.int64Value, partSize)
        }
    }

    func testErrorInBeforeNewPartIsPropagated() throws {
        struct Plein: Error {}
        var calls = 0
        XCTAssertThrowsError(try EncryptedArchive.create(
            from: source, to: parts, password: "secret", partSize: partSize,
            beforeNewPart: {
                calls += 1
                if calls == 3 { throw Plein() }
            }
        )) { error in
            XCTAssertTrue(error is Plein, "\(error)")
        }
    }
}
#endif
