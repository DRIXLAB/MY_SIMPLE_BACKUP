import XCTest
@testable import BackupCore

final class SyncEngineTests: XCTestCase {
    var root: URL!
    var src: URL!
    var dst: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        L10n.language = .french
        root = fm.temporaryDirectory.appendingPathComponent("synctest-\(UUID().uuidString)")
        src = root.appendingPathComponent("source")
        dst = root.appendingPathComponent("backup/dest")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    func write(_ rel: String, _ content: String, in base: URL? = nil, mtime: Date? = nil) throws -> URL {
        let url = (base ?? src).appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    func read(_ rel: String, in base: URL? = nil) -> String? {
        (try? Data(contentsOf: (base ?? dst).appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ rel: String, in base: URL? = nil) -> Bool {
        Entry.read(atPath: (base ?? dst).appendingPathComponent(rel).path) != nil
    }

    func sync(delete: Bool = false, engine: SyncEngine = SyncEngine(),
              cancel: @escaping () -> Bool = { false },
              progress: @escaping (SyncProgress) -> Void = { _ in }) throws -> SyncStats {
        try engine.sync(source: src, destination: dst,
                        options: SyncOptions(deleteExtraneous: delete),
                        isCancelled: cancel, progress: progress)
    }

    func tempFiles(in base: URL) -> [String] {
        (fm.enumerator(atPath: base.path)?.allObjects as? [String] ?? [])
            .filter { SyncEngine.isTempName(($0 as NSString).lastPathComponent) }
    }

    // MARK: Copie

    func testInitialCopyReproducesTreeContentAndDates() throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try write("a.txt", "alpha", mtime: date)
        try write("sous/dossier/b.txt", "bravo")
        try write("Photos Library.photoslibrary/database/c.db", "charlie")
        try fm.createDirectory(at: src.appendingPathComponent("vide"), withIntermediateDirectories: true)

        let stats = try sync()

        XCTAssertEqual(read("a.txt"), "alpha")
        XCTAssertEqual(read("sous/dossier/b.txt"), "bravo")
        XCTAssertEqual(read("Photos Library.photoslibrary/database/c.db"), "charlie")
        XCTAssertEqual(Entry.read(atPath: dst.appendingPathComponent("vide").path)?.kind, .directory)
        XCTAssertEqual(stats.sourceFiles, 3)
        XCTAssertEqual(stats.copiedFiles, 3)
        XCTAssertEqual(stats.copiedBytes, 5 + 5 + 7)
        XCTAssertEqual(stats.issues, [])
        let copiedDate = Entry.read(atPath: dst.appendingPathComponent("a.txt").path)!.modificationDate
        XCTAssertEqual(copiedDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(tempFiles(in: dst), [])
    }

    func testSecondRunCopiesNothing() throws {
        try write("a.txt", "alpha")
        try write("d/b.txt", "bravo")
        _ = try sync()

        let stats = try sync()
        XCTAssertEqual(stats.copiedFiles, 0)
        XCTAssertEqual(stats.sourceFiles, 2)
    }

    func testChangedSizeOrDateIsRecopied() throws {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try write("taille.txt", "v1", mtime: old)
        try write("date.txt", "aaaa", mtime: old)
        try write("intact.txt", "zzz", mtime: old)
        _ = try sync()

        try write("taille.txt", "version 2", mtime: old)
        try write("date.txt", "bbbb", mtime: old.addingTimeInterval(60))
        let stats = try sync()

        XCTAssertEqual(stats.copiedFiles, 2)
        XCTAssertEqual(read("taille.txt"), "version 2")
        XCTAssertEqual(read("date.txt"), "bbbb")
    }

    func testDateWithinModifyWindowIsConsideredUpToDate() throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try write("a.txt", "alpha", mtime: date)
        _ = try sync()
        try fm.setAttributes([.modificationDate: date.addingTimeInterval(1)],
                             ofItemAtPath: dst.appendingPathComponent("a.txt").path)
        XCTAssertEqual(try sync().copiedFiles, 0)
    }

    func testPermissionsArePreservedAndUpdated() throws {
        let file = try write("script.sh", "#!/bin/sh")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        _ = try sync()
        XCTAssertEqual(Entry.read(atPath: dst.appendingPathComponent("script.sh").path)?.permissions, 0o755)

        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let stats = try sync()
        XCTAssertEqual(stats.copiedFiles, 0)
        XCTAssertEqual(Entry.read(atPath: dst.appendingPathComponent("script.sh").path)?.permissions, 0o600)
    }

    func testReadOnlyDirectoryRemainsWritableForNextBackup() throws {
        try write("ro/a.txt", "alpha")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.appendingPathComponent("ro").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("ro").path) }
        _ = try sync()
        let perms = Entry.read(atPath: dst.appendingPathComponent("ro").path)!.permissions
        XCTAssertEqual(perms & 0o700, 0o700)
    }

