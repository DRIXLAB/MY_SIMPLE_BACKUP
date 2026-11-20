import AppKit
import BackupCore
import SwiftUI

@main
struct SauvegardeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = BackupController()

    var body: some Scene {
        Window("MY SIMPLE BACKUP", id: "main") {
            ContentView(controller: controller)
                .onAppear { appDelegate.controller = controller }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(tr("Historique des sauvegardes…", "Backup History…")) { controller.showHistory = true }
                    .keyboardShortcut("y", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: BackupController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘Q pendant une sauvegarde : confirmation, puis arrêt propre (voir `BackupController.shouldTerminate`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shouldTerminate() ?? .terminateNow
    }
}
