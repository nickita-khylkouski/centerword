import Foundation
import AppKit
import ApplicationServices
import SwiftUI

struct CenterWordPermissionSnapshot: Equatable {
    var accessibility: Bool
    var listenEvent: Bool
    var postEvent: Bool

    var clipboardWorkflowReady: Bool {
        listenEvent
    }
}

struct TeleprompterAppearance: Equatable {
    let fontStyle: TeleprompterFontStyle
    let fontWeight: TeleprompterFontWeight
    let textColor: TeleprompterTextColorChoice
    let backgroundColor: TeleprompterBackgroundChoice
    let allCaps: Bool
    let fontSize: Double
}

enum TeleprompterLogic {
    static let fallbackWordsPerMinute = 860
    static let defaultWordsPerMinuteKey = "defaultWordsPerMinute"
    static let onboardingCompletedKey = "hasCompletedOnboarding"
    static let readerFontSizeKey = "readerFontSize"
    static let readerFontStyleKey = "readerFontStyle"
    static let readerFontWeightKey = "readerFontWeight"
    static let readerTextColorKey = "readerTextColor"
    static let readerBackgroundColorKey = "readerBackgroundColor"
    static let readerAllCapsKey = "readerAllCaps"
    static let overlayWidthKey = "overlayWidth"
    static let overlayHeightKey = "overlayHeight"
    static let defaultReaderFontSize = 72.0

    static func clampWordsPerMinute(_ value: Int) -> Int {
        min(max(value, 1), 2_000)
    }

    static func parseWordsPerMinute(from text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard let value = Int(digits), !digits.isEmpty else {
            return nil
        }

        return clampWordsPerMinute(value)
    }

    static func storedDefaultWordsPerMinute(userDefaults: UserDefaults = .standard) -> Int {
        let storedValue = userDefaults.integer(forKey: defaultWordsPerMinuteKey)
        if storedValue == 0 {
            return fallbackWordsPerMinute
        }

        return clampWordsPerMinute(storedValue)
    }

    static func wordsToSeek(forSeconds seconds: TimeInterval, wordsPerMinute: Int) -> Int {
        guard seconds > 0 else {
            return 0
        }

        let words = seconds * Double(clampWordsPerMinute(wordsPerMinute)) / 60.0
        return max(1, Int(words.rounded()))
    }

    static func durationUnits(for token: String) -> Double {
        TeleprompterText.isFastSeparatorToken(token) ? 0.5 : 1.0
    }

    static func secondsPerUnit(wordsPerMinute: Int) -> TimeInterval {
        60.0 / Double(clampWordsPerMinute(wordsPerMinute))
    }

    static func displayDuration(for token: String, wordsPerMinute: Int) -> TimeInterval {
        durationUnits(for: token) * secondsPerUnit(wordsPerMinute: wordsPerMinute)
    }

    static func seekIndex(
        currentIndex: Int,
        bySeconds seconds: TimeInterval,
        wordsPerMinute: Int,
        tokens: [String]
    ) -> Int {
        guard !tokens.isEmpty else {
            return 0
        }

        let clampedIndex = min(max(currentIndex, 0), tokens.count - 1)
        let targetUnits = abs(seconds) * Double(clampWordsPerMinute(wordsPerMinute)) / 60.0
        guard targetUnits > 0 else {
            return clampedIndex
        }

        if seconds < 0 {
            var index = clampedIndex
            var traversedUnits = 0.0

            while index > 0, traversedUnits < targetUnits {
                index -= 1
                traversedUnits += durationUnits(for: tokens[index])
            }

            return index
        }

        var index = clampedIndex
        var traversedUnits = 0.0

        while index < tokens.count - 1, traversedUnits < targetUnits {
            index += 1
            traversedUnits += durationUnits(for: tokens[index])
        }

        return index
    }

    static func elapsedSeconds(currentIndex: Int, tokens: [String], wordsPerMinute: Int) -> TimeInterval {
        guard !tokens.isEmpty else {
            return 0
        }

        let clampedIndex = min(max(currentIndex, 0), tokens.count)
        let elapsedUnits = tokens.prefix(clampedIndex).reduce(0.0) { partialResult, token in
            partialResult + durationUnits(for: token)
        }
        return elapsedUnits * secondsPerUnit(wordsPerMinute: wordsPerMinute)
    }

    static func remainingSeconds(currentIndex: Int, tokens: [String], wordsPerMinute: Int) -> TimeInterval {
        guard !tokens.isEmpty else {
            return 0
        }

        let startIndex = min(max(currentIndex + 1, 0), tokens.count)
        let remainingUnits = tokens[startIndex...].reduce(0.0) { partialResult, token in
            partialResult + durationUnits(for: token)
        }
        return remainingUnits * secondsPerUnit(wordsPerMinute: wordsPerMinute)
    }

    static func clampReaderFontSize(_ value: Double) -> Double {
        min(max(value, 36), 140)
    }

