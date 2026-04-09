import SwiftUI

@MainActor
final class CenterWordApplicationDelegate: NSObject, NSApplicationDelegate {
    let session = CenterWordSession()

    private let hotKeyMonitor = CenterWordHotKeyMonitor()
    private lazy var overlayController = CenterWordOverlayController()
    private var allowsTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        CenterWordDiagnostics.record("app_launch begin")
        if terminateIfDuplicateInstanceExists() {
            CenterWordDiagnostics.record("app_launch duplicate_instance_exit")
            return
        }

        NSApplication.shared.setActivationPolicy(.regular)
        LaunchAtLoginManager.ensureEnabled()

        hotKeyMonitor.onPress = { [weak self] in
            self?.handleHotKeyPress()
        }

        let registrationStatus = hotKeyMonitor.install()
        CenterWordDiagnostics.record("app_launch hotkey_status \(registrationStatus.message)")
        Task { @MainActor [weak self] in
            self?.session.updateHotKeyRegistrationStatus(registrationStatus)
            if !registrationStatus.isRegistered {
                self?.session.presentError(registrationStatus.message)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let registrationStatus = hotKeyMonitor.refresh()
        CenterWordDiagnostics.record("app_active hotkey_status \(registrationStatus.message)")
        Task { @MainActor [weak self] in
            self?.session.updateHotKeyRegistrationStatus(registrationStatus)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard allowsTermination else {
            for window in sender.windows {
                window.orderOut(nil)
            }
            sender.hide(nil)
            return .terminateCancel
        }

        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        session.openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyMonitor.uninstall()
    }

    private func handleHotKeyPress() {
        CenterWordDiagnostics.record("hotkey_press accepted")
        let wordsPerMinute = TeleprompterLogic.storedDefaultWordsPerMinute()

        guard let clipboardText = currentClipboardText(),
              !TeleprompterText.words(in: clipboardText).isEmpty else {
            let message = "Clipboard does not currently contain readable text."
            CenterWordDiagnostics.record("hotkey_press clipboard_failure empty_or_unreadable")
            session.recordHotKeyStatus(message)
            overlayController.presentError(message: message)
            NSApp.requestUserAttention(.criticalRequest)
            return
        }

        let wordCount = TeleprompterText.words(in: clipboardText).count
        CenterWordDiagnostics.record("hotkey_press clipboard_success words=\(wordCount) wpm=\(wordsPerMinute)")
        session.recordHotKeyStatus("Showing clipboard at \(wordsPerMinute) WPM")
        overlayController.present(text: clipboardText, wordsPerMinute: wordsPerMinute)
    }

    private func currentClipboardText() -> String? {
        let pasteboard = NSPasteboard.general

        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        let objects = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString]
        if let text = objects?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        return nil
    }

    private func terminateIfDuplicateInstanceExists() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        guard let existing = duplicates.first else {
            return false
        }

        existing.activate()
        allowsTermination = true
        NSApp.terminate(nil)
        return true
    }
}

@main
struct CenterWordApplication: App {
    @NSApplicationDelegateAdaptor(CenterWordApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Window("CenterWord", id: "main") {
            TeleprompterView()
                .environmentObject(appDelegate.session)
                .background(
                    OpenWindowRegistrar { openMainWindow in
                        appDelegate.session.openMainWindow = openMainWindow
                    }
                )
        }
        .defaultSize(width: 900, height: 680)
    }
}

private struct OpenWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    let register: (@escaping () -> Void) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                register {
                    openWindow(id: "main")
                }
            }
    }
}
