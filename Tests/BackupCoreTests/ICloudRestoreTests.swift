#if canImport(AppleArchive) && os(macOS)
import XCTest
@testable import BackupCore

/// macOS uniquement : sauvegarde d'une chaîne dans un dossier local, puis restauration.
final class ICloudRestoreTests: XCTestCase {
    var root: URL!
    var source: URL!
    var backupFolder: URL!
    var cache: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("restauration-\(UUID().uuidString)")
        source = root.appendingPathComponent("Documents")
        backupFolder = root.appendingPathComponent("iCloud")
        cache = root.appendingPathComponent("cache/documents.json")
        try fm.createDirectory(at: source.appendingPathComponent("dossier/vide"), withIntermediateDirectories: true)
        try write("a.txt", "alpha")
        try write("dossier/b.txt", "bravo")
        try write("c.txt", "charlie")
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("lien").path, withDestinationPath: "a.txt")
        // Fichier assez gros pour former plusieurs morceaux.
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: source.appendingPathComponent("gros.bin"))
        try setOld("gros.bin")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func setOld(_ rel: String, ageSeconds: TimeInterval = 3600) throws {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)],
                             ofItemAtPath: source.appendingPathComponent(rel).path)
    }

    private func write(_ rel: String, _ text: String, ageSeconds: TimeInterval = 3600) throws {
        try Data(text.utf8).write(to: source.appendingPathComponent(rel))
        try setOld(rel, ageSeconds: ageSeconds)
    }

    private func runBackup() throws {
        var options = ICloudChainBackup.Options()
        options.iterations = 1_000
        options.partSize = 64 * 1024
        _ = try ICloudChainBackup(source: source, destination: backupFolder.appendingPathComponent("Documents"),
                                  cacheFile: cache, password: "secret", options: options, uploader: nil).run()
    }

    private func element() throws -> ICloudChainRestore.Element {
        try XCTUnwrap(ICloudChainRestore.elements(in: backupFolder).first)
    }

    private func read(_ dir: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(rel))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Deux étapes : complète, puis a.txt modifié, nouveau.txt ajouté, c.txt supprimé.
    private func twoSteps() throws {
        try runBackup()
        try write("a.txt", "alpha modifié", ageSeconds: 60)
        try write("nouveau.txt", "nouveau")
        try fm.removeItem(at: source.appendingPathComponent("c.txt"))
        try runBackup()
    }

    func testRestoreLatestAndEarlierStep() throws {
        try twoSteps()
        // Un fichier sans rapport avec les sauvegardes est ignoré.
        try Data("x".utf8).write(to: backupFolder.appendingPathComponent("applications.txt"))
        let elements = ICloudChainRestore.elements(in: backupFolder)
        XCTAssertEqual(elements.map(\.name), ["Documents"])
        XCTAssertEqual(elements[0].steps.count, 2)

        var fetched: [String] = []
        var released: [String] = []
        let restore = ICloudChainRestore(element: elements[0], password: "secret",
                                         fetch: { fetched.append($0.path) },
                                         release: { released.append($0.path) })
        let journals = try restore.journals()
        XCTAssertEqual(journals.map(\.step), [0, 1])

        // Dernier état.
        let latest = root.appendingPathComponent("restaure-1")
        var last = ICloudChainRestore.Progress()
        let outcome = try restore.restore(upTo: 1, journals: journals, to: latest, progress: { last = $0 })
        XCTAssertEqual(outcome.issues, [])
        XCTAssertEqual(read(latest, "a.txt"), "alpha modifié")
        XCTAssertEqual(read(latest, "dossier/b.txt"), "bravo")
        XCTAssertEqual(read(latest, "nouveau.txt"), "nouveau")
        XCTAssertNil(read(latest, "c.txt"), "supprimé à l'étape 1")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: latest.appendingPathComponent("lien").path), "a.txt")
        XCTAssertEqual(try Data(contentsOf: latest.appendingPathComponent("gros.bin")),
                       try Data(contentsOf: source.appendingPathComponent("gros.bin")))
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: latest.appendingPathComponent("dossier/vide").path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(outcome.restoredFiles, 5) // a.txt, dossier/b.txt, nouveau.txt, lien, gros.bin
        XCTAssertEqual(last.partsDone, last.partsTotal)
        XCTAssertGreaterThan(last.partsTotal, 2, "gros.bin occupe plusieurs morceaux")
        // Aucun dossier provisoire laissé.
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: latest.path).contains { $0.hasPrefix(".msb-") })
        // Chaque morceau de données lu a été libéré.
        let parts = fetched.filter { $0.hasSuffix(".aea") && $0.contains("/\(ChainLayout.dataFolder)/") }
        XCTAssertEqual(parts.count, last.partsTotal)
        XCTAssertEqual(Set(released), Set(parts))

        // État de l'archive complète.
        let first = root.appendingPathComponent("restaure-0")
        let initial = try restore.restore(upTo: 0, journals: journals, to: first)
        XCTAssertEqual(initial.issues, [])
        XCTAssertEqual(read(first, "a.txt"), "alpha")
        XCTAssertEqual(read(first, "c.txt"), "charlie")
        XCTAssertNil(read(first, "nouveau.txt"))
    }

    func testWrongPasswordIsDetectedOnJournals() throws {
        try runBackup()
        let restore = ICloudChainRestore(element: try element(), password: "mauvais")
        XCTAssertThrowsError(try restore.journals()) { error in
            guard case ICloudChainRestore.Failure.unreadableJournals = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
    }

    func testNonEmptyDestinationIsRefused() throws {
        try runBackup()
        let restore = ICloudChainRestore(element: try element(), password: "secret")
        let journals = try restore.journals()
        let target = root.appendingPathComponent("occupe")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("à garder".utf8).write(to: target.appendingPathComponent("perso.txt"))
        XCTAssertThrowsError(try restore.restore(upTo: 0, journals: journals, to: target)) { error in
            XCTAssertEqual(error as? ICloudChainRestore.Failure, .destinationNotEmpty(target.path))
        }
        XCTAssertEqual(read(target, "perso.txt"), "à garder")
    }

    func testDamagedPartIsReportedWithoutStopping() throws {
        try runBackup()
        let element = try element()
        let data = element.steps[0].url.appendingPathComponent(ChainLayout.dataFolder)
        let parts = try EncryptedArchive.parts(in: data)
        XCTAssertGreaterThan(parts.count, 1)
        // On abîme le dernier morceau (milieu du fichier).
        let damaged = try XCTUnwrap(parts.last)
        var bytes = try Data(contentsOf: damaged)
        for i in stride(from: bytes.count / 2, to: min(bytes.count, bytes.count / 2 + 64), by: 1) { bytes[i] ^= 0xFF }
        try bytes.write(to: damaged)

        let restore = ICloudChainRestore(element: element, password: "secret")
        let target = root.appendingPathComponent("restaure")
        let outcome = try restore.restore(upTo: 0, journals: try restore.journals(), to: target)
        XCTAssertTrue(outcome.issues.contains { $0.path == damaged.lastPathComponent })
        XCTAssertGreaterThan(outcome.restoredFiles, 0, "les autres morceaux sont restaurés")
    }

    func testCancellation() throws {
        try runBackup()
        let restore = ICloudChainRestore(element: try element(), password: "secret")
        let journals = try restore.journals()
        XCTAssertThrowsError(try restore.restore(upTo: 0, journals: journals, to: root.appendingPathComponent("annule"),
                                                 isCancelled: { true })) { error in
            XCTAssertEqual(error as? SyncError, .cancelled)
        }
    }
}
#endif
