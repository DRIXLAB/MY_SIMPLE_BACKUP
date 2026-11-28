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
        // Fichier « verrouillé » d'un test : déverrouillé pour pouvoir tout supprimer.
        _ = chflags(source.appendingPathComponent("verrouille.txt").path, 0)
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

    func testWholeChainSharesOneKey() throws {
        _ = try backup().run()
        try write("a.txt", "alpha modifié", ageSeconds: 60)
        _ = try backup().run()
        let chain = try XCTUnwrap(ChainLayout.currentChain(in: destination))
        XCTAssertEqual(chain.steps.count, 2)
        let salts = try chain.steps.flatMap { step in
            try [ChainLayout.dataFolder, ChainLayout.journalFolder].map {
                try EncryptedArchive.readKeyParameters(in: step.url.appendingPathComponent($0)).salt
            }
        }
        XCTAssertEqual(Set(salts).count, 1, "une seule dérivation du mot de passe pour toute la chaîne")
        // Une nouvelle chaîne a sa propre clé.
        _ = try backup().run(startNewChain: true)
        let fresh = try XCTUnwrap(ChainLayout.currentChain(in: destination)?.steps.first)
        XCTAssertNotEqual(try EncryptedArchive.readKeyParameters(in: fresh.url.appendingPathComponent(ChainLayout.journalFolder)).salt,
                          salts[0])
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
        // Même seconde que la première chaîne : son dossier doit quand même être distinct.
        let fresh = try backup().run(startNewChain: true)
        XCTAssertEqual(fresh.step, 0)
        XCTAssertEqual(fresh.kind, .complete)
        XCTAssertEqual(fresh.changedFiles, 3)
        XCTAssertNotEqual(fresh.chainName, first.chainName)
        XCTAssertEqual(ChainLayout.chains(in: destination).map(\.lastPathComponent), [fresh.chainName])
    }

    func testOtherPasswordNeverExtendsTheChain() throws {
        _ = try backup().run()
        try write("a.txt", "alpha modifié", ageSeconds: 60)
        var options = ICloudChainBackup.Options()
        options.iterations = 1_000
        let other = ICloudChainBackup(source: source, destination: destination, cacheFile: cache,
                                      password: "autre", options: options, uploader: nil)
        XCTAssertThrowsError(try other.run()) { error in
            XCTAssertEqual(error as? ICloudChainBackup.Failure, .passwordMismatch("Documents"))
        }
        XCTAssertEqual(ChainLayout.currentChain(in: destination)?.steps.count, 1, "aucune étape ajoutée")
        // Nouvelle chaîne demandée : le nouveau mot de passe est accepté.
        XCTAssertEqual(try other.run(startNewChain: true).step, 0)
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

    // MARK: Originaux jamais modifiés

    /// Empreinte complète de chaque élément de la source (sauf la date de dernier accès, que toute
    /// lecture met à jour) : contenu, inode, nombre de liens, droits, drapeaux, dates de
    /// modification, de changement d'état et de création, attributs étendus.
    private func fingerprint() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let paths = (fm.enumerator(atPath: source.path)?.allObjects as? [String]) ?? []
        for rel in paths + [""] {
            let path = rel.isEmpty ? source.path : source.appendingPathComponent(rel).path
            var info = stat()
            let status = lstat(path, &info)
            XCTAssertEqual(status, 0, path)
            func time(_ t: timespec) -> String { "\(t.tv_sec).\(t.tv_nsec)" }
            var fields = ["inode \(info.st_ino)", "liens \(info.st_nlink)", "mode \(info.st_mode)",
                          "drapeaux \(info.st_flags)", "taille \(info.st_size)",
                          "modif \(time(info.st_mtimespec))", "etat \(time(info.st_ctimespec))",
                          "creation \(time(info.st_birthtimespec))"]
            if info.st_mode & S_IFMT == S_IFREG {
                fields.append("contenu " + (try Data(contentsOf: URL(fileURLWithPath: path))).base64EncodedString())
            }
            let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            if length > 0 {
                var names = [CChar](repeating: 0, count: length)
                _ = listxattr(path, &names, length, XATTR_NOFOLLOW)
                fields.append("xattr \(names)")
            }
            result[rel] = fields
        }
        return result
    }

    private func leftoverStaging() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("msb-lot-") }
    }

    func testOriginalsAreNeverModified() throws {
        // Cas délicats : attribut étendu, lien symbolique, fichier « verrouillé » dans le Finder,
        // fichier en lecture seule, dossier vide.
        let tagged = source.appendingPathComponent("a.txt").path
        let tag = Array("rouge".utf8)
        XCTAssertEqual(setxattr(tagged, "com.example.etiquette", tag, tag.count, 0, 0), 0)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("lien").path, withDestinationPath: "a.txt")
        try write("verrouille.txt", "ne pas toucher")
        try write("lecture-seule.txt", "lecture seule")
        XCTAssertEqual(chmod(source.appendingPathComponent("lecture-seule.txt").path, 0o444), 0)
        try fm.createDirectory(at: source.appendingPathComponent("vide"), withIntermediateDirectories: true)
        XCTAssertEqual(chflags(source.appendingPathComponent("verrouille.txt").path, UInt32(UF_IMMUTABLE)), 0)
        let staleBefore = Set(leftoverStaging())

        let before = try fingerprint()
        XCTAssertEqual(try backup().run().changedFiles, 5)
        XCTAssertEqual(try fingerprint(), before, "archive complète")

        try write("c.txt", "charlie modifié", ageSeconds: 60)
        let beforeIncrement = try fingerprint()
        XCTAssertEqual(try backup().run().step, 1)
        XCTAssertEqual(try fingerprint(), beforeIncrement, "incrément")

        // Aucune copie de travail laissée, même pour le fichier verrouillé.
        XCTAssertEqual(Set(leftoverStaging()), staleBefore)

        // Restauration : contenu et attribut étendu retrouvés.
        let element = try XCTUnwrap(ICloudChainRestore.elements(in: destination.deletingLastPathComponent()).first)
        let restore = ICloudChainRestore(element: element, password: "secret")
        let target = root.appendingPathComponent("restaure")
        let outcome = try restore.restore(upTo: 1, journals: try restore.journals(), to: target)
        XCTAssertEqual(outcome.issues, [])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("verrouille.txt")), "ne pas toucher")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("c.txt")), "charlie modifié")
        var value = [UInt8](repeating: 0, count: 16)
        let length = getxattr(target.appendingPathComponent("a.txt").path, "com.example.etiquette", &value, 16, 0, 0)
        XCTAssertEqual(length, 5)
        XCTAssertEqual(Array(value.prefix(5)), tag)
    }

    func testDestinationInsideSourceIsRefusedBeforeAnyWrite() throws {
        let before = try fingerprint()
        let inside = ICloudChainBackup(source: source, destination: source.appendingPathComponent("iCloud/Documents"),
                                       cacheFile: cache, password: "secret", uploader: nil)
        XCTAssertThrowsError(try inside.run()) { error in
            guard case SyncError.overlappingPaths = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try fingerprint(), before, "rien n'a été écrit dans la source")
        // Source dans la destination : refusé aussi.
        let around = ICloudChainBackup(source: source, destination: root, cacheFile: cache, password: "secret", uploader: nil)
        XCTAssertThrowsError(try around.run())
    }
}
#endif
