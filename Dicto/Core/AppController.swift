import AppKit
import Combine

/// 전체 흐름: fn 탭 → 녹음 → fn 탭 → Whisper → Claude 정제 → 붙여넣기
@MainActor
final class AppController: ObservableObject {
    enum Phase: Equatable { case idle, recording, processing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var modelStatus: String = "모델 로딩 중…"
    @Published private(set) var modelReady = false
    @Published private(set) var lastRaw: String = ""
    @Published private(set) var lastRefined: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var claudePath: String? = ClaudeRefiner.findClaude()
    @Published private(set) var accessibilityOK = false

    let settings = Settings.shared
    let overlay = OverlayState()

    private lazy var panel = OverlayPanel(state: overlay)
    private lazy var copyPopup = CopyPopupPanel()
    private lazy var idlePill = IdlePillPanel()
    private var progressTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private lazy var soundStart: NSSound? = Self.loadSound("record-start")
    private lazy var soundEnd: NSSound? = Self.loadSound("record-end")

    private static func loadSound(_ name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        let s = NSSound(contentsOf: url, byReference: false)
        s?.volume = 0.6
        return s
    }
    private let hotkey = FnKeyMonitor()
    private let recorder = AudioRecorder()
    private var transcriber: WhisperTranscriber?
    private let refiner = ClaudeRefiner()
    private var appleSTT: Any? // AppleSpeechTranscriber (macOS 26)
    @Published private(set) var appleSTTStatus: String?
    private var hideTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    func start() {
        FileLog.write("---- launch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") ----")
        accessibilityOK = TextPaster.isAccessibilityTrusted(prompt: true)
        log.info("accessibility trusted: \(self.accessibilityOK)")
        FileLog.write("accessibility=\(accessibilityOK) claude=\(claudePath ?? "none")")

        Task { _ = await AudioRecorder.requestPermission() }

        recorder.onLevel = { [weak self] rms in
            Task { @MainActor in self?.overlay.pushLevel(rms) }
        }

        hotkey.onTap = { [weak self] in self?.toggle() }
        hotkey.start()

        // 외부(빌드 스크립트)에서 재시작 요청: ~/Library/Application Support/Dicto/.relaunch 파일이 생기면 스스로 재시작
        let relaunchMarker = Settings.appSupportDir.appendingPathComponent(".relaunch")
        try? FileManager.default.removeItem(at: relaunchMarker)
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard FileManager.default.fileExists(atPath: relaunchMarker.path) else { return }
            Task { @MainActor in
                guard let self else { return }
                // 녹음/처리 중이면 끝날 때까지 미룸 (다음 틱에 다시 확인)
                guard self.phase == .idle else { return }
                try? FileManager.default.removeItem(at: relaunchMarker)
                AppDelegate.relaunch()
            }
        }

