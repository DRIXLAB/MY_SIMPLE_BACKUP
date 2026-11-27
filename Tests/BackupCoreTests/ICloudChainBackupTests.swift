#if canImport(AppleArchive) && os(macOS)
import XCTest
@testable import BackupCore

/// macOS uniquement : chaîne de sauvegarde dans un dossier local (sans iCloud, `uploader` nil).
final class ICloudChainBackupTests: XCTestCase {
    var root: URL!
    var source: URL!
    var destination: URL!
    var cache: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("chaine-\(UUID().uuidString)")
        source = root.appendingPathComponent("Documents")
        destination = root.appendingPathComponent("iCloud/Documents")
        cache = root.appendingPathComponent("cache/documents.json")
        try fm.createDirectory(at: source.appendingPathComponent("dossier"), withIntermediateDirectories: true)
        try write("a.txt", "alpha")
        try write("dossier/b.txt", "bravo")
        try write("c.txt", "charlie")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ rel: String, _ text: String, ageSeconds: TimeInterval = 3600) throws {
        let url = source.appendingPathComponent(rel)
        try Data(text.utf8).write(to: url)
        // Date fixe dans le passé : une modification ultérieure est toujours détectée.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
    }

    private func backup() -> ICloudChainBackup {
        var options = ICloudChainBackup.Options()
        options.iterations = 1_000
        options.partSize = 64 * 1024
        return ICloudChainBackup(source: source, destination: destination, cacheFile: cache,
                                 password: "secret", options: options, uploader: nil)
    }

    func testFullThenIncrementThenNothing() throws {
        let first = try backup().run()
        XCTAssertEqual(first.step, 0)
        XCTAssertEqual(first.kind, .complete)
        XCTAssertEqual(first.changedFiles, 3)

        try write("a.txt", "alpha modifié", ageSeconds: 60)
        try write("nouveau.txt", "nouveau")
        try fm.removeItem(at: source.appendingPathComponent("c.txt"))
        let second = try backup().run()
        XCTAssertEqual(second.step, 1)
        XCTAssertEqual(second.kind, .increment)
        XCTAssertEqual(second.changedFiles, 2)
        XCTAssertEqual(second.deletedItems, 1)
        XCTAssertEqual(second.chainName, first.chainName)

        let third = try backup().run()
        XCTAssertNil(third.step, "aucun changement : aucune étape créée")

        let journals = try backup().journals()
        XCTAssertEqual(journals.map(\.step), [0, 1])
        XCTAssertEqual(journals[1].deleted, ["c.txt"])
        let plan = RestorePlan(deltas: journals)
        XCTAssertEqual(plan.items.keys.sorted(), ["a.txt", "dossier", "dossier/b.txt", "nouveau.txt"])
        XCTAssertEqual(plan.stepOf["a.txt"], 1)
        XCTAssertEqual(plan.stepOf["dossier/b.txt"], 0)

        // Aucun nom de fichier en clair dans la destination.
        let everything = (fm.enumerator(atPath: destination.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(everything.contains { $0.contains("bravo") || $0.contains("b.txt") || $0.contains("nouveau") })
    }

    func testStepDataContainsOnlyChangedFiles() throws {
        _ = try backup().run()
        try write("dossier/b.txt", "bravo bis", ageSeconds: 60)
        let outcome = try backup().run()
        let step = try XCTUnwrap(ChainLayout.currentChain(in: destination)?.steps.last)
        XCTAssertEqual(step.number, outcome.step)
        let restored = root.appendingPathComponent("restauration")
        try EncryptedArchive.extract(from: step.url.appendingPathComponent(ChainLayout.dataFolder),
                                     to: restored, password: "secret")
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("dossier/b.txt"), encoding: .utf8), "bravo bis")
        XCTAssertFalse(fm.fileExists(atPath: restored.appendingPathComponent("a.txt").path))
    }

    func testStateIsRebuiltFromJournalsWhenCacheIsMissing() throws {
        _ = try backup().run()
        try fm.removeItem(at: cache)
        XCTAssertNil(try backup().run().step, "état relu depuis les journaux : rien n'a changé")
        try write("c.txt", "charlie modifié", ageSeconds: 60)
        try fm.removeItem(at: cache)
        let outcome = try backup().run()
        XCTAssertEqual(outcome.step, 1)
        XCTAssertEqual(outcome.changedFiles, 1)
    }

    func testIncompleteStepIsRemovedAndNumberReused() throws {
        let first = try backup().run()
        let chain = destination.appendingPathComponent(first.chainName)
        // Daté d'une heure plus tôt : un nom différent de la vraie étape 1, créée à la seconde près.
        let orphan = chain.appendingPathComponent(ChainLayout.stepFolderName(step: 1, kind: .increment,
                                                                             date: Date().addingTimeInterval(-3600)))
        try fm.createDirectory(at: orphan.appendingPathComponent(ChainLayout.dataFolder), withIntermediateDirectories: true)

        try write("a.txt", "alpha modifié", ageSeconds: 60)
        let outcome = try backup().run()
        XCTAssertEqual(outcome.step, 1)
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertEqual(ChainLayout.committedSteps(in: chain).map(\.number), [0, 1])
    }

    func testStartNewChainReplacesOldChainOnlyAfterSuccess() throws {
        let first = try backup().run()
        try write("a.txt", "alpha modifié", ageSeconds: 60)
        _ = try backup().run()
        Thread.sleep(forTimeInterval: 1.1) // nom de chaîne horodaté à la seconde
        let fresh = try backup().run(startNewChain: true)
        XCTAssertEqual(fresh.step, 0)
        XCTAssertEqual(fresh.kind, .complete)
        XCTAssertEqual(fresh.changedFiles, 3)
        XCTAssertNotEqual(fresh.chainName, first.chainName)
        XCTAssertEqual(ChainLayout.chains(in: destination).map(\.lastPathComponent), [fresh.chainName])
    }

    func testCancellationLeavesNoStepAndKeepsChain() throws {
        let first = try backup().run()
        try write("a.txt", "alpha modifié", ageSeconds: 60)
        XCTAssertThrowsError(try backup().run(isCancelled: { true }))
        let chain = destination.appendingPathComponent(first.chainName)
        XCTAssertEqual(ChainLayout.steps(in: chain).map(\.number), [0])
        // La sauvegarde suivante reprend normalement.
        XCTAssertEqual(try backup().run().step, 1)
    }

    func testCancelledFirstBackupLeavesNothing() throws {
        XCTAssertThrowsError(try backup().run(isCancelled: { true }))
        XCTAssertEqual(ChainLayout.chains(in: destination), [])
    }
}
#endif
