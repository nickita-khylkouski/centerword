import SwiftUI

struct TeleprompterView: View {
    @EnvironmentObject private var session: CenterWordSession
    @AppStorage(TeleprompterLogic.defaultWordsPerMinuteKey) private var storedDefaultWordsPerMinute = TeleprompterLogic.fallbackWordsPerMinute
    @AppStorage(TeleprompterLogic.onboardingCompletedKey) private var hasCompletedOnboarding = false
    @AppStorage("hasPromptedForShortcutAccess") private var hasPromptedForShortcutAccess = false
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
    @State private var permissionSnapshot = SelectedTextCaptureService.permissionSnapshot()

    private let seekStepSeconds: TimeInterval = 5

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if shouldPresentSetupScreen {
                setupScreen
            } else {
                dashboardScreen
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .onAppear {
            applyStoredDefaultWordsPerMinute()
            refreshPermissions()
            syncOnboardingStateWithPermission()
            maybePromptForPermissions()
        }
        .onDisappear {
            engine.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            syncOnboardingStateWithPermission()
        }
        .onReceive(session.$launchRequest.compactMap { $0 }) { request in
            applyLaunchRequest(request)
            session.consumeLaunchRequest()
        }
        .alert("CenterWord", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) {
                session.clearError()
            }
            Button("Open Input Monitoring Settings") {
                openInputMonitoringSettings()
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

    private var shouldPresentSetupScreen: Bool {
        TeleprompterLogic.shouldPresentSetupScreen(
            hasCompletedOnboarding: hasCompletedOnboarding,
            permissionSnapshot: permissionSnapshot,
            hotKeyStatus: session.hotKeyRegistrationStatus
        )
    }

    private var shouldShowAccessibilityWarning: Bool {
        TeleprompterLogic.shouldShowPermissionWarning(
            hasCompletedOnboarding: hasCompletedOnboarding,
            permissionSnapshot: permissionSnapshot,
            hotKeyStatus: session.hotKeyRegistrationStatus
        )
    }

    private var capabilityReady: Bool {
        permissionSnapshot.clipboardWorkflowReady && session.hotKeyRegistrationStatus.isRegistered
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
        formattedDuration(
            TeleprompterLogic.elapsedSeconds(
                currentIndex: currentWordIndex,
                tokens: words,
                wordsPerMinute: wordsPerMinute
            )
        )
    }

    private var remainingLabel: String {
        formattedDuration(
            TeleprompterLogic.remainingSeconds(
                currentIndex: currentWordIndex,
                tokens: words,
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

    private var dashboardScreen: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("CenterWord")
                    .font(.title.bold())

                Text("Paste long text here, then start, pause, resume, or jump around. Cmd+Option+S still opens the stripped-down fast reader.")
                    .foregroundStyle(.secondary)

                if shouldShowAccessibilityWarning {
                    accessibilityWarningSection
                }

                if let hotKeyStatusMessage = session.hotKeyStatusMessage {
                    Text(hotKeyStatusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

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
            .frame(maxWidth: 960, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var readerPreviewSection: some View {
        Text(displayedWord)
            .font(readerFont(size: readerFontSize))
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.3)
            .padding(24)
            .foregroundStyle(Color(nsColor: .labelColor))
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current word")
            .accessibilityValue(displayedWord)
    }

    private var setupScreen: some View {
        ScrollView(.vertical) {
            VStack {
                onboardingSection
                    .frame(maxWidth: 680)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onboardingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.title.bold())

            Text("Do this once, then CenterWord becomes a one-keystroke clipboard reader.")
                .foregroundStyle(.secondary)

            Text("CenterWord is clipboard-first now. Copy text anywhere, hit Cmd+Option+S, and the popup teleprompter comes to the front. The only required permission is Input Monitoring so the global shortcut can fire while another app is focused.")
                .foregroundStyle(.secondary)

            permissionStatusRow(
                title: "Global shortcut",
                granted: permissionSnapshot.listenEvent && session.hotKeyRegistrationStatus.isRegistered,
                detail: permissionSnapshot.listenEvent ? session.hotKeyRegistrationStatus.message : "Input Monitoring is required to detect Cmd+Option+S while CenterWord is in the background."
            )

            Text(Bundle.main.bundleURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                Button("Prompt for Shortcut Access") {
                    SelectedTextCaptureService.requestListenEventPermission()
                    refreshPermissions()
                }

                Button("Open Input Monitoring Settings") {
                    openInputMonitoringSettings()
                }

                Button("Reveal App in Finder") {
                    revealAppInFinder()
                }

                Button(capabilityReady ? "Finish Setup" : "Check Again") {
                    refreshPermissions()
                    if capabilityReady {
                        hasCompletedOnboarding = true
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("Install flow: grant Input Monitoring, verify the shortcut row says ready, then click Finish Setup. After that, your daily flow is copy text and hit Cmd+Option+S.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 12))
    }

    private var accessibilityWarningSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hotkey capture permissions are incomplete")
                    .font(.headline)

                Text("The main reader still works, but the clipboard popup still needs Input Monitoring permission so Cmd+Option+S can fire globally.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Input Monitoring Settings") {
                openInputMonitoringSettings()
            }

            Button("Reveal App in Finder") {
                revealAppInFinder()
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
        )
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
                    .frame(width: 170, alignment: .leading)

                    Picker("Weight", selection: $storedReaderFontWeight) {
                        ForEach(TeleprompterFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170, alignment: .leading)

                    HStack(spacing: 10) {
                        Text("Size")
                            .foregroundStyle(.secondary)

                        Text("\(Int(readerFontSize))")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)

                        Stepper(
                            "",
                            value: $storedReaderFontSize,
                            in: 36...140,
                            step: 4
                        )
                        .labelsHidden()
                        .fixedSize()
                    }
                    .frame(width: 120, alignment: .leading)

                    Toggle("ALL CAPS", isOn: $readerAllCaps)
                        .toggleStyle(.switch)

                    Spacer()
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
                Text("Shortcut")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(
                        permissionSnapshot.listenEvent && session.hotKeyRegistrationStatus.isRegistered ? "Shortcut ready" : "Shortcut unavailable",
                        systemImage: permissionSnapshot.listenEvent && session.hotKeyRegistrationStatus.isRegistered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(permissionSnapshot.listenEvent && session.hotKeyRegistrationStatus.isRegistered ? .green : .yellow)

                    Button("Check Again") {
                        refreshPermissions()
                        syncOnboardingStateWithPermission()
                    }

                    Button("Open Input Monitoring Settings") {
                        openInputMonitoringSettings()
                    }

                    Spacer()

                    Text("Cmd+Option+S reads the current clipboard. Accessibility is not required for the shipped flow.")
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

        engine.start(
            wordsPerMinute: wordsPerMinute,
            intervalProvider: currentTokenInterval
        ) {
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
            intervalProvider: currentTokenInterval
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
            tokens: words
        )

        if shouldResume {
            startPlayback()
        }
    }

    private func advanceWord() -> Bool {
        guard !words.isEmpty else {
            return false
        }

        let nextIndex = currentWordIndex + 1
        guard nextIndex < words.count else {
            pausePlayback()
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

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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

    private func currentTokenInterval() -> TimeInterval {
        guard !words.isEmpty else {
            return TeleprompterLogic.secondsPerUnit(wordsPerMinute: wordsPerMinute)
        }

        return TeleprompterLogic.displayDuration(
            for: words[currentWordIndex],
            wordsPerMinute: wordsPerMinute
        )
    }

    private func refreshPermissions() {
        permissionSnapshot = SelectedTextCaptureService.permissionSnapshot()
    }

    private func maybePromptForPermissions() {
        guard shouldPresentSetupScreen, !hasPromptedForShortcutAccess, !capabilityReady else {
            return
        }

        hasPromptedForShortcutAccess = true
        SelectedTextCaptureService.requestListenEventPermission()
        refreshPermissions()
    }

    private func syncOnboardingStateWithPermission() {
        if capabilityReady {
            hasCompletedOnboarding = true
        }
    }

    @ViewBuilder
    private func permissionStatusRow(title: String, granted: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                granted ? "\(title) granted" : "\(title) not granted",
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(granted ? .green : .yellow)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
