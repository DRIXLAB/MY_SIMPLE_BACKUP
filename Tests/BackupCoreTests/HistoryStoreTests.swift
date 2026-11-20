import XCTest
@testable import BackupCore

final class HistoryStoreTests: XCTestCase {
    var dir: URL!
    var store: HistoryStore!

    override func setUpWithError() throws {
        L10n.language = .french
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        // Dossier parent absent : save doit le créer.
        store = HistoryStore(fileURL: dir.appendingPathComponent("sous/history.json"), maxRuns: 3, maxIssuesPerSource: 2)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Dates à la seconde : l'encodage ISO 8601 ne conserve pas les fractions.
    func makeRun(at seconds: TimeInterval, issues: [String] = []) -> RunReport {
        let start = Date(timeIntervalSince1970: seconds)
        var docs = SourceReport(id: "documents", label: "Documents", symbol: "doc.fill")
        docs.status = issues.isEmpty ? .success : .warning
        docs.summary = "10 fichiers"
        docs.issues = issues
        docs.issueCount = issues.count
        docs.copiedFiles = 4
        docs.copiedBytes = 1_000
        docs.startedAt = start
        docs.finishedAt = start.addingTimeInterval(5)
        var apps = SourceReport(id: "applist", label: "Liste des applications", symbol: "square.grid.2x2.fill")
        apps.status = .success
        apps.copiedFiles = 1
        var run = RunReport(startedAt: start, destination: URL(fileURLWithPath: "/Volumes/Disque/Sauvegarde"),
                            deleteMode: true, sources: [docs, apps])
        run.finishedAt = start.addingTimeInterval(10)
        return run
    }

    func testLoadReturnsEmptyWhenFileMissing() {
        XCTAssertEqual(store.load(), [])
        XCTAssertNil(store.loadReportingProblems().movedAside)
    }

    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pas du json".utf8).write(to: store.fileURL)

        let result = store.loadReportingProblems()
        XCTAssertEqual(result.runs, [])
        let aside = try XCTUnwrap(result.movedAside)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "pas du json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        // La sauvegarde suivante crée un nouveau fichier sans toucher à l'ancien.
        try store.append(makeRun(at: 1_700_000_000), to: [])
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
    }

    func testAppendingDoesNotWrite() {
        let updated = store.appending(makeRun(at: 1_700_000_000), to: [])
        XCTAssertEqual(updated.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testRoundTripPreservesEverything() throws {
        let run = makeRun(at: 1_700_000_000, issues: ["a.txt : accès refusé"])
        try store.save([run])
        XCTAssertEqual(store.load(), [run])
    }

    func testAppendPutsNewestFirstAndCapsCount() throws {
        var history: [RunReport] = []
        for i in 0..<5 {
            history = try store.append(makeRun(at: 1_700_000_000 + Double(i) * 3600), to: history)
        }
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded, history)
        XCTAssertEqual(loaded.map(\.startedAt.timeIntervalSince1970),
                       [1_700_014_400, 1_700_010_800, 1_700_007_200])
    }

    func testAppendTruncatesIssuesButKeepsRealCount() throws {
        let run = makeRun(at: 1_700_000_000, issues: ["a", "b", "c", "d"])
        let history = try store.append(run, to: [])
        let docs = try XCTUnwrap(history.first?.sources.first)
        XCTAssertEqual(docs.issues, ["a", "b"])
        XCTAssertEqual(docs.issueCount, 4)
        XCTAssertTrue(history[0].plainText(duration: "10 s").contains("… et 2 autre(s)"))
    }

    func testAppendSameRunTwiceDoesNotDuplicate() throws {
        let run = makeRun(at: 1_700_000_000)
        let once = try store.append(run, to: [])
        let twice = try store.append(run, to: once)
        XCTAssertEqual(twice.count, 1)
    }

    func testTotalsAndStatusTitle() {
        var run = makeRun(at: 1_700_000_000)
        XCTAssertEqual(run.copiedFiles, 5)
        XCTAssertEqual(run.copiedBytes, 1_000)
        XCTAssertEqual(run.statusTitle, "Terminée")
        run.sources[0].status = .failed
        XCTAssertEqual(run.statusTitle, "1 problème")
        run.cancelled = true
        XCTAssertEqual(run.statusTitle, "Annulée")
        run.finishedAt = nil
        XCTAssertEqual(run.statusTitle, "En cours")
    }
}