        updateIdlePill()
        settings.$showIdlePill.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIdlePill() }
        }.store(in: &cancellables)
        // 화면/스페이스가 바뀌면 손잡이 위치 갱신
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateIdlePill() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateIdlePill() }
        }

        loadModel()

        if #available(macOS 26, *) {
            let stt = AppleSpeechTranscriber()
            appleSTT = stt
            recorder.onBuffer = { [weak stt] buf in stt?.append(buf) }
            let lang = settings.language.rawValue
            Task {
                let err = await AppleSpeechTranscriber.prepare(language: lang)
                await MainActor.run { self.appleSTTStatus = err }
                FileLog.write("apple-stt prepare: \(err ?? "ok")")
            }
        }

        // 접근성 권한을 나중에 켰을 때 자동으로 반영
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ok = TextPaster.isAccessibilityTrusted(prompt: false)
                if ok != self.accessibilityOK {
                    self.accessibilityOK = ok
                    if ok { self.hotkey.start() }
                }
            }
        }
    }

    func loadModel() {
        modelReady = false
        modelStatus = "모델 로딩 중…"
        let url = Settings.modelURL
        Task.detached(priority: .userInitiated) { [weak self] in
            let t = WhisperTranscriber(modelURL: url)
            do {
                try t.load()
                await MainActor.run {
                    self?.transcriber = t
                    self?.modelReady = true
                    self?.modelStatus = "Whisper: \(url.lastPathComponent)"
                }
            } catch {
                FileLog.write("loadModel error: \(error.localizedDescription)")
                await MainActor.run {
                    self?.modelStatus = error.localizedDescription
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 토글

    func toggle() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopAndProcess()
        case .processing: break
        }
    }

    private func startRecording() {
        FileLog.write("fn tap -> startRecording (modelReady=\(modelReady))")
        guard modelReady else {
            flash(modelStatus, isError: true)
            return
        }
        copyPopup.hide()
        idlePill.hide()
        overlay.resetLevels()
        overlay.phase = .recording
        phase = .recording
        recordingStartedAt = Date()
        hideTask?.cancel()
        panel.show()
        playSound(soundStart)

        if settings.engine == .apple { AppleRefiner.prewarm(dictionary: Settings.loadVocabulary().promptTerms(limit: 30)) }

        let useAppleSTT = settings.sttEngine == .apple
        let lang = settings.language.rawValue
        Task {
            if useAppleSTT, #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber {
                do { try await stt.start(language: lang) }
                catch { FileLog.write("apple-stt start error: \(error.localizedDescription)") }
            }
            guard phase == .recording else { return }
            do {
                try await recorder.startAsync()
            } catch {
                FileLog.write("recorder start failed: \(error.localizedDescription)")
                phase = .idle
                if #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber { _ = try? await stt.stop() }
                flash(error.localizedDescription, isError: true, duration: 3)
                return
            }
            // 감시: 2.5초 안에 오디오가 안 들어오면 마이크 문제로 간주
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if phase == .recording && recorder.buffersReceived == 0 {
                FileLog.write("no audio buffers after 2.5s -> abort recording")
                _ = recorder.stop()
                phase = .idle
                if #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber { _ = try? await stt.stop() }
                flash("마이크 입력이 없어요 (입력 장치 확인)", isError: true, duration: 3)
            }
        }
    }

    private func stopAndProcess() {
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        FileLog.write("fn tap -> stop, \(String(format: "%.1f", duration))s audio")
        phase = .processing
        playSound(soundEnd)
        let useAppleSTT = settings.sttEngine == .apple

        guard duration >= 0.4 else {
            phase = .idle
            if useAppleSTT, #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber {
                Task { _ = try? await stt.stop() }
            }
            flash("너무 짧아요", isError: true)
            return
        }

        // 무음 감지: 피크가 아주 작으면 Whisper를 돌리지 않음 (무음 환각 방지)
        var peak: Float = 0
        var sumSq: Float = 0
        for v in samples { let a = abs(v); if a > peak { peak = a }; sumSq += v * v }
        let rms = (sumSq / Float(max(1, samples.count))).squareRoot()
        FileLog.write(String(format: "audio peak=%.4f rms=%.4f", peak, rms))
        if peak < 0.02 || rms < 0.002 {
            phase = .idle
            if useAppleSTT, #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber {
                Task { _ = try? await stt.stop() }
            }
            flash("아무 말도 안 들렸어요", isError: true)
            return
        }

        overlay.phase = .processing("받아쓰는 중…")
        panel.refit()
        lastError = nil
        startProgress(expected: settings.engine == .apple ? 1.2 : 5.0)

        let language = settings.language.rawValue
        let refine = settings.refineEnabled
        let model = settings.claudeModel.rawValue
        let engine = settings.engine
        let restore = settings.restoreClipboard
        let vocab = Settings.loadVocabulary()
        // 정제 모델에는 별칭까지 알려줌 ("Supabase (heard as: 수파베이스)"), Whisper 힌트엔 올바른 표기만
        let dictionary = vocab.promptTerms(limit: 80)
        let learn = settings.learnVocabulary

        Task {
            do {
                let t0 = Date()
                var raw = ""
                if useAppleSTT, #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber {
                    do {
                        raw = try await stt.stop()
                        FileLog.write("apple-stt \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(raw)")
                    } catch {
                        FileLog.write("apple-stt error: \(error.localizedDescription)")
                    }
                }
                if raw.isEmpty {
                    guard let transcriber else { throw DictoError.modelLoadFailed }
                    let hint = RefinePrompt.whisperHint(language: language, dictionary: vocab.terms)
                    raw = try await transcriber.transcribe(samples, language: language, hint: hint)
                    FileLog.write("whisper \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(raw)")
                    if RefinePrompt.isHintEcho(raw, hint: hint) {
                        FileLog.write("whisper output is hint echo -> treat as silence")
                        raw = ""
                    }
                }
                // 개인 사전 기준 교정 (별칭 치환 + Supabse → Supabase 같은 한 글자 차이)
                let (fixedRaw, fixes) = vocab.correct(raw)
                if !fixes.isEmpty { FileLog.write("vocab fix: \(fixes.joined(separator: ", "))") }
                raw = fixedRaw
                lastRaw = raw

                guard !raw.isEmpty else {
                    phase = .idle
                    flash("아무 말도 안 들렸어요", isError: true)
                    return
                }

                var final = raw
                var refineFailed = false
                if refine {
                    overlay.phase = .processing(engine == .apple ? "정리 중… (Apple)" : "정리 중… (Claude \(model))")
                    panel.refit()
                    let t0 = Date()
                    do {
                        if engine == .apple {
                            final = try await AppleRefiner.refine(raw, dictionary: dictionary)
                        } else {
                            final = try await refiner.refine(raw, model: model, dictionary: dictionary)
                        }
                        FileLog.write("\(engine.rawValue)(\(model)) \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(final)")
                        if RefinePrompt.looksRewritten(raw: raw, out: final) {
                            FileLog.write("refine output too different (sim=\(String(format: "%.2f", RefinePrompt.similarity(raw: raw, out: final)))) -> using raw")
                            final = raw
                        }
                    } catch where engine == .apple && AppleRefiner.isGuardrailError(error) {
                        // Apple 안전 필터 오탐 → 조용히 원문 사용
                        FileLog.write("apple guardrail false positive -> using raw")
                    } catch {
                        FileLog.write("\(engine.rawValue) error after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(error.localizedDescription)")
                        // 정제 실패 시 원문이라도 붙여넣기
                        log.error("refine failed: \(error.localizedDescription)")
                        lastError = error.localizedDescription
                        refineFailed = true
                        flash("정제 실패 → 원문 붙여넣기 (\(error.localizedDescription))", isError: true, duration: 4)
                    }
                }
                // 정제 모델이 표기를 되돌렸을 수 있으니 한 번 더
                final = vocab.correct(final).0
                lastRefined = final
                appendHistory(raw: raw, refined: final)
                if learn {
                    let promoted = vocab.learn(from: final)
                    if !promoted.isEmpty { FileLog.write("vocab learned: \(promoted.joined(separator: ", "))") }
                }

                let focus = FocusDetector.check()
                switch focus {
                case .notEditable(let desc):
                    // 입력창 포커스 없음 → 붙여넣기 대신 복사 팝업
                    FileLog.write("no text focus (\(desc)) -> copy popup")
                    phase = .idle
                    hideOverlay(after: 0)
                    copyPopup.show(text: final)
                case .editable(let desc):
                    FileLog.write("paste -> \(desc)")
                    TextPaster.paste(final, restoreClipboard: restore)
                    phase = .idle
                    if !refineFailed { hideOverlay(after: 0.15) }
                case .unknown:
                    FileLog.write("focus unknown -> paste anyway")
                    TextPaster.paste(final, restoreClipboard: restore)
                    phase = .idle
                    if !refineFailed { hideOverlay(after: 0.15) }
                }
            } catch {
                FileLog.write("process error: \(error.localizedDescription)")
                phase = .idle
                lastError = error.localizedDescription
                flash(error.localizedDescription, isError: true, duration: 4)
            }
        }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        _ = recorder.stop()
        if #available(macOS 26, *), let stt = appleSTT as? AppleSpeechTranscriber { Task { _ = try? await stt.stop() } }
        phase = .idle
        hideOverlay(after: 0)
    }

    // MARK: - 오버레이 헬퍼

    private func flash(_ text: String, isError: Bool, duration: TimeInterval = 2) {
        idlePill.hide()
        progressTask?.cancel()
        overlay.phase = .message(text, isError: isError)
        panel.show()
        hideOverlay(after: duration)
    }

    private func hideOverlay(after seconds: TimeInterval) {
        hideTask?.cancel()
        finishProgress()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel.hide()
            self?.updateIdlePill()
        }
    }

    private func playSound(_ sound: NSSound?) {
        guard settings.playSounds, let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private func updateIdlePill() {
        if settings.showIdlePill && phase == .idle { idlePill.show() } else { idlePill.hide() }
    }

    /// 처리 중 진행 바: 예상 시간 동안 90%까지 차오르고, 완료 시 100%
    private func startProgress(expected: TimeInterval) {
        progressTask?.cancel()
        overlay.progress = 0
        progressTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let p = 0.9 * (1 - exp(-t / (expected * 0.6)))
                await MainActor.run { self?.overlay.progress = CGFloat(p) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func finishProgress() {
        progressTask?.cancel()
        overlay.progress = 1
    }

    private func appendHistory(raw: String, refined: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)]\nRAW: \(raw)\nOUT: \(refined)\n\n"
        if let h = try? FileHandle(forWritingTo: Settings.historyURL) {
            h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
        } else {
            try? entry.write(to: Settings.historyURL, atomically: true, encoding: .utf8)
        }
    }
}
