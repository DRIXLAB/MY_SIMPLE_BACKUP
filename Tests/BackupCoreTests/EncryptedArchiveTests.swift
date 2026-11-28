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
    /// Morceaux de 100 Ko : les 3 fichiers de 120 Ko donnent 3 morceaux au moins.
    let partSize: Int64 = 100 * 1024
    /// Peu d'itérations : la dérivation de clé reste rapide dans les tests.
    let iterations = 1_000

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        parts = root.appendingPathComponent("morceaux")
        restored = root.appendingPathComponent("restauration")
        try fm.createDirectory(at: source.appendingPathComponent("sous"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("été"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("vide"), withIntermediateDirectories: true)

        try Data("bonjour".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data().write(to: source.appendingPathComponent("rien.txt"))
        try Data("accents".utf8).write(to: source.appendingPathComponent("été/accentué.txt"))
        // Données aléatoires (incompressibles) : plusieurs morceaux garantis.
        for name in ["sous/b1.bin", "sous/b2.bin", "sous/b3.bin"] {
            var random = Data(count: 120 * 1024)
            random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            try random.write(to: source.appendingPathComponent(name))
        }
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

    private func create(password: String = "secret", to directory: URL? = nil) throws -> EncryptedArchive.Result {
        try EncryptedArchive.create(from: source, to: directory ?? parts, password: password,
                                    partSize: partSize, iterations: iterations)
    }

    func testRoundTripAcrossSeveralParts() throws {
        var completed: [URL] = []
        let result = try EncryptedArchive.create(from: source, to: parts, password: "secret",
                                                 partSize: partSize, iterations: iterations,
                                                 onPartCompleted: { url, _ in completed.append(url) })
        XCTAssertGreaterThanOrEqual(result.parts.count, 3)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.parts, try EncryptedArchive.parts(in: parts))
        XCTAssertEqual(completed, result.parts)
        XCTAssertEqual(result.parts.first?.lastPathComponent, "archive-0001.aea")

        // Le contenu n'apparaît pas en clair dans les morceaux.
        for part in result.parts {
            XCTAssertNil(try Data(contentsOf: part).range(of: Data("bonjour".utf8)), part.lastPathComponent)
        }

        try EncryptedArchive.extract(from: parts, to: restored, password: "secret")
        for rel in ["a.txt", "rien.txt", "été/accentué.txt", "sous/b1.bin", "sous/b2.bin", "sous/b3.bin"] {
            XCTAssertEqual(try data(restored, rel), try data(source, rel), rel)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: restored.appendingPathComponent("vide").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: restored.appendingPathComponent("lien").path), "a.txt")
        let date = try fm.attributesOfItem(atPath: restored.appendingPathComponent("a.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_600_000_000, accuracy: 1)
    }

    func testSourceFilesAreNeverModified() throws {
        let before = try data(source, "sous/b1.bin")
        let attributes = try fm.attributesOfItem(atPath: source.appendingPathComponent("sous/b1.bin").path)
        _ = try create()
        XCTAssertEqual(try data(source, "sous/b1.bin"), before)
        let after = try fm.attributesOfItem(atPath: source.appendingPathComponent("sous/b1.bin").path)
        XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
        // Aucun lien physique vers l'original (copies de travail clonées).
        XCTAssertEqual((after[.referenceCount] as? NSNumber)?.intValue, 1)
    }

    func testOnlyGivenItemsAreArchived() throws {
        let items = try ArchivePlan.scan(source).items.filter { $0.path == "a.txt" || $0.path == "sous" || $0.path == "sous/b2.bin" }
        _ = try EncryptedArchive.create(from: source, items: items, to: parts, password: "secret",
                                        partSize: partSize, iterations: iterations)
        try EncryptedArchive.extract(from: parts, to: restored, password: "secret")
        XCTAssertEqual(try data(restored, "sous/b2.bin"), try data(source, "sous/b2.bin"))
        XCTAssertTrue(fm.fileExists(atPath: restored.appendingPathComponent("a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: restored.appendingPathComponent("sous/b1.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: restored.appendingPathComponent("été").path))
    }

    func testWrongPasswordIsRejected() throws {
        _ = try create(password: "bon")
        XCTAssertThrowsError(try EncryptedArchive.extract(from: parts, to: restored, password: "mauvais"))
        XCTAssertFalse(fm.fileExists(atPath: restored.appendingPathComponent("sous/b1.bin").path))
    }

    func testDamagedPartIsDetected() throws {
        let result = try create()
        var damaged = try Data(contentsOf: result.parts[1])
        damaged[damaged.count / 2] ^= 0xFF
        try damaged.write(to: result.parts[1])
        XCTAssertThrowsError(try EncryptedArchive.extract(from: parts, to: restored, password: "secret"))
    }

    func testBeforeNewPartIsCalledForEachPart() throws {
        var calls = 0
        let result = try EncryptedArchive.create(from: source, to: parts, password: "secret",
                                                 partSize: partSize, iterations: iterations,
                                                 beforeNewPart: { calls += 1 })
        XCTAssertEqual(calls, result.parts.count)
    }

    func testCancellationStopsAndRemovesAllParts() throws {
        var completedCount = 0
        XCTAssertThrowsError(try EncryptedArchive.create(
            from: source, to: parts, password: "secret", partSize: partSize, iterations: iterations,
            onPartCompleted: { _, _ in completedCount += 1 },
            isCancelled: { completedCount >= 1 }
        )) { error in
            XCTAssertEqual(error as? EncryptedArchive.Failure, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(completedCount, 1)
        XCTAssertEqual((try? EncryptedArchive.parts(in: parts)) ?? [], [])
        XCTAssertFalse(fm.fileExists(atPath: parts.appendingPathComponent(EncryptedArchive.keyFileName).path))
    }

    func testErrorInBeforeNewPartIsPropagated() throws {
        struct Plein: Error {}
        var calls = 0
        XCTAssertThrowsError(try EncryptedArchive.create(
            from: source, to: parts, password: "secret", partSize: partSize, iterations: iterations,
            beforeNewPart: {
                calls += 1
                if calls == 2 { throw Plein() }
            }
        )) { error in
            XCTAssertTrue(error is Plein, "\(error)")
        }
        XCTAssertEqual((try? EncryptedArchive.parts(in: parts)) ?? [], [])
    }

    func testKeyParametersAreWrittenAndSaltIsRandom() throws {
        _ = try create()
        _ = try create(to: root.appendingPathComponent("autres-morceaux"))
        let first = try EncryptedArchive.readKeyParameters(in: parts)
        let second = try EncryptedArchive.readKeyParameters(in: root.appendingPathComponent("autres-morceaux"))
        XCTAssertEqual(first.iterations, iterations)
        XCTAssertEqual(first.salt.count, 16)
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertEqual(EncryptedArchive.defaultIterations, 600_000)
    }

    func testKeyDerivationIsDeterministic() throws {
        let parameters = EncryptedArchive.KeyParameters(iterations: 1000, salt: Data(repeating: 7, count: 16))
        func bytes(_ password: String) throws -> Data {
            try EncryptedArchive.deriveKey(password: password, parameters: parameters).withUnsafeBytes { Data($0) }
        }
        XCTAssertEqual(try bytes("secret").count, 32)
        XCTAssertEqual(try bytes("secret"), try bytes("secret"))
        XCTAssertNotEqual(try bytes("secret"), try bytes("autre"))
    }

    func testPartsListsICloudPlaceholdersUnderTheirRealName() throws {
        try fm.createDirectory(at: parts, withIntermediateDirectories: true)
        try Data().write(to: parts.appendingPathComponent("archive-0001.aea"))
        try Data().write(to: parts.appendingPathComponent(".archive-0002.aea.icloud"))
        try Data().write(to: parts.appendingPathComponent(".autre.icloud"))
        XCTAssertEqual(try EncryptedArchive.parts(in: parts).map(\.lastPathComponent),
                       ["archive-0001.aea", "archive-0002.aea"])
    }

    func testBeforeReadingIsCalledForKeyFileThenEachPart() throws {
        let result = try create()
        var seen: [String] = []
        try EncryptedArchive.extract(from: parts, to: restored, password: "secret",
                                     beforeReading: { seen.append($0.lastPathComponent) })
        XCTAssertEqual(seen, [EncryptedArchive.keyFileName] + result.parts.map(\.lastPathComponent))
    }

    func testMissingKeyFileIsDetected() throws {
        _ = try create()
        try fm.removeItem(at: parts.appendingPathComponent(EncryptedArchive.keyFileName))
        XCTAssertThrowsError(try EncryptedArchive.extract(from: parts, to: restored, password: "secret")) { error in
            XCTAssertEqual(error as? EncryptedArchive.Failure, .unreadableArchive)
        }
    }
}
#endif
