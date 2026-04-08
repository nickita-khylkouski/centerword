import Foundation
import AppKit
import ApplicationServices
import SwiftUI

enum TeleprompterLogic {
    static let fallbackWordsPerMinute = 860
    static let defaultWordsPerMinuteKey = "defaultWordsPerMinute"
    static let readerFontSizeKey = "readerFontSize"
    static let readerFontStyleKey = "readerFontStyle"
    static let readerFontWeightKey = "readerFontWeight"
    static let readerTextColorKey = "readerTextColor"
    static let readerBackgroundColorKey = "readerBackgroundColor"
    static let readerAllCapsKey = "readerAllCaps"
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

    static func seekIndex(
        currentIndex: Int,
        bySeconds seconds: TimeInterval,
        wordsPerMinute: Int,
        totalWords: Int
    ) -> Int {
        guard totalWords > 0 else {
            return 0
        }

        let step = wordsToSeek(forSeconds: abs(seconds), wordsPerMinute: wordsPerMinute)
        let signedStep = seconds < 0 ? -step : step
        return min(max(currentIndex + signedStep, 0), totalWords - 1)
    }

    static func elapsedSeconds(currentIndex: Int, wordsPerMinute: Int) -> TimeInterval {
        let clampedIndex = max(currentIndex, 0)
        return Double(clampedIndex) * 60.0 / Double(clampWordsPerMinute(wordsPerMinute))
    }

    static func remainingSeconds(currentIndex: Int, totalWords: Int, wordsPerMinute: Int) -> TimeInterval {
        guard totalWords > 0 else {
            return 0
        }

        let remainingWords = max(totalWords - currentIndex - 1, 0)
        return Double(remainingWords) * 60.0 / Double(clampWordsPerMinute(wordsPerMinute))
    }

    static func clampReaderFontSize(_ value: Double) -> Double {
        min(max(value, 36), 140)
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
    @MainActor
    static func revealApplication() {
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        forceFrontmostAccessibility()
    }

    private static func forceFrontmostAccessibility() {
        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

struct TeleprompterLaunchRequest: Identifiable {
    let id = UUID()
    let text: String
    let wordsPerMinute: Int
}

@MainActor
final class CenterWordSession: ObservableObject {
    @Published private(set) var launchRequest: TeleprompterLaunchRequest?
    @Published var errorMessage: String?

    var openMainWindow: (() -> Void)?
    private let revealCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
    ]

    func presentCapturedText(_ text: String, wordsPerMinute: Int) {
        errorMessage = nil
        launchRequest = TeleprompterLaunchRequest(
            text: text,
            wordsPerMinute: TeleprompterLogic.clampWordsPerMinute(wordsPerMinute)
        )
        revealWindow()
    }

    func presentError(_ message: String) {
        errorMessage = message
        revealWindow()
    }

    func clearError() {
        errorMessage = nil
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
        activateApplication()
        for window in NSApp.windows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.collectionBehavior.formUnion(revealCollectionBehavior)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func activateApplication() {
        CenterWordActivation.revealApplication()
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
        tick: @escaping @MainActor () -> Bool
    ) {
        stop()

        let clampedWordsPerMinute = TeleprompterLogic.clampWordsPerMinute(wordsPerMinute)
        playbackTask = Task {
            if initialDelay > 0 {
                try? await Task.sleep(for: .seconds(initialDelay))
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60.0 / Double(clampedWordsPerMinute)))

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