    func testSpecialPermissionBitsAreNeverCopied() throws {
        let file = try write("outil", "#!/bin/sh")
        try fm.setAttributes([.posixPermissions: 0o4755], ofItemAtPath: file.path)
        _ = try sync()
        _ = try sync()
        let perms = try XCTUnwrap(Entry.read(atPath: dst.appendingPathComponent("outil").path)?.permissions)
        XCTAssertEqual(perms & 0o7777, 0o755)
    }

    func testDeepTreeIsCopied() throws {
        let deep = (0..<200).map { _ in "d" }.joined(separator: "/")
        try write(deep + "/fond.txt", "tout au fond")
        let stats = try sync()
        XCTAssertEqual(read(deep + "/fond.txt"), "tout au fond")
        XCTAssertEqual(stats.issues, [])
    }

    #if canImport(Darwin)
    /// macOS uniquement (lancé par build.sh) : étiquettes Finder & co. via copyfile(COPYFILE_XATTR).
    func testExtendedAttributesAreCopied() throws {
        let file = try write("etiquette.txt", "x")
        let value = Array("valeur".utf8)
        XCTAssertEqual(setxattr(file.path, "com.cepe.test", value, value.count, 0, 0), 0)
        _ = try sync()
        var buffer = [UInt8](repeating: 0, count: 64)
        let size = getxattr(dst.appendingPathComponent("etiquette.txt").path, "com.cepe.test", &buffer, buffer.count, 0, 0)
        XCTAssertEqual(size, value.count)
        XCTAssertEqual(Array(buffer.prefix(max(size, 0))), value)
    }
    #endif

    // MARK: Suppression

    func testExtraneousItemsAreKeptWithoutDeleteOption() throws {
        try write("a.txt", "alpha")
        try write("ancien.txt", "old", in: dst)
        try write("ancien-dossier/x.txt", "old", in: dst)

        let stats = try sync(delete: false)
        XCTAssertTrue(exists("ancien.txt"))
        XCTAssertTrue(exists("ancien-dossier/x.txt"))
        XCTAssertEqual(stats.deletedItems, 0)
    }

    func testExtraneousItemsAreDeletedWithDeleteOption() throws {
        try write("a.txt", "alpha")
        try write("garde/b.txt", "bravo")
        try write("ancien.txt", "old", in: dst)
        try write("garde/ancien.txt", "old", in: dst)
        try write("ancien-dossier/x/y.txt", "old", in: dst)

        let stats = try sync(delete: true)
        XCTAssertFalse(exists("ancien.txt"))
        XCTAssertFalse(exists("garde/ancien.txt"))
        XCTAssertFalse(exists("ancien-dossier"))
        XCTAssertEqual(read("garde/b.txt"), "bravo")
        XCTAssertEqual(stats.deletedItems, 3)
    }

    func testCaseOnlyDifferenceIsNeverDeleted() throws {
        try write("Rapport.txt", "nouveau")
        try write("rapport.txt", "ancien", in: dst)
        _ = try sync(delete: true)
        // Volume sensible à la casse (Linux) : les deux coexistent ; insensible (macOS) : un seul fichier, à jour.
        XCTAssertEqual(read("Rapport.txt"), "nouveau")
    }

    func testEmptySourceDoesNotWipeDestination() throws {
        try write("precieux.txt", "data", in: dst)
        let stats = try sync(delete: true)
        XCTAssertTrue(exists("precieux.txt"))
        XCTAssertEqual(stats.deletedItems, 0)
        XCTAssertEqual(stats.issues.count, 1)
    }