    static func shouldPresentSetupScreen(
        hasCompletedOnboarding: Bool,
        permissionSnapshot: CenterWordPermissionSnapshot,
        hotKeyStatus: CenterWordHotKeyRegistrationStatus
    ) -> Bool {
        !hasCompletedOnboarding && (!permissionSnapshot.clipboardWorkflowReady || !hotKeyStatus.isRegistered)
    }

    static func shouldShowPermissionWarning(
        hasCompletedOnboarding: Bool,
        permissionSnapshot: CenterWordPermissionSnapshot,
        hotKeyStatus: CenterWordHotKeyRegistrationStatus
    ) -> Bool {
        hasCompletedOnboarding && (!permissionSnapshot.clipboardWorkflowReady || !hotKeyStatus.isRegistered)
    }

    static func storedAppearance(userDefaults: UserDefaults = .standard) -> TeleprompterAppearance {
        let fontStyle = TeleprompterFontStyle(
            rawValue: userDefaults.string(forKey: readerFontStyleKey) ?? ""
        ) ?? .rounded
        let fontWeight = TeleprompterFontWeight(
            rawValue: userDefaults.string(forKey: readerFontWeightKey) ?? ""
        ) ?? .bold
        let textColor = TeleprompterTextColorChoice(
            rawValue: userDefaults.string(forKey: readerTextColorKey) ?? ""
        ) ?? .paper
        let backgroundColor = TeleprompterBackgroundChoice(
            rawValue: userDefaults.string(forKey: readerBackgroundColorKey) ?? ""
        ) ?? .charcoal
        let allCaps = userDefaults.bool(forKey: readerAllCapsKey)
        let fontSize = clampReaderFontSize(userDefaults.double(forKey: readerFontSizeKey) == 0 ? defaultReaderFontSize : userDefaults.double(forKey: readerFontSizeKey))

        return TeleprompterAppearance(
            fontStyle: fontStyle,
            fontWeight: fontWeight,
            textColor: textColor,
            backgroundColor: backgroundColor,
            allCaps: allCaps,
            fontSize: fontSize
        )
    }
}

enum TeleprompterFontStyle: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .rounded:
            return "Rounded"
        case .serif:
            return "Serif"
        case .monospaced:
            return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .system:
            return .default
        case .rounded:
            return .rounded
        case .serif:
            return .serif
        case .monospaced:
            return .monospaced
        }
    }
}

enum TeleprompterFontWeight: String, CaseIterable, Identifiable {
    case regular
    case semibold
    case bold
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular:
            return "Regular"
        case .semibold:
            return "Semibold"
        case .bold:
            return "Bold"
        case .heavy:
            return "Heavy"
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .regular:
            return .regular
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        }
    }
}

enum TeleprompterTextColorChoice: String, CaseIterable, Identifiable {
    case paper
    case pureWhite
    case mint
    case amber
    case sky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper:
            return "Paper"
        case .pureWhite:
            return "White"
        case .mint:
            return "Mint"
        case .amber:
            return "Amber"
        case .sky:
            return "Sky"
        }
    }

    var color: Color {
        switch self {
        case .paper:
            return Color(red: 0.96, green: 0.94, blue: 0.90)
        case .pureWhite:
            return .white
        case .mint:
            return Color(red: 0.75, green: 0.97, blue: 0.85)
        case .amber:
            return Color(red: 1.00, green: 0.86, blue: 0.52)
        case .sky:
            return Color(red: 0.76, green: 0.90, blue: 1.00)
        }
    }
}

enum TeleprompterBackgroundChoice: String, CaseIterable, Identifiable {
    case charcoal
    case black
    case navy
    case forest
    case plum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .charcoal:
            return "Charcoal"
        case .black:
            return "Black"
        case .navy:
            return "Navy"
        case .forest:
            return "Forest"
        case .plum:
            return "Plum"
        }
    }

    var color: Color {
        switch self {
        case .charcoal:
            return Color(red: 0.17, green: 0.16, blue: 0.15)
        case .black:
            return Color(red: 0.05, green: 0.05, blue: 0.06)
        case .navy:
            return Color(red: 0.08, green: 0.12, blue: 0.22)
        case .forest:
            return Color(red: 0.07, green: 0.16, blue: 0.12)
        case .plum:
            return Color(red: 0.19, green: 0.10, blue: 0.17)
        }
    }
}

