import XCTest
@testable import BackupCore

final class ArchivePlanTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("d/vide"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appendingPathComponent("a.txt"))
        try Data(count: 20).write(to: root.appendingPathComponent("d/b.txt"))
        try Data(count: 5).write(to: root.appendingPathComponent("d/._b.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("lien").path, withDestinationPath: "a.txt")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func item(_ path: String, _ size: Int64) -> ArchiveItem {
        ArchiveItem(path: path, kind: .file, size: size, modificationDate: Date(timeIntervalSince1970: 0))
    }

    func testScanListsFilesLinksAndDirectoriesSorted() throws {
        let scan = try ArchivePlan.scan(root)
        XCTAssertEqual(scan.items.map(\.path), ["a.txt", "d", "d/._b.txt", "d/b.txt", "d/vide", "lien"])
        XCTAssertEqual(scan.items.map(\.kind), [.file, .directory, .file, .file, .directory, .symlink])
        XCTAssertEqual(scan.totalSize, 35)
        XCTAssertEqual(scan.issues, [])
    }

    func testScanOfMissingRootThrows() {
        XCTAssertThrowsError(try ArchivePlan.scan(root.appendingPathComponent("absent")))
    }

    func testScanCanBeCancelled() {
        XCTAssertThrowsError(try ArchivePlan.scan(root, isCancelled: { true })) { error in
            XCTAssertEqual(error as? SyncError, .cancelled)
        }
    }

    func testBatchesRespectPartSize() {
        let items = [item("a", 40), item("b", 40), item("c", 40), item("d", 10)]
        let batches = ArchivePlan.batches(items, partSize: 100)
        XCTAssertEqual(batches.map { $0.map(\.path) }, [["a", "b"], ["c", "d"]])
    }

    func testOversizedItemFormsItsOwnBatch() {
        let items = [item("a", 10), item("gros", 500), item("b", 10)]
        let batches = ArchivePlan.batches(items, partSize: 100)
        XCTAssertEqual(batches.map { $0.map(\.path) }, [["a"], ["gros"], ["b"]])
    }

    func testBatchesOfNothingIsEmptyAndZeroSizeItemsStayTogether() {
        XCTAssertEqual(ArchivePlan.batches([], partSize: 100).count, 0)
        let dirs = (0..<5).map { ArchiveItem(path: "d\($0)", kind: .directory, size: 0, modificationDate: Date()) }
        XCTAssertEqual(ArchivePlan.batches(dirs, partSize: 100).count, 1)
    }

    func testLogicalFileNameOfICloudPlaceholders() {
        XCTAssertEqual(ArchivePlan.logicalFileName(".archive-0001.aea.icloud"), "archive-0001.aea")
        XCTAssertEqual(ArchivePlan.logicalFileName(".cle.json.icloud"), "cle.json")
        XCTAssertEqual(ArchivePlan.logicalFileName("archive-0001.aea"), "archive-0001.aea")
        XCTAssertEqual(ArchivePlan.logicalFileName(".cache"), ".cache")
        XCTAssertEqual(ArchivePlan.logicalFileName(".icloud"), ".icloud")
    }
}
