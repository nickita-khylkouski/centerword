import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

enum SelectedTextCaptureError: LocalizedError {
    case copyPermissionRequired
    case accessibilityPermissionRequired
    case noSelectedTextFound

    var errorDescription: String? {
        switch self {
        case .copyPermissionRequired:
            return "CenterWord needs permission to send Cmd+C before it can run the legacy selected-text flow."
        case .accessibilityPermissionRequired:
            return "CenterWord needs Accessibility permission for the legacy selected-text fallback."
        case .noSelectedTextFound:
            return "No readable selected text was found."
        }
    }
}

actor SelectedTextCaptureService {
    private struct PasteboardBackup {
        let items: [[(NSPasteboard.PasteboardType, Data)]]
    }

    private struct PasteboardSnapshot {
        let changeCount: Int
        let text: String?
    }

    private let modifierReleasePollNanoseconds: UInt64 = 40_000_000
    private let modifierReleaseTimeoutNanoseconds: UInt64 = 1_400_000_000
    private let preCopyDelayNanoseconds: UInt64 = 1_000_000_000
    private let copyKeyEventStepMicroseconds: useconds_t = 18_000
    private let copyPollIntervalsNanoseconds: [UInt64] = [
        80_000_000,
        120_000_000,
        160_000_000,
        220_000_000,
        320_000_000,
        420_000_000,
    ]
    private let stabilizationDelayNanoseconds: UInt64 = 120_000_000
    private static let copyMenuTitle = "Copy"
    private static let editMenuTitle = "Edit"

    static func permissionSnapshot() -> CenterWordPermissionSnapshot {
        CenterWordPermissionSnapshot(
            accessibility: accessibilityPermissionGranted(),
            listenEvent: listenEventPermissionGranted(),
            postEvent: postEventPermissionGranted()
        )
    }

    static func accessibilityPermissionGranted() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": false,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func listenEventPermissionGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func postEventPermissionGranted() -> Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    static func requestListenEventPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    @discardableResult
    static func requestPostEventPermission() -> Bool {
        CGRequestPostEventAccess()
    }

    @discardableResult
    static func promptForAccessibilityPermission() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func captureSelectedText(promptIfNeeded: Bool) async -> Result<String, SelectedTextCaptureError> {
        if promptIfNeeded {
            _ = Self.requestPostEventPermission()
        }

        let accessibilityGranted = ensureAccessibilityPermission(promptIfNeeded: promptIfNeeded)
        let postPermissionGranted = Self.postEventPermissionGranted()
        let frontmostBundle = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown" }
        CenterWordDiagnostics.record("capture_begin bundle=\(frontmostBundle) post=\(postPermissionGranted) ax=\(accessibilityGranted)")

        if accessibilityGranted,
           let accessibilityText = selectedTextFromAccessibility(),
           !accessibilityText.isEmpty {
            CenterWordDiagnostics.record("capture_ax_success chars=\(accessibilityText.count)")
            return .success(accessibilityText)
        }

        if let copiedText = await selectedTextFromCopyStrategy(
            postPermissionGranted: postPermissionGranted,
            accessibilityGranted: accessibilityGranted
        ), !copiedText.isEmpty {
            CenterWordDiagnostics.record("capture_copy_success chars=\(copiedText.count)")
            return .success(copiedText)
        }

        if !postPermissionGranted && !accessibilityGranted {
            CenterWordDiagnostics.record("capture_fail missing_copy_and_ax")
            return .failure(.copyPermissionRequired)
        }

        if !postPermissionGranted {
            CenterWordDiagnostics.record("capture_fail missing_copy")
            return .failure(.copyPermissionRequired)
        }

        if !accessibilityGranted {
            CenterWordDiagnostics.record("capture_fail missing_ax")
            return .failure(.accessibilityPermissionRequired)
        }

        CenterWordDiagnostics.record("capture_fail no_selected_text")
        return .failure(.noSelectedTextFound)
    }

    private func ensureAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": promptIfNeeded,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func selectedTextFromCopyStrategy(
        postPermissionGranted: Bool,
        accessibilityGranted: Bool
    ) async -> String? {
        let originalBackup = await MainActor.run { snapshotPasteboard() }
        let originalChangeCount = await MainActor.run { NSPasteboard.general.changeCount }

        if postPermissionGranted {
            await waitForModifiersToRelease()
            CenterWordDiagnostics.record("capture_copy modifiers_released")
            try? await Task.sleep(nanoseconds: preCopyDelayNanoseconds)
            CenterWordDiagnostics.record("capture_copy pre_copy_delay_complete")
            postCommandC()
            CenterWordDiagnostics.record("capture_copy command_c_posted")

            var copiedText = await waitForCopiedText(originalChangeCount: originalChangeCount)
            if copiedText == nil {
                CenterWordDiagnostics.record("capture_copy first_attempt_empty retrying")
                postCommandC()
                CenterWordDiagnostics.record("capture_copy command_c_reposted")
                copiedText = await waitForCopiedText(originalChangeCount: originalChangeCount)
            }

            if let copiedText {
                await MainActor.run { restorePasteboard(originalBackup) }
                CenterWordDiagnostics.record("capture_copy pasteboard_restored")
                return copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if accessibilityGranted {
            CenterWordDiagnostics.record("capture_copy trying_menu_copy")
            let menuCopyPressed = await MainActor.run { pressMenuCopyOnFrontmostApp() }
            if menuCopyPressed {
                CenterWordDiagnostics.record("capture_copy menu_copy_pressed")
                if let menuCopiedText = await waitForCopiedText(originalChangeCount: originalChangeCount) {
                    await MainActor.run { restorePasteboard(originalBackup) }
                    CenterWordDiagnostics.record("capture_copy pasteboard_restored")
                    return menuCopiedText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                CenterWordDiagnostics.record("capture_copy menu_copy_empty")
            } else {
                CenterWordDiagnostics.record("capture_copy menu_copy_unavailable")
            }
        }

        await MainActor.run { restorePasteboard(originalBackup) }
        CenterWordDiagnostics.record("capture_copy pasteboard_restored")
        return nil
    }

    private func waitForModifiersToRelease() async {
        var elapsed: UInt64 = 0
        while modifierKeysArePressed(), elapsed < modifierReleaseTimeoutNanoseconds {
            try? await Task.sleep(nanoseconds: modifierReleasePollNanoseconds)
            elapsed += modifierReleasePollNanoseconds
        }
    }

    private func modifierKeysArePressed() -> Bool {
        let modifierKeys: [CGKeyCode] = [
            CGKeyCode(kVK_Command),
            CGKeyCode(kVK_RightCommand),
            CGKeyCode(kVK_Option),
            CGKeyCode(kVK_RightOption),
        ]

        return modifierKeys.contains { keyCode in
            CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
    }

    private func waitForCopiedText(originalChangeCount: Int) async -> String? {
        for interval in copyPollIntervalsNanoseconds {
            try? await Task.sleep(nanoseconds: interval)
            let snapshot = await MainActor.run { readPasteboardSnapshot() }

            guard snapshot.changeCount != originalChangeCount else {
                continue
            }

            if let text = snapshot.text, !text.isEmpty {
                CenterWordDiagnostics.record("capture_copy pasteboard_changed chars=\(text.count)")
                try? await Task.sleep(nanoseconds: stabilizationDelayNanoseconds)
                let stabilizedSnapshot = await MainActor.run { readPasteboardSnapshot() }

                if stabilizedSnapshot.changeCount == snapshot.changeCount,
                   let stabilizedText = stabilizedSnapshot.text,
                   !stabilizedText.isEmpty {
                    return stabilizedText
                }

                return text
            }
        }

        return nil
    }

    @MainActor
    private func snapshotPasteboard() -> PasteboardBackup {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }
        } ?? []

        return PasteboardBackup(items: items)
    }

    @MainActor
    private func readPasteboardSnapshot() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        return PasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            text: readText(from: pasteboard)
        )
    }

    @MainActor
    private func restorePasteboard(_ backup: PasteboardBackup) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !backup.items.isEmpty else {
            return
        }

        let items = backup.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    @MainActor
    private func readText(from pasteboard: NSPasteboard) -> String? {
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           let first = strings.first {
            let text = String(first)
            if !text.isEmpty {
                return text
            }
        }

        let plainTextTypes: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
        ]

        for type in plainTextTypes {
            if let value = pasteboard.string(forType: type), !value.isEmpty {
                return value
            }

            if let data = pasteboard.data(forType: type) {
                if let utf8String = String(data: data, encoding: .utf8), !utf8String.isEmpty {
                    return utf8String
                }
                if let utf16String = String(data: data, encoding: .utf16), !utf16String.isEmpty {
                    return utf16String
                }
            }
        }

        return nil
    }

    @MainActor
    private func pressMenuCopyOnFrontmostApp() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        guard let menuBar = copyElementAttribute(kAXMenuBarAttribute as CFString, from: applicationElement),
              let editItem = findMenuItem(
                matchingAnyTitle: [Self.editMenuTitle],
                in: menuBar,
                maxDepth: 6
              ),
              AXUIElementPerformAction(editItem, kAXPressAction as CFString) == .success else {
            return false
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.12))

        guard let copyItem = findMenuItem(
                matchingAnyTitle: [Self.copyMenuTitle],
                in: menuBar,
                maxDepth: 12
              ) ?? findMenuItem(
                matchingAnyTitle: [Self.copyMenuTitle],
                in: applicationElement,
                maxDepth: 12
              ) else {
            return false
        }

        return AXUIElementPerformAction(copyItem, kAXPressAction as CFString) == .success
    }

    private func selectedTextFromAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedElement = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide) else {
            return nil
        }

        var currentElement: AXUIElement? = focusedElement
        var inspectedDepth = 0

        while let element = currentElement, inspectedDepth < 8 {
            if let text = copyStringAttribute(kAXSelectedTextAttribute as CFString, from: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }

            currentElement = copyElementAttribute(kAXParentAttribute as CFString, from: element)
            inspectedDepth += 1
        }

        return nil
    }

    private func postCommandC() {
        guard let commandDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return
        }

        commandDown.flags = .maskCommand
        cDown.flags = .maskCommand
        cUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        usleep(copyKeyEventStepMicroseconds)
        cDown.post(tap: .cghidEventTap)
        usleep(copyKeyEventStepMicroseconds)
        cUp.post(tap: .cghidEventTap)
        usleep(copyKeyEventStepMicroseconds)
        commandUp.post(tap: .cghidEventTap)
    }

    nonisolated private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }

        return (rawValue as! AXUIElement)
    }

    nonisolated private func copyElementsAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success,
              let rawValue,
              let array = rawValue as? [AXUIElement] else {
            return []
        }

        return array
    }

    nonisolated private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard status == .success, let rawValue else {
            return nil
        }

        return rawValue as? String
    }

    nonisolated private func findMenuItem(
        matchingAnyTitle titles: [String],
        in root: AXUIElement,
        maxDepth: Int
    ) -> AXUIElement? {
        let loweredTitles = Set(titles.map { $0.lowercased() })
        var visited = Set<CFHashCode>()

        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth <= maxDepth else {
                return nil
            }

            let identifier = CFHash(element)
            guard visited.insert(identifier).inserted else {
                return nil
            }

            if let title = copyStringAttribute(kAXTitleAttribute as CFString, from: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               loweredTitles.contains(title) {
                return element
            }

            let childAttributes: [CFString] = [
                kAXChildrenAttribute as CFString,
                kAXMenuBarAttribute as CFString,
                kAXVisibleChildrenAttribute as CFString,
            ]

            for attribute in childAttributes {
                for child in copyElementsAttribute(attribute, from: element) {
                    if let match = search(child, depth: depth + 1) {
                        return match
                    }
                }
            }

            return nil
        }

        return search(root, depth: 0)
    }
}