enum CenterWordActivation {
    static let revealCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
    ]

    @MainActor
    static func revealApplication() {
        CenterWordDiagnostics.record("activation_reveal_application begin")
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.arrangeInFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        CenterWordDiagnostics.record("activation_reveal_application end")
    }

    @MainActor
    static func reveal(window: NSWindow) {
        CenterWordDiagnostics.record("activation_reveal_window begin")
        if window is CenterWordOverlayPanel {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.level = .screenSaver
            NSApp.setActivationPolicy(.regular)
            CenterWordDiagnostics.record("activation_reveal_window overlay_unhide")
            NSApp.unhide(nil)
            CenterWordDiagnostics.record("activation_reveal_window overlay_make_key_and_front")
            window.makeKeyAndOrderFront(nil)
            CenterWordDiagnostics.record("activation_reveal_window overlay_order_front")
            window.orderFrontRegardless()
            CenterWordDiagnostics.record("activation_reveal_window overlay_order_above")
            window.order(.above, relativeTo: 0)
            CenterWordDiagnostics.record("activation_reveal_window overlay_activate_running_app")
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            CenterWordDiagnostics.record("activation_reveal_window overlay_activate_appkit")
            NSApp.activate(ignoringOtherApps: true)
            CenterWordDiagnostics.record("activation_reveal_window overlay_arrange_in_front")
            NSApp.arrangeInFront(nil)
            CenterWordDiagnostics.record("activation_reveal_window overlay_end")
            return
        }

        prepare(window: window)
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        bringToFront(window)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.arrangeInFront(nil)
        CenterWordDiagnostics.record("activation_reveal_window end")
    }

    @MainActor
    static func prepare(window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.formUnion(revealCollectionBehavior)
    }

    @MainActor
    static func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

struct TeleprompterLaunchRequest: Identifiable {
    let id = UUID()
    let text: String
    let wordsPerMinute: Int
}

@MainActor
final class CenterWordSession: ObservableObject {
    @Published var errorMessage: String?
    @Published private(set) var hotKeyStatusMessage: String?
    @Published private(set) var hotKeyRegistrationStatus: CenterWordHotKeyRegistrationStatus = .unavailable("Cmd+Option+S is not ready yet.")
    @Published private(set) var launchRequest: TeleprompterLaunchRequest?

    var openMainWindow: (() -> Void)?

    func presentCapturedText(_ text: String, wordsPerMinute: Int) {
        errorMessage = nil
        hotKeyStatusMessage = "Captured \(TeleprompterText.words(in: text).count) words"
        CenterWordDiagnostics.record("session_present_captured_text words=\(TeleprompterText.words(in: text).count) wpm=\(wordsPerMinute)")
        launchRequest = TeleprompterLaunchRequest(
            text: text,
            wordsPerMinute: TeleprompterLogic.clampWordsPerMinute(wordsPerMinute)
        )
        revealWindow()
    }

    func presentError(_ message: String) {
        errorMessage = message
        hotKeyStatusMessage = message
        CenterWordDiagnostics.record("session_present_error \(message)")
        revealWindow()
        NSApp.requestUserAttention(.criticalRequest)
    }

    func presentCaptureError(_ message: String) {
        presentError(message)
    }

    func clearError() {
        errorMessage = nil
    }

    func consumeLaunchRequest() {
        launchRequest = nil
    }

    func recordHotKeyStatus(_ message: String) {
        hotKeyStatusMessage = message
        CenterWordDiagnostics.record("session_hotkey_status \(message)")
    }

    func updateHotKeyRegistrationStatus(_ status: CenterWordHotKeyRegistrationStatus) {
        hotKeyRegistrationStatus = status
        if !status.isRegistered {
            hotKeyStatusMessage = status.message
        }
    }

    private func revealWindow() {
        if NSApp.windows.isEmpty {
            openMainWindow?()
        }

        pruneRedundantWindows()
        revealExistingWindows()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.pruneRedundantWindows()
            self.revealExistingWindows()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.pruneRedundantWindows()
            self.revealExistingWindows()
        }
    }

    private func revealExistingWindows() {
        for window in NSApp.windows {
            CenterWordActivation.reveal(window: window)
        }
    }

    private func pruneRedundantWindows() {
        let windows = NSApp.windows
        guard windows.count > 1 else {
            return
        }

        for window in windows.dropFirst() {
            window.close()
        }
    }
}

@MainActor
final class TeleprompterEngine {
    private var playbackTask: Task<Void, Never>?

    func start(
        wordsPerMinute: Int,
        initialDelay: TimeInterval = 0,
        intervalProvider: (@MainActor () -> TimeInterval)? = nil,
        tick: @escaping @MainActor () -> Bool
    ) {
        stop()

        let clampedWordsPerMinute = TeleprompterLogic.clampWordsPerMinute(wordsPerMinute)
        playbackTask = Task {
            if initialDelay > 0 {
                try? await Task.sleep(for: .seconds(initialDelay))
            }

            while !Task.isCancelled {
                let interval = await MainActor.run {
                    intervalProvider?() ?? TeleprompterLogic.secondsPerUnit(wordsPerMinute: clampedWordsPerMinute)
                }

                try? await Task.sleep(for: .seconds(interval))

                if Task.isCancelled {
                    break
                }

                let shouldContinue = await MainActor.run(body: tick)
                if !shouldContinue {
                    break
                }
            }
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    deinit {
        playbackTask?.cancel()
    }
}
