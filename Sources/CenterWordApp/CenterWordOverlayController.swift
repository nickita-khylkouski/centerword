import AppKit
import SwiftUI

final class CenterWordOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum CenterWordOverlayMode: Equatable {
    case idle
    case loaded
    case error(message: String)
}

@MainActor
final class CenterWordOverlayState: ObservableObject {
    @Published var displayedWord = ""
    @Published var subtitle = ""
    @Published var appearance = TeleprompterLogic.storedAppearance()
    @Published var mode: CenterWordOverlayMode = .idle

    var close: (() -> Void)?
    var openShortcutSettings: (() -> Void)?
}

@MainActor
final class CenterWordOverlayController: NSObject, NSWindowDelegate {
    private let state = CenterWordOverlayState()
    private let engine = TeleprompterEngine()
    private var panel: CenterWordOverlayPanel?
    private var words: [String] = []
    private var currentWordIndex = 0
    private var currentWordsPerMinute = TeleprompterLogic.fallbackWordsPerMinute
    private var pendingAutoCloseTask: Task<Void, Never>?

    private let defaultPanelSize = NSSize(width: 1200, height: 700)
    private let minimumPanelSize = NSSize(width: 760, height: 420)
    private let presentationLeadIn: TimeInterval = 0.35
    private let endAutoCloseDelay: TimeInterval = 1.0

    override init() {}

    func present(text: String, wordsPerMinute: Int) {
        let parsedWords = TeleprompterText.words(in: text)
        guard !parsedWords.isEmpty else {
            CenterWordDiagnostics.record("overlay_present skipped_empty_text")
            presentError(message: "Clipboard does not currently contain readable text.")
            return
        }

        CenterWordDiagnostics.record("overlay_present begin words=\(parsedWords.count) wpm=\(wordsPerMinute)")

        cancelPendingAutoClose()
        engine.stop()
        words = parsedWords
        currentWordIndex = 0
        currentWordsPerMinute = TeleprompterLogic.clampWordsPerMinute(wordsPerMinute)
        state.appearance = TeleprompterLogic.storedAppearance()
        state.mode = .loaded
        state.subtitle = "Loaded \(parsedWords.count) words at \(currentWordsPerMinute) WPM"
        state.displayedWord = formattedWord(words[0])

        CenterWordDiagnostics.record("overlay_present ensure_panel begin")
        let overlayPanel = ensurePanel()
        CenterWordDiagnostics.record("overlay_present ensure_panel end")
        CenterWordDiagnostics.record("overlay_present configure begin")
        configure(panel: overlayPanel)
        CenterWordDiagnostics.record("overlay_present configure end")
        CenterWordDiagnostics.record("overlay_present reveal begin")
        reveal(panel: overlayPanel)
        CenterWordDiagnostics.record("overlay_present reveal end")

        engine.start(
            wordsPerMinute: currentWordsPerMinute,
            initialDelay: presentationLeadIn,
            intervalProvider: currentTokenInterval
        ) { [weak self] in
            self?.advanceWord() ?? false
        }
    }

    func presentError(message: String) {
        CenterWordDiagnostics.record("overlay_present_error \(message)")
        cancelPendingAutoClose()
        engine.stop()
        words = []
        currentWordIndex = 0
        currentWordsPerMinute = TeleprompterLogic.fallbackWordsPerMinute
        state.mode = .error(message: message)
        state.subtitle = "CenterWord couldn't read clipboard text."
        state.displayedWord = ""
        let overlayPanel = ensurePanel()
        configure(panel: overlayPanel)
        reveal(panel: overlayPanel)
    }

    func hide() {
        cancelPendingAutoClose()
        engine.stop()
        panel?.orderOut(nil)
        CenterWordDiagnostics.record("overlay_hide")
    }

