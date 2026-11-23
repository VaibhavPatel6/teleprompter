import AppKit
import Carbon.HIToolbox

// MARK: - Settings

enum Settings {
    private static let d = UserDefaults.standard
    static var script: String {
        get { d.string(forKey: "script") ?? defaultScript }
        set { d.set(newValue, forKey: "script") }
    }
    static var wpm: Double {
        get { d.object(forKey: "wpm") as? Double ?? 140 }
        set { d.set(newValue, forKey: "wpm") }
    }
    /// Voice-follow (true) or fixed-pace timed scroll (false).
    static var voiceMode: Bool {
        get { d.object(forKey: "voiceMode") as? Bool ?? true }
        set { d.set(newValue, forKey: "voiceMode") }
    }
    /// See-through: the white background clears so you can see behind the
    /// window, while the script text stays solid.
    static var seeThrough: Bool {
        get { d.bool(forKey: "seeThrough") }
        set { d.set(newValue, forKey: "seeThrough") }
    }
    static var fontSize: CGFloat {
        get { CGFloat(d.object(forKey: "fontSize") as? Double ?? 32) }
        set { d.set(Double(newValue), forKey: "fontSize") }
    }
    static let defaultScript = """
    Welcome to your teleprompter. Paste your script with Edit, then press play.

    In voice mode the words follow you as you speak. Control-Option-Space starts and stops listening from any app. Control-Option-Left goes back one sentence, Control-Option-Right skips ahead one, and Control-Option-R restarts.
    """
}

// MARK: - Panel

/// Floating panel that stays above other apps (and their full-screen spaces)
/// without stealing activation when clicked.
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Controller

