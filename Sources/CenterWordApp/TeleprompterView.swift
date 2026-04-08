import SwiftUI

struct TeleprompterView: View {
    @EnvironmentObject private var session: CenterWordSession
    @AppStorage(TeleprompterLogic.defaultWordsPerMinuteKey) private var storedDefaultWordsPerMinute = TeleprompterLogic.fallbackWordsPerMinute
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasPromptedForAccessibility") private var hasPromptedForAccessibility = false
    @AppStorage(TeleprompterLogic.readerFontSizeKey) private var storedReaderFontSize = TeleprompterLogic.defaultReaderFontSize
    @AppStorage(TeleprompterLogic.readerFontStyleKey) private var storedReaderFontStyle = TeleprompterFontStyle.rounded.rawValue
    @AppStorage(TeleprompterLogic.readerFontWeightKey) private var storedReaderFontWeight = TeleprompterFontWeight.bold.rawValue
    @AppStorage(TeleprompterLogic.readerTextColorKey) private var storedReaderTextColor = TeleprompterTextColorChoice.paper.rawValue
    @AppStorage(TeleprompterLogic.readerBackgroundColorKey) private var storedReaderBackgroundColor = TeleprompterBackgroundChoice.charcoal.rawValue
    @AppStorage(TeleprompterLogic.readerAllCapsKey) private var readerAllCaps = false

    @State private var sourceText = ""
    @State private var wordsPerMinute = TeleprompterLogic.fallbackWordsPerMinute
    @State private var wpmText = "\(TeleprompterLogic.fallbackWordsPerMinute)"
    @State private var defaultWPMText = "\(TeleprompterLogic.fallbackWordsPerMinute)"
    @State private var words: [String] = []
    @State private var currentWordIndex = 0
    @State private var isPlaying = false
    @State private var engine = TeleprompterEngine()
    @State private var isPresentationMode = false
    @State private var accessibilityPermissionGranted = SelectedTextCaptureService.accessibilityPermissionGranted()

    private let presentationLeadIn: TimeInterval = 0.35
    private let presentationTrailingHold: TimeInterval = 0.2
    private let seekStepSeconds: TimeInterval = 5