    private func ensurePanel() -> CenterWordOverlayPanel {
        if let panel {
            return panel
        }

        CenterWordDiagnostics.record("overlay_ensure_panel create_panel begin")
        let panel = CenterWordOverlayPanel(
            contentRect: NSRect(origin: .zero, size: defaultPanelSize),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        CenterWordDiagnostics.record("overlay_ensure_panel create_panel end")
        CenterWordDiagnostics.record("overlay_ensure_panel configure_panel begin")
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = minimumPanelSize
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        CenterWordDiagnostics.record("overlay_ensure_panel configure_panel end")
        state.close = { [weak self] in self?.hide() }
        state.openShortcutSettings = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
                return
            }
            NSWorkspace.shared.open(url)
        }
        CenterWordDiagnostics.record("overlay_ensure_panel hosting_view begin")
        panel.contentView = NSHostingView(rootView: CenterWordOverlayView(state: state))
        CenterWordDiagnostics.record("overlay_ensure_panel hosting_view end")
        self.panel = panel
        return panel
    }

    private func configure(panel: NSPanel) {
        let targetScreen = activeScreen(for: panel)
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let storedSize = storedPanelSize()
        let panelSize = NSSize(
            width: max(minimumPanelSize.width, min(storedSize.width, visibleFrame.width)),
            height: max(minimumPanelSize.height, min(storedSize.height, visibleFrame.height))
        )
        panel.setContentSize(panelSize)
        let origin = NSPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.midY - (panelSize.height / 2)
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private func reveal(panel: NSPanel) {
        CenterWordActivation.reveal(window: panel)
        for delay in [0.08, 0.24] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak panel] in
                guard let panel else {
                    return
                }
                CenterWordActivation.reveal(window: panel)
            }
        }
    }

    private func advanceWord() -> Bool {
        let nextIndex = currentWordIndex + 1
        guard nextIndex < words.count else {
            engine.stop()
            state.subtitle = "Finished"
            scheduleAutoClose()
            return false
        }

        currentWordIndex = nextIndex
        state.displayedWord = formattedWord(words[nextIndex])
        return true
    }

    private func formattedWord(_ word: String) -> String {
        state.appearance.allCaps ? word.uppercased() : word
    }

    private func currentTokenInterval() -> TimeInterval {
        guard !words.isEmpty else {
            return TeleprompterLogic.secondsPerUnit(wordsPerMinute: currentWordsPerMinute)
        }

        return TeleprompterLogic.displayDuration(
            for: words[currentWordIndex],
            wordsPerMinute: currentWordsPerMinute
        )
    }

    private func activeScreen(for panel: NSPanel) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? panel.screen ?? NSScreen.main
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? CenterWordOverlayPanel else {
            return
        }

        UserDefaults.standard.set(panel.frame.width, forKey: TeleprompterLogic.overlayWidthKey)
        UserDefaults.standard.set(panel.frame.height, forKey: TeleprompterLogic.overlayHeightKey)
    }

    private func storedPanelSize() -> NSSize {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.double(forKey: TeleprompterLogic.overlayWidthKey)
        let storedHeight = defaults.double(forKey: TeleprompterLogic.overlayHeightKey)

        guard storedWidth > 0, storedHeight > 0 else {
            return defaultPanelSize
        }

        return NSSize(width: storedWidth, height: storedHeight)
    }

    private func scheduleAutoClose() {
        cancelPendingAutoClose()
        let delay = endAutoCloseDelay
        pendingAutoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.hide()
            }
        }
    }

    private func cancelPendingAutoClose() {
        pendingAutoCloseTask?.cancel()
        pendingAutoCloseTask = nil
    }
}

private struct CenterWordOverlayView: View {
    @ObservedObject var state: CenterWordOverlayState

    var body: some View {
        ZStack {
            state.appearance.backgroundColor.color
                .ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    if !state.subtitle.isEmpty {
                        Text(state.subtitle)
                            .font(.headline)
                            .foregroundStyle(state.appearance.textColor.color.opacity(0.82))
                    }

                    Spacer()

                    Button("Close") {
                        state.close?()
                    }
                    .buttonStyle(.borderedProminent)
                }

                switch state.mode {
                case .idle:
                    Text("CenterWord")
                        .font(.title.bold())
                        .foregroundStyle(state.appearance.textColor.color)
                case .loaded:
                    Text(state.displayedWord)
                        .font(
                            .system(
                                size: min(state.appearance.fontSize * 1.45, 220),
                                weight: state.appearance.fontWeight.fontWeight,
                                design: state.appearance.fontStyle.design
                            )
                        )
                        .foregroundStyle(state.appearance.textColor.color)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .error(message):
                    VStack(spacing: 18) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.yellow)

                        Text("Couldn't read clipboard text")
                            .font(.title.bold())
                            .foregroundStyle(state.appearance.textColor.color)

                        Text(message)
                            .font(.title3)
                            .foregroundStyle(state.appearance.textColor.color.opacity(0.88))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 640)

                        HStack(spacing: 12) {
                            Button("Open Input Monitoring Settings") {
                                state.openShortcutSettings?()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Dismiss") {
                                state.close?()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(40)
        }
    }
}