@MainActor
final class Prompter: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let minWPM = 60.0, maxWPM = 260.0

    let panel: PrompterPanel
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let controls = NSStackView()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private let editButton = NSButton()
    private let wpmLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private let listeningDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var timedOnlyViews: [NSView] = []
    private let eyeButton = NSButton()
    private var statusItem: NSStatusItem?

    private var pacer: Pacer
    private var follower: VoiceFollower
    private var voiceShown = 0               // words spoken, as currently displayed
    private let listener = SpeechListener()
    private var paintedCount = 0             // words currently painted black
    private var isEditing = false
    private var isPlaying = false
    private var countdownRemaining: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var timer: Timer?
    private var scrollY: CGFloat = 0

    private let ahead = NSColor(white: 0.72, alpha: 1)
    private let read = NSColor.black

    override init() {
        pacer = Pacer(script: Settings.script, wpm: Settings.wpm)
        follower = VoiceFollower(words: pacer.words)
        panel = PrompterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 220),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        configurePanel()
        configureText()
        configureControls()
        configureCountdown()
        configureListeningIndicator()
        configureSeeThroughControls()
        listener.onWords = { [weak self] words, isFinal in self?.heard(words, isFinal: isFinal) }
        listener.onStatus = { [weak self] message in self?.statusLabel.stringValue = message ?? "" }
        enterReadMode(resetPosition: true)
        updateLabels()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: Setup

    private func configurePanel() {
        panel.title = "Teleprompter"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .white
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 120)
        panel.delegate = self
        if !panel.setFrameUsingName("PrompterFrame"), let screen = NSScreen.main {
            let w: CGFloat = 900, h: CGFloat = 220
            panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.visibleFrame.maxY - h, width: w, height: h), display: true)
        }
        panel.setFrameAutosaveName("PrompterFrame")

        let content = HoverView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.onHover = { [weak self] inside in self?.setControlsVisible(inside) }
        panel.contentView = content
    }

    private func configureText() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.automaticallyAdjustsContentInsets = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.textContainerInset = NSSize(width: 24, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        scrollView.documentView = textView

        let content = panel.contentView!
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .darkGray
        return b
    }

    private func configureControls() {
        editButton.target = self
        editButton.action = #selector(toggleEdit)
        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.isBordered = false
        playButton.contentTintColor = .black
        wpmLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        wpmLabel.textColor = .darkGray

        modeControl.segmentCount = 2
        modeControl.setImage(NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice"), forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "timer", accessibilityDescription: "Timed"), forSegment: 1)
        modeControl.setToolTip("Voice: follows your speech", forSegment: 0)
        modeControl.setToolTip("Timed: scrolls at a fixed pace", forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        modeControl.selectedSegment = Settings.voiceMode ? 0 : 1
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        let slowerButton = button("minus", "Slower (⌃⌥↓)", #selector(slower))
        let fasterButton = button("plus", "Faster (⌃⌥↑)", #selector(faster))
        timedOnlyViews = [slowerButton, wpmLabel, fasterButton]

        for v in [
            editButton,
            modeControl,
            button("arrow.counterclockwise", "Restart (⌃⌥R)", #selector(restart)),
            button("backward.end", "Back one sentence (⌃⌥←)", #selector(backSentence)),
            playButton,
            button("forward.end", "Skip ahead one sentence (⌃⌥→)", #selector(forwardSentence)),
            slowerButton,
            wpmLabel,
            fasterButton,
            button("textformat.size.smaller", "Smaller text (⌘−)", #selector(smallerText)),
            button("textformat.size.larger", "Larger text (⌘+)", #selector(largerText)),
        ] as [NSView] { controls.addArrangedSubview(v) }

        controls.orientation = .horizontal
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor(white: 0.96, alpha: 0.97).cgColor
        controls.layer?.cornerRadius = 8
        controls.layer?.borderColor = NSColor(white: 0.85, alpha: 1).cgColor
        controls.layer?.borderWidth = 1
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alphaValue = 0

        let content = panel.contentView!
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    private func configureCountdown() {
        countdownLabel.font = .systemFont(ofSize: 64, weight: .bold)
        countdownLabel.textColor = .black
        countdownLabel.alignment = .center
        countdownLabel.drawsBackground = true
        countdownLabel.backgroundColor = NSColor(white: 1, alpha: 0.9)
        countdownLabel.isHidden = true
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(countdownLabel)
        NSLayoutConstraint.activate([
            countdownLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            countdownLabel.widthAnchor.constraint(equalToConstant: 120),
        ])
    }

    private func configureListeningIndicator() {
        listeningDot.wantsLayer = true
        listeningDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        listeningDot.layer?.cornerRadius = 5
        listeningDot.isHidden = true
        listeningDot.toolTip = "Listening"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .gray
        statusLabel.lineBreakMode = .byTruncatingTail
        for v in [listeningDot, statusLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView!.addSubview(v)
        }
        let content = panel.contentView!
        NSLayoutConstraint.activate([
            listeningDot.widthAnchor.constraint(equalToConstant: 10),
            listeningDot.heightAnchor.constraint(equalToConstant: 10),
            listeningDot.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            listeningDot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: listeningDot.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: listeningDot.leadingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 80),
        ])
    }

    /// Eye button in the window's title bar, plus an icon in the menu bar.
    private func configureSeeThroughControls() {
        eyeButton.isBordered = false
        eyeButton.target = self
        eyeButton.action = #selector(toggleSeeThrough)
        eyeButton.frame = NSRect(x: 2, y: 1, width: 24, height: 20)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        holder.addSubview(eyeButton)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Teleprompter see-through")
        item.button?.target = self
        item.button?.action = #selector(toggleSeeThrough)
        statusItem = item
    }

    @objc func toggleSeeThrough() {
        Settings.seeThrough.toggle()
        applySeeThrough()
    }

    /// Clear the white background (never the text) when see-through is on.
    /// Edit mode always stays solid so typing is readable.
    private func applySeeThrough() {
        let on = Settings.seeThrough
        let clear = on && !isEditing
        panel.isOpaque = !clear
        panel.hasShadow = !clear
        panel.backgroundColor = clear ? .clear : .white
        panel.contentView?.layer?.backgroundColor = (clear ? NSColor(white: 1, alpha: 0.12) : NSColor.white).cgColor
        scrollView.drawsBackground = !clear
        textView.drawsBackground = !clear
        panel.invalidateShadow()

        let tip = on ? "Make solid (⌃⌥T)" : "See-through (⌃⌥T)"
        eyeButton.image = NSImage(systemSymbolName: on ? "eye.fill" : "eye", accessibilityDescription: tip)
        eyeButton.contentTintColor = on ? .controlAccentColor : .darkGray
        eyeButton.toolTip = tip
        statusItem?.button?.contentTintColor = on ? .controlAccentColor : nil
        statusItem?.button?.toolTip = tip
    }

    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            controls.animator().alphaValue = (visible || isEditing) ? 1 : 0
        }
    }

    // MARK: Modes

    private var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineSpacing = Settings.fontSize * 0.25
        return p
    }

    private func enterReadMode(resetPosition: Bool) {
        isEditing = false
        let script = textView.string.isEmpty && resetPosition ? Settings.script : textView.string
        if resetPosition || script != Settings.script || pacer.words.isEmpty {
            Settings.script = script
            loadScript(script)
        }
        textView.isEditable = false
        textView.isSelectable = false
        textView.textStorage?.setAttributedString(NSAttributedString(string: script, attributes: [
            .font: NSFont.systemFont(ofSize: Settings.fontSize, weight: .medium),
            .foregroundColor: ahead,
            .paragraphStyle: paragraphStyle,
        ]))
        paintedCount = 0
        paintProgress()
        updateBottomInset()
        scrollY = targetScrollY()
        applyScroll()
        updateLabels()
        setControlsVisible(false)
        applySeeThrough()
    }

    private func enterEditMode() {
        pause()
        isEditing = true
        textView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black,
        ], range: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.isEditable = true
        textView.isSelectable = true
        scrollView.contentInsets = NSEdgeInsetsZero
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        updateLabels()
        setControlsVisible(true)
        applySeeThrough()
    }

    func textDidChange(_ notification: Notification) {
        Settings.script = textView.string
        loadScript(textView.string)
    }

    private func loadScript(_ script: String) {
        pacer = Pacer(script: script, wpm: Settings.wpm)
        follower = VoiceFollower(words: pacer.words)
        voiceShown = 0
    }

    // MARK: Actions

    @objc func toggleEdit() { isEditing ? enterReadMode(resetPosition: false) : enterEditMode() }

    @objc func togglePlay() {
        if isEditing { enterReadMode(resetPosition: false) }
        if isPlaying { pause(); return }
        statusLabel.stringValue = ""
        if Settings.voiceMode {
            if voiceShown >= pacer.words.count { follower.jump(to: 0); voiceShown = 0 }
            isPlaying = true
            updateLabels()
            Task {
                do {
                    try await listener.start()
                    if !isPlaying { listener.stop() }   // paused while starting up
                } catch {
                    statusLabel.stringValue = error.localizedDescription
                    pause()
                }
            }
            return
        }
        if pacer.isFinished { pacer.restart(); repaintAll() }
        isPlaying = true
        countdownRemaining = 3
        lastTick = CACurrentMediaTime()
        updateLabels()
    }

    private static let debug = ProcessInfo.processInfo.environment["TELEPROMPTER_DEBUG"] != nil

    private func heard(_ words: [String], isFinal: Bool) {
        if Self.debug { FileHandle.standardError.write("\(isFinal ? "FINAL" : "volat") \(words) -> was \(voiceShown)\n".data(using: .utf8)!) }
        guard Settings.voiceMode, isPlaying, !isEditing else { return }
        if isFinal {
            follower.commit(heard: words)
            voiceShown = follower.spokenCount
        } else {
            voiceShown = follower.preview(heard: words)
        }
        if voiceShown >= pacer.words.count { pause() }
    }

    @objc func modeChanged() {
        pause()
        let voice = modeControl.selectedSegment == 0
        guard voice != Settings.voiceMode else { return }
        if voice {
            follower.jump(to: pacer.currentIndex)
            voiceShown = follower.spokenCount
        } else {
            pacer.jump(to: voiceShown)
        }
        Settings.voiceMode = voice
        repaintAll()
        updateLabels()
    }

    func pause() {
        listener.stop()
        isPlaying = false
        countdownRemaining = 0
        countdownLabel.isHidden = true
        updateLabels()
    }

    @objc func restart() {
        if isEditing { enterReadMode(resetPosition: false) }
        if Settings.voiceMode {
            follower.jump(to: 0)
            voiceShown = 0
        } else {
            pacer.restart()
            if isPlaying { countdownRemaining = 3 }
        }
        repaintAll()
    }

    @objc func backSentence() {
        guard !isEditing, !pacer.words.isEmpty else { return }
        if Settings.voiceMode {
            var i = pacer.words.sentenceStart(atOrBefore: min(voiceShown, pacer.words.count - 1))
            if i == voiceShown && i > 0 { i = pacer.words.sentenceStart(atOrBefore: i - 1) }
            follower.jump(to: i)
            voiceShown = i
        } else {
            pacer.backOneSentence()
        }
        repaintAll()
    }

    @objc func forwardSentence() {
        guard !isEditing, !pacer.words.isEmpty else { return }
        if Settings.voiceMode {
            let i = pacer.words.nextSentenceStart(after: min(voiceShown, pacer.words.count - 1)) ?? voiceShown
            follower.jump(to: i)
            voiceShown = i
        } else {
            pacer.forwardOneSentence()
        }
        repaintAll()
    }

    @objc func faster() { setWPM(Settings.wpm + 10) }
    @objc func slower() { setWPM(Settings.wpm - 10) }

    private func setWPM(_ value: Double) {
        Settings.wpm = min(Self.maxWPM, max(Self.minWPM, value))
        pacer.wpm = Settings.wpm
        updateLabels()
    }

    @objc func largerText() { setFontSize(Settings.fontSize + 4) }
    @objc func smallerText() { setFontSize(Settings.fontSize - 4) }

    private func setFontSize(_ size: CGFloat) {
        Settings.fontSize = min(96, max(16, size))
        if !isEditing {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.textStorage?.addAttributes([
                .font: NSFont.systemFont(ofSize: Settings.fontSize, weight: .medium),
                .paragraphStyle: paragraphStyle,
            ], range: full)
            updateBottomInset()
        }
    }

    private func updateLabels() {
        wpmLabel.stringValue = "\(Int(Settings.wpm)) WPM"
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isPlaying ? "Pause" : "Play")
        playButton.toolTip = (isPlaying ? "Pause" : "Play") + " (⌃⌥Space)"
        editButton.title = isEditing ? "Done" : "Edit"
        listeningDot.isHidden = !(isPlaying && Settings.voiceMode)
        timedOnlyViews.forEach { $0.isHidden = Settings.voiceMode }
    }

    // MARK: Rendering

    /// How many words should be black: spoken (voice) or reached (timed).
    private var spokenCount: Int {
        if Settings.voiceMode { return voiceShown }
        return pacer.words.isEmpty ? 0 : pacer.currentIndex + 1
    }

    /// The word whose line is pinned to the top of the window.
    private var pinIndex: Int {
        Settings.voiceMode ? min(voiceShown, max(0, pacer.words.count - 1)) : pacer.currentIndex
    }

    /// Paint spoken words black; everything ahead stays gray.
    private func paintProgress() {
        guard let storage = textView.textStorage, !pacer.words.isEmpty else { return }
        let target = spokenCount
        guard target != paintedCount else { return }
        func end(_ count: Int) -> Int { count == 0 ? 0 : NSMaxRange(pacer.words[count - 1].range) }
        let from = end(min(target, paintedCount)), to = end(max(target, paintedCount))
        storage.addAttribute(.foregroundColor, value: target > paintedCount ? read : ahead,
                             range: NSRange(location: from, length: to - from))
        paintedCount = target
    }

    private func repaintAll() {
        guard !isEditing else { return }
        paintProgress()
    }

    /// Scroll position that puts the current word's line at the top.
    private func targetScrollY() -> CGFloat {
        guard !pacer.words.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        let glyphs = lm.glyphRange(forCharacterRange: pacer.words[pinIndex].range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        return max(0, rect.minY + textView.textContainerOrigin.y - 6)
    }

    /// Room below the text so the last line can still reach the top.
    private func updateBottomInset() {
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: max(0, scrollView.bounds.height - Settings.fontSize * 2), right: 0)
    }

    private func applyScroll() {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func windowDidResize(_ notification: Notification) {
        if !isEditing { updateBottomInset() }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        guard !isEditing else { return }

        if isPlaying && !Settings.voiceMode {
            if countdownRemaining > 0 {
                countdownRemaining -= dt
                countdownLabel.isHidden = countdownRemaining <= 0
                countdownLabel.stringValue = "\(Int(countdownRemaining.rounded(.up)))"
            } else {
                pacer.advance(by: dt)
                if pacer.isFinished { pause() }
            }
        }
        if spokenCount != paintedCount { paintProgress() }

        let target = targetScrollY()
        if abs(target - scrollY) > 0.5 {
            scrollY += (target - scrollY) * CGFloat(min(1, dt * 5))
            applyScroll()
        }
    }

    // MARK: Keys when the panel is focused

    func handleLocalKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            switch e.charactersIgnoringModifiers {
            case "=", "+": largerText(); return true
            case "-": smallerText(); return true
            case "e": toggleEdit(); return true
            default: return false
            }
        }
        guard !isEditing, mods.subtracting([.function, .numericPad]).isEmpty else { return false }
        switch Int(e.keyCode) {
        case kVK_Space: togglePlay()
        case kVK_UpArrow: faster()
        case kVK_DownArrow: slower()
        case kVK_LeftArrow: backSentence()
        case kVK_RightArrow: forwardSentence()
        case kVK_ANSI_R: restart()
        case kVK_ANSI_T: toggleSeeThrough()
        default: return false
        }
        return true
    }
}

/// Content view that reports mouse enter/exit for the hover control strip.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - Global hotkeys (Carbon: no Accessibility permission needed)

@MainActor
final class HotKeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { me.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(_ keyCode: Int, _ action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x54505250), id: id), GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var prompter: Prompter!
    var hotKeys: HotKeys!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        prompter = Prompter()
        prompter.panel.orderFrontRegardless()

        hotKeys = HotKeys()
        hotKeys.register(kVK_Space) { [weak self] in self?.prompter.togglePlay() }
        hotKeys.register(kVK_UpArrow) { [weak self] in self?.prompter.faster() }
        hotKeys.register(kVK_DownArrow) { [weak self] in self?.prompter.slower() }
        hotKeys.register(kVK_LeftArrow) { [weak self] in self?.prompter.backSentence() }
        hotKeys.register(kVK_RightArrow) { [weak self] in self?.prompter.forwardSentence() }
        hotKeys.register(kVK_ANSI_R) { [weak self] in self?.prompter.restart() }
        hotKeys.register(kVK_ANSI_T) { [weak self] in self?.prompter.toggleSeeThrough() }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.prompter.panel else { return e }
            return self.prompter.handleLocalKey(e) ? nil : e
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        prompter.pause()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prompter.panel.orderFrontRegardless()
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Teleprompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

// Diagnostic: print permission state without prompting, then quit.
//   open -W --stdout /dev/stdout /Applications/Teleprompter.app --args --permission-status
if CommandLine.arguments.contains("--permission-status") {
    print(SpeechListener.permissionSummary())
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