    func testUnreadableSourceSubdirectoryDeletesNothingInDestination() throws {
        try write("a.txt", "alpha")
        try write("prive/secret.txt", "s")
        _ = try sync()

        let engine = SyncEngine()
        let blocked = SyncEngine.resolvedPath(src.appendingPathComponent("prive").path)
        engine.listSourceDirectory = { path in
            if path == blocked { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }
        let stats = try sync(delete: true, engine: engine)
        XCTAssertEqual(read("prive/secret.txt"), "s")
        XCTAssertEqual(stats.issues.map(\.path), ["prive"])
    }

    func testUnreadableSourceRootThrows() throws {
        try write("a.txt", "alpha", in: dst)
        let engine = SyncEngine()
        engine.listSourceDirectory = { _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertThrowsError(try sync(delete: true, engine: engine)) { error in
            guard case SyncError.sourceUnreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(exists("a.txt"))
    }

    func testDeletingDirectoryDoesNotFollowSymlinksOutside() throws {
        let outside = try write("important.txt", "ne pas toucher", in: root.appendingPathComponent("ailleurs"))
        try write("a.txt", "alpha")
        try fm.createDirectory(at: dst.appendingPathComponent("ancien"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dst.appendingPathComponent("ancien/lien").path,
                                  withDestinationPath: outside.deletingLastPathComponent().path)
        try fm.createSymbolicLink(atPath: dst.appendingPathComponent("lien-racine").path,
                                  withDestinationPath: outside.deletingLastPathComponent().path)

        _ = try sync(delete: true)
        XCTAssertFalse(exists("ancien"))
        XCTAssertFalse(exists("lien-racine"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "ne pas toucher")
    }

    func testAppleDoubleFilesOfExistingFilesAreKept() throws {
        try write("photo.jpg", "jpeg")
        try write("._photo.jpg", "métadonnées", in: dst)
        try write("._disparu.jpg", "métadonnées orphelines", in: dst)

        let stats = try sync(delete: true)
        XCTAssertEqual(stats.issues, [])
        XCTAssertEqual(read("._photo.jpg"), "métadonnées")
        XCTAssertFalse(exists("._disparu.jpg"))
        XCTAssertEqual(stats.deletedItems, 1)
    }

    func testListDirectoryShowsEverythingExceptDotEntries() throws {
        try write("._metadonnees", "x")
        try write(".cache", "x")
        try write("été.txt", "x")
        try fm.createDirectory(at: src.appendingPathComponent("dossier"), withIntermediateDirectories: true)
        XCTAssertEqual(try SyncEngine.listDirectory(src.path).sorted(), ["._metadonnees", ".cache", "dossier", "été.txt"])
        XCTAssertThrowsError(try SyncEngine.listDirectory(root.appendingPathComponent("absent").path))
    }

    func testAppleDoubleFilesInSourceAreBackedUp() throws {
        try write("archive/._document.pdf", "métadonnées")
        try write("archive/document.pdf", "pdf")
        _ = try sync()
        XCTAssertEqual(read("archive/._document.pdf"), "métadonnées")
    }

    // MARK: Disque débranché

    func testDestinationRemovedMidwayStopsWithError() throws {
        for i in 0..<10 { try write("f\(i).txt", "contenu \(i)") }
        // La vérification d'annulation est appelée avant chaque action : on y simule le débranchement.
        var calls = 0
        var removed = false
        let destination = dst!
        XCTAssertThrowsError(try sync(cancel: {
            calls += 1
            if calls == 8, !removed {
                removed = true
                try? FileManager.default.removeItem(at: destination)
            }
            return false
        })) { error in
            guard case SyncError.destinationUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(removed)
    }

    // MARK: Conflits de type

    func testDestinationSymlinkInPlaceOfDirectoryIsReplacedNotFollowed() throws {
        let outsideDir = root.appendingPathComponent("ailleurs")
        try write("garder.txt", "intact", in: outsideDir)
        try write("photos/p.jpg", "jpeg")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dst.appendingPathComponent("photos").path, withDestinationPath: outsideDir.path)

        _ = try sync()
        XCTAssertEqual(Entry.read(atPath: dst.appendingPathComponent("photos").path)?.kind, .directory)
        XCTAssertEqual(read("photos/p.jpg"), "jpeg")
        XCTAssertFalse(exists("p.jpg", in: outsideDir))
        XCTAssertEqual(read("garder.txt", in: outsideDir), "intact")
    }

    func testFileReplacedByDirectoryAndBack() throws {
        try write("x/inside.txt", "dir")
        try write("x", "file", in: dst)
        _ = try sync()
        XCTAssertEqual(read("x/inside.txt"), "dir")

        try fm.removeItem(at: src.appendingPathComponent("x"))
        try write("x", "file again")
        let kept = try sync(delete: false)
        XCTAssertEqual(kept.issues.map(\.path), ["x"])
        XCTAssertEqual(read("x/inside.txt"), "dir")

        _ = try sync(delete: true)
        XCTAssertEqual(read("x"), "file again")
    }

    // MARK: Liens symboliques

    func testSafeLinksCopiedUnsafeLinksSkipped() throws {
        try write("docs/a.txt", "alpha")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("docs/rel").path, withDestinationPath: "a.txt")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("docs/parent").path, withDestinationPath: "../docs/a.txt")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("absolu").path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("docs/sortie").path, withDestinationPath: "../../x")

        let stats = try sync()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("docs/rel").path), "a.txt")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("docs/parent").path), "../docs/a.txt")
        XCTAssertFalse(exists("absolu"))
        XCTAssertFalse(exists("docs/sortie"))
        XCTAssertEqual(stats.skippedItems, 2)
        XCTAssertEqual(stats.copiedFiles, 1)

        XCTAssertEqual(try sync().copiedFiles, 0)
    }

    func testIsSafeLinkRule() {
        XCTAssertTrue(SyncEngine.isSafeLink(target: "a", linkDirectory: ""))
        XCTAssertTrue(SyncEngine.isSafeLink(target: "../b", linkDirectory: "x"))
        XCTAssertTrue(SyncEngine.isSafeLink(target: "./c/../d", linkDirectory: ""))
        XCTAssertFalse(SyncEngine.isSafeLink(target: "../b", linkDirectory: ""))
        XCTAssertFalse(SyncEngine.isSafeLink(target: "x/../../b", linkDirectory: ""))
        XCTAssertFalse(SyncEngine.isSafeLink(target: "/abs", linkDirectory: "x"))
    }

    // MARK: Sécurité des chemins

    func testOverlappingPathsAreRefused() throws {
        try write("a.txt", "alpha")
        let engine = SyncEngine()
        for destination in [src!, src.appendingPathComponent("sous/backup"), src.deletingLastPathComponent()] {
            XCTAssertThrowsError(try engine.sync(source: src, destination: destination)) { error in
                guard case SyncError.overlappingPaths = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertFalse(exists("sous", in: src))
    }

    func testOverlapDetectedThroughSymlink() throws {
        try write("a.txt", "alpha")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: src.path)
        XCTAssertThrowsError(try SyncEngine().sync(source: src, destination: alias.appendingPathComponent("backup")))
    }

    func testPathsOverlapRule() {
        XCTAssertTrue(SyncEngine.pathsOverlap("/a/b", "/a/b"))
        XCTAssertTrue(SyncEngine.pathsOverlap("/a/b", "/a/b/c"))
        XCTAssertTrue(SyncEngine.pathsOverlap("/a/b/c", "/A/B"))
        XCTAssertFalse(SyncEngine.pathsOverlap("/a/b", "/a/bc"))
        XCTAssertFalse(SyncEngine.pathsOverlap("/Users/x/Music", "/Volumes/Disque/Music"))
    }

    func testMissingSourceThrows() {
        XCTAssertThrowsError(try SyncEngine().sync(source: root.appendingPathComponent("absent"), destination: dst)) { error in
            XCTAssertEqual(error as? SyncError, .sourceNotFound(root.appendingPathComponent("absent").path))
        }
    }

    // MARK: Fichiers temporaires, annulation, progression

    func testStaleTempFilesAreCleanedEvenWithoutDelete() throws {
        try write("a.txt", "alpha")
        try write(".sauvegarde-deadbeef.tmp", "partiel", in: dst)
        _ = try sync(delete: false)
        XCTAssertEqual(tempFiles(in: dst), [])
    }

    func testCancellationStopsAndLeavesNoTempFile() throws {
        for i in 0..<20 { try write("f\(i).txt", String(repeating: "x", count: 1000)) }
        var calls = 0
        XCTAssertThrowsError(try sync(cancel: { calls += 1; return calls > 30 })) { error in
            XCTAssertEqual(error as? SyncError, .cancelled)
        }
        XCTAssertEqual(tempFiles(in: dst), [])
        let copied = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
        XCTAssertLessThan(copied.count, 20)
    }

    func testProgressReachesTotal() throws {
        try write("a.bin", String(repeating: "a", count: 10_000))
        try write("b/c.bin", String(repeating: "c", count: 5_000))
        var last: SyncProgress?
        var sawTransfer = false
        _ = try sync(progress: { p in
            last = p
            if p.phase == .transferring { sawTransfer = true }
        })
        XCTAssertTrue(sawTransfer)
        XCTAssertEqual(last?.bytesTotal, 15_000)
        XCTAssertEqual(last?.bytesDone, 15_000)
        XCTAssertEqual(last?.filesDone, 2)
        XCTAssertEqual(last?.fraction, 1)
    }

    func testLargeFileCopiedInChunks() throws {
        let size = 3 * 1024 * 1024 + 17
        let data = Data((0..<size).map { UInt8($0 % 251) })
        try data.write(to: src.appendingPathComponent("gros.bin"))
        _ = try SyncEngine().sync(source: src, destination: dst, options: SyncOptions(chunkSize: 64 * 1024))
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("gros.bin")), data)
    }

    func testCancellationFlag() {
        let flag = CancellationFlag()
        XCTAssertFalse(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }
}
