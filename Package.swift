// swift-tools-version:5.9
//
// MY SIMPLE BACKUP — compilé avec Swift Package Manager (Xcode 15.0+), sans projet Xcode.
// build.sh assemble ensuite le bundle « MY SIMPLE BACKUP.app » à partir de l'exécutable
// et de Bundle/Info.plist.
//
//   BackupCore      moteur de synchronisation + inventaire des apps (Foundation, testable sous Linux)
//   SauvegardeMac   application SwiftUI (macOS uniquement)
//   icloud-probe    outil de diagnostic de la sauvegarde iCloud (macOS uniquement)

import PackageDescription

var targets: [Target] = [
    .target(name: "BackupCore"),
    .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
]

#if os(macOS)
// L'application n'est déclarée que sur macOS : sous Linux, `swift test` ne compile que le moteur.
targets.append(.executableTarget(name: "SauvegardeMac", dependencies: ["BackupCore"]))
// Diagnostic iCloud (archive chiffrée → iCloud → libération → retéléchargement) :
//   swift run -c release icloud-probe "<dossier de test dans iCloud Drive>"
targets.append(.executableTarget(name: "icloud-probe", dependencies: ["BackupCore"]))
#endif

let package = Package(
    name: "SauvegardeMac",
    platforms: [.macOS(.v13)],
    targets: targets
)