    var body: some View {
        ZStack {
            readerBackgroundChoice.color
                .ignoresSafeArea()

            if isPresentationMode {
                Text(displayedWord)
                    .font(readerFont(size: presentationFontSize))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.25)
                    .foregroundStyle(readerTextColorChoice.color)
                    .padding(48)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current word")
                    .accessibilityValue(displayedWord)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CenterWord")
                            .font(.title.bold())

                        if shouldShowOnboarding {
                            onboardingSection
                        }

                        Text("Paste long text here, then start, pause, resume, or jump around. Cmd+Option+S still opens the stripped-down fast reader.")
                            .foregroundStyle(.secondary)

                        TextEditor(text: $sourceText)
                            .frame(minHeight: 240)
                            .font(.body)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                            .onChange(of: sourceText) {
                                rebuildWords()
                            }

                        controlsSection
                        readerPreviewSection
                        infoStrip

                        Divider()

                        settingsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .onAppear {
            applyStoredDefaultWordsPerMinute()
            refreshAccessibilityPermission()
            maybePromptForAccessibilityPermission()
        }
        .onDisappear {
            engine.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityPermission()
        }
        .onReceive(session.$launchRequest.compactMap { $0 }) { request in
            applyLaunchRequest(request)
        }
        .alert("CenterWord", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) {
                session.clearError()
            }
            Button("Open Accessibility Settings") {
                openAccessibilitySettings()
                session.clearError()
            }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var currentWord: String {
        guard !words.isEmpty else {
            return "Paste text and press Start."
        }

        return words[currentWordIndex]
    }

    private var displayedWord: String {
        readerAllCaps ? currentWord.uppercased() : currentWord
    }

    private var readerFontStyleChoice: TeleprompterFontStyle {
        TeleprompterFontStyle(rawValue: storedReaderFontStyle) ?? .rounded
    }

    private var readerFontWeightChoice: TeleprompterFontWeight {
        TeleprompterFontWeight(rawValue: storedReaderFontWeight) ?? .bold
    }

    private var readerTextColorChoice: TeleprompterTextColorChoice {
        TeleprompterTextColorChoice(rawValue: storedReaderTextColor) ?? .paper
    }

    private var readerBackgroundChoice: TeleprompterBackgroundChoice {
        TeleprompterBackgroundChoice(rawValue: storedReaderBackgroundColor) ?? .charcoal
    }

    private var readerFontSize: Double {
        let clampedSize = TeleprompterLogic.clampReaderFontSize(storedReaderFontSize)
        if clampedSize != storedReaderFontSize {
            storedReaderFontSize = clampedSize
        }
        return clampedSize
    }

    private var presentationFontSize: Double {
        min(readerFontSize * 1.45, 176)
    }

    private var progressLabel: String {
        guard !words.isEmpty else {
            return "0 / 0"
        }

        return "\(currentWordIndex + 1) / \(words.count)"
    }

    private var startButtonTitle: String {
        guard !words.isEmpty else {
            return "Start"
        }

        return isAtEnd ? "Start Over" : (currentWordIndex == 0 ? "Start" : "Resume")
    }

    private var elapsedLabel: String {
        formattedDuration(TeleprompterLogic.elapsedSeconds(currentIndex: currentWordIndex, wordsPerMinute: wordsPerMinute))
    }

    private var remainingLabel: String {
        formattedDuration(
            TeleprompterLogic.remainingSeconds(
                currentIndex: currentWordIndex,
                totalWords: words.count,
                wordsPerMinute: wordsPerMinute
            )
        )
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("WPM")

                TextField("860", text: $wpmText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .onAppear {
                        syncWPMFieldFromState()
                    }
                    .onSubmit {
                        applyWPMTextToState()
                    }

                Button(startButtonTitle) {
                    startPlayback()
                }
                .accessibilityLabel(startButtonTitle)
                .disabled(words.isEmpty || isPlaying)

                Button("Pause") {
                    pausePlayback()
                }
                .accessibilityLabel("Pause")
                .disabled(!isPlaying)

                Button("Restart") {
                    resetPlayback()
                }
                .accessibilityLabel("Restart")
                .disabled(words.isEmpty)

                Spacer()

                Text("\(words.count) words")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Back 5s") {
                    seek(by: -seekStepSeconds)
                }
                .accessibilityLabel("Back 5 seconds")
                .disabled(words.isEmpty)

                Button("Forward 5s") {
                    seek(by: seekStepSeconds)
                }
                .accessibilityLabel("Forward 5 seconds")
                .disabled(words.isEmpty)

                Spacer()

                Text(progressLabel)
                    .foregroundStyle(.secondary)

                Text("\(elapsedLabel) elapsed")
                    .foregroundStyle(.secondary)

                Text("\(remainingLabel) left")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readerPreviewSection: some View {
        Text(displayedWord)
            .font(readerFont(size: readerFontSize))
            .frame(maxWidth: .infinity, minHeight: max(220, readerFontSize * 2.6))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.3)
            .padding(24)
            .foregroundStyle(readerTextColorChoice.color)
            .background(Color.white.opacity(0.04))
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current word")
            .accessibilityValue(displayedWord)
    }

    private var shouldShowOnboarding: Bool {
        !hasCompletedOnboarding || !accessibilityPermissionGranted
    }

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.headline)

            Text("To use Cmd+Option+S anywhere, CenterWord needs Accessibility access. macOS requires you to approve that yourself, but the buttons below take you straight to it.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label(
                    accessibilityPermissionGranted ? "Accessibility granted" : "Accessibility not granted yet",
                    systemImage: accessibilityPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(accessibilityPermissionGranted ? .green : .yellow)

                Spacer()

                Text(Bundle.main.bundleURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
                Button("Prompt for Access") {
                    hasPromptedForAccessibility = true
                    SelectedTextCaptureService.promptForAccessibilityPermission()
                    refreshAccessibilityPermission()
                }

                Button("Open Accessibility Settings") {
                    openAccessibilitySettings()
                }

                Button("Reveal App in Finder") {
                    revealAppInFinder()
                }

                Button(accessibilityPermissionGranted ? "Finish Setup" : "Check Again") {
                    refreshAccessibilityPermission()
                    if accessibilityPermissionGranted {
                        hasCompletedOnboarding = true
                    }
                }
            }

            Text("Install flow: open CenterWord once, click Prompt for Access, enable CenterWord in Accessibility, then come back and click Finish Setup.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.06))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var infoStrip: some View {
        HStack(spacing: 16) {
            Text("Back/forward uses the current WPM to estimate a 5-second jump.")
                .foregroundStyle(.secondary)

            Spacer()

            Text(playbackStatusLabel)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var playbackStatusLabel: String {
        if words.isEmpty {
            return "Ready"
        }

        if isAtEnd && !isPlaying {
            return "Finished"
        }

        return isPlaying ? "Playing" : "Paused"
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text("Reader style")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Picker("Font", selection: $storedReaderFontStyle) {
                        ForEach(TeleprompterFontStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Weight", selection: $storedReaderFontWeight) {
                        ForEach(TeleprompterFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(
                        "Size \(Int(readerFontSize))",
                        value: $storedReaderFontSize,
                        in: 36...140,
                        step: 4
                    )

                    Toggle("ALL CAPS", isOn: $readerAllCaps)
                        .toggleStyle(.switch)
                }

                HStack(spacing: 12) {
                    Picker("Text", selection: $storedReaderTextColor) {
                        ForEach(TeleprompterTextColorChoice.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Background", selection: $storedReaderBackgroundColor) {
                        ForEach(TeleprompterBackgroundChoice.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Text("Preview updates live")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Hotkey default")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    TextField("860", text: $defaultWPMText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .onSubmit {
                            applyDefaultWPMText()
                        }

                    Text("WPM")
                        .foregroundStyle(.secondary)

                    Button("Save Default") {
                        applyDefaultWPMText()
                    }
                    .accessibilityLabel("Save default speed")
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("Current default: \(TeleprompterLogic.clampWordsPerMinute(storedDefaultWordsPerMinute))")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func applyStoredDefaultWordsPerMinute() {
        let clampedDefault = TeleprompterLogic.clampWordsPerMinute(storedDefaultWordsPerMinute)
        storedDefaultWordsPerMinute = clampedDefault
        wordsPerMinute = clampedDefault
        syncWPMFieldFromState()
        defaultWPMText = "\(clampedDefault)"
    }

    private func applyDefaultWPMText() {
        if let parsed = TeleprompterLogic.parseWordsPerMinute(from: defaultWPMText) {
            storedDefaultWordsPerMinute = parsed
        }

        let clampedDefault = TeleprompterLogic.clampWordsPerMinute(storedDefaultWordsPerMinute)
        storedDefaultWordsPerMinute = clampedDefault
        defaultWPMText = "\(clampedDefault)"
    }

    private func syncWPMFieldFromState() {
        wpmText = "\(wordsPerMinute)"
    }

    private func applyWPMTextToState() {
        let previousWordsPerMinute = wordsPerMinute

        if let parsed = TeleprompterLogic.parseWordsPerMinute(from: wpmText) {
            wordsPerMinute = parsed
        }

        syncWPMFieldFromState()

        guard isPlaying, previousWordsPerMinute != wordsPerMinute else {
            return
        }

        engine.start(wordsPerMinute: wordsPerMinute) {
            advanceWord()
        }
    }

    private func rebuildWords() {
        let updatedWords = TeleprompterText.words(in: sourceText)
        words = updatedWords

        if updatedWords.isEmpty {
            currentWordIndex = 0
            pausePlayback()
            return
        }

        currentWordIndex = min(currentWordIndex, updatedWords.count - 1)
    }

    private func startPlayback() {
        applyWPMTextToState()

        guard !words.isEmpty else {
            return
        }

        if isAtEnd {
            currentWordIndex = 0
        }

        isPlaying = true
        engine.start(
            wordsPerMinute: wordsPerMinute,
            initialDelay: isPresentationMode ? presentationLeadIn : 0
        ) {
            advanceWord()
        }
    }

    private func pausePlayback() {
        engine.stop()
        isPlaying = false
    }

    private func resetPlayback() {
        pausePlayback()
        currentWordIndex = 0
    }

    private func seek(by seconds: TimeInterval) {
        applyWPMTextToState()

        guard !words.isEmpty else {
            return
        }

        let shouldResume = isPlaying
        if shouldResume {
            pausePlayback()
        }

        currentWordIndex = TeleprompterLogic.seekIndex(
            currentIndex: currentWordIndex,
            bySeconds: seconds,
            wordsPerMinute: wordsPerMinute,
            totalWords: words.count
        )

        if shouldResume {
            startPlayback()
        }
    }

    private func advanceWord() -> Bool {
        guard !words.isEmpty else {
            finishPresentationIfNeeded()
            return false
        }

        let nextIndex = currentWordIndex + 1
        guard nextIndex < words.count else {
            finishPresentationIfNeeded()
            return false
        }

        currentWordIndex = nextIndex
        return true
    }

    private func applyLaunchRequest(_ request: TeleprompterLaunchRequest) {
        sourceText = request.text
        wordsPerMinute = request.wordsPerMinute
        syncWPMFieldFromState()
        rebuildWords()
        currentWordIndex = 0
        isPresentationMode = true
        centerPresentationWindow()
        startPlayback()
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    session.clearError()
                }
            }
        )
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func centerPresentationWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            return
        }

        let targetSize = NSSize(width: 820, height: 420)
        window.collectionBehavior.formUnion([
            .moveToActiveSpace,
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ])
        window.level = .screenSaver
        window.setContentSize(targetSize)
        window.center()
        revealPresentationWindow(window)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            revealPresentationWindow(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            revealPresentationWindow(window)
        }
    }

    private func finishPresentationIfNeeded() {
        pausePlayback()

        guard isPresentationMode else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + presentationTrailingHold) {
            isPresentationMode = false
            hidePresentationWindow()
        }
    }

    private func hidePresentationWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            return
        }

        window.level = .normal
        window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle])
        window.orderOut(nil)
    }

    private func revealPresentationWindow(_ window: NSWindow) {
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.order(.above, relativeTo: 0)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func readerFont(size: Double) -> Font {
        .system(
            size: size,
            weight: readerFontWeightChoice.fontWeight,
            design: readerFontStyleChoice.design
        )
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var isAtEnd: Bool {
        !words.isEmpty && currentWordIndex >= words.count - 1
    }

    private func refreshAccessibilityPermission() {
        accessibilityPermissionGranted = SelectedTextCaptureService.accessibilityPermissionGranted()
    }

    private func maybePromptForAccessibilityPermission() {
        guard !hasPromptedForAccessibility, !accessibilityPermissionGranted else {
            return
        }

        hasPromptedForAccessibility = true
        SelectedTextCaptureService.promptForAccessibilityPermission()
    }
}
