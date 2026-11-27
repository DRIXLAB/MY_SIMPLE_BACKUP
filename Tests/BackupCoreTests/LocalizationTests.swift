import XCTest
@testable import BackupCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L10n.language = .french
    }

    func testTrFollowsLanguage() {
        L10n.language = .french
        XCTAssertEqual(tr("Annuler", "Cancel"), "Annuler")
        L10n.language = .english
        XCTAssertEqual(tr("Annuler", "Cancel"), "Cancel")
    }

    func testPluralRules() {
        L10n.language = .french
        XCTAssertEqual(L10n.count(0, "fichier", "fichiers", "file", "files"), "0 fichier")
        XCTAssertEqual(L10n.count(1, "fichier", "fichiers", "file", "files"), "1 fichier")
        XCTAssertEqual(L10n.count(2, "fichier", "fichiers", "file", "files"), "2 fichiers")
        L10n.language = .english
        XCTAssertEqual(L10n.count(0, "fichier", "fichiers", "file", "files"), "0 files")
        XCTAssertEqual(L10n.count(1, "fichier", "fichiers", "file", "files"), "1 file")
        XCTAssertEqual(L10n.count(2, "fichier", "fichiers", "file", "files"), "2 files")
    }

    func testBytes() {
        L10n.language = .french
        XCTAssertEqual(L10n.bytes(512), "512 o")
        XCTAssertEqual(L10n.bytes(1_500_000), "1,5 Mo")
        XCTAssertEqual(L10n.bytes(250_000_000_000), "250 Go")
        L10n.language = .english
        XCTAssertEqual(L10n.bytes(512), "512 bytes")
        XCTAssertEqual(L10n.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(L10n.bytes(2_000_000_000_000), "2 TB")
    }

    func testDuration() {
        XCTAssertEqual(L10n.duration(seconds: 45), "45 s")
        XCTAssertEqual(L10n.duration(seconds: 192), "3 min 12 s")
        XCTAssertEqual(L10n.duration(seconds: 3900), "1 h 05 min")
        XCTAssertEqual(L10n.duration(seconds: -5), "0 s")
    }

    func testDisplaySummaryIsRebuiltInCurrentLanguage() {
        var report = SourceReport(id: "documents", label: "Documents", symbol: "doc.fill")
        report.status = .success
        report.sourceFiles = 3
        report.copiedFiles = 1
        report.copiedBytes = 2_000
        report.deletedItems = 2
        L10n.language = .french
        XCTAssertEqual(report.displaySummary, "3 fichiers  ·  1 copié  ·  2 supprimés  ·  2 Ko")
        L10n.language = .english
        XCTAssertEqual(report.displaySummary, "3 files  ·  1 copied  ·  2 deleted  ·  2 KB")
    }

    func testLegacySummaryIsKeptWhenCountersAreMissing() {
        var report = SourceReport(id: "documents", label: "Documents", symbol: "doc.fill")
        report.status = .success
        report.summary = "ancien résumé"
        L10n.language = .english
        XCTAssertEqual(report.displaySummary, "ancien résumé")
    }

    func testLegacyHistoryWithoutNewFieldsStillDecodes() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","startedAt":"2026-11-01T10:00:00Z",
          "destination":"file:///Volumes/Disque/","deleteMode":false,"cancelled":false,
          "sources":[{"id":"documents","label":"Documents","symbol":"doc.fill","status":"success",
                      "summary":"10 fichiers","issues":[],"issueCount":0,"copiedFiles":2,"copiedBytes":10}]}]
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        try Data(json.utf8).write(to: store.fileURL)
        let runs = store.load()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.sources.first?.displaySummary, "10 fichiers")
    }

    func testCloudSummary() {
        var report = SourceReport(id: "icloud:documents", label: "Documents", symbol: "icloud.fill")
        report.status = .success
        report.sourceFiles = 120
        L10n.language = .french
        XCTAssertTrue(report.isCloud)
        XCTAssertEqual(report.displaySummary, "aucun changement à envoyer  ·  120 fichiers")
        report.cloudStep = 0
        report.cloudFull = true
        report.copiedFiles = 120
        report.copiedBytes = 3_000_000
        XCTAssertEqual(report.displaySummary, "archive complète  ·  120 fichiers envoyés  ·  3 Mo")
        report.cloudStep = 4
        report.cloudFull = false
        report.copiedFiles = 1
        report.copiedBytes = 0
        report.deletedItems = 2
        L10n.language = .english
        XCTAssertEqual(report.displaySummary, "increment #4  ·  1 file uploaded  ·  2 deleted")
    }
}
