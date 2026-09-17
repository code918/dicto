import Foundation

/// whisper.cpp (Homebrew libwhisper) 인프로세스 래퍼
final class WhisperTranscriber {
    private var ctx: OpaquePointer?
    let modelURL: URL
    private let queue = DispatchQueue(label: "com.lake514.dicto.whisper", qos: .userInitiated)

    var isLoaded: Bool { ctx != nil }

    init(modelURL: URL) {
        self.modelURL = modelURL
        // whisper 내부 로그 끄기
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw DictoError.modelMissing(modelURL)
        }
        // ggml 백엔드(Metal/CPU)는 동적 로드 - 이거 없으면 whisper_init에서 abort
        FileLog.write("load: backends before=\(ggml_backend_reg_count())")
        ggml_backend_load_all()
        if ggml_backend_reg_count() == 0 {
            // Homebrew ggml 백엔드 디렉토리를 직접 지정 (빌트인 경로가 안 맞을 때)
            ggml_backend_load_all_from_path("/opt/homebrew/opt/ggml/libexec")
        }
        var names: [String] = []
        for i in 0..<ggml_backend_reg_count() {
            if let r = ggml_backend_reg_get(i), let n = ggml_backend_reg_name(r) { names.append(String(cString: n)) }
        }
        FileLog.write("load: backends after=\(ggml_backend_reg_count()) \(names)")
        log.info("ggml backends loaded: \(ggml_backend_reg_count())")
        guard ggml_backend_reg_count() > 0 else {
            FileLog.write("load: NO ggml backends found -> abort avoided")
            throw DictoError.modelLoadFailed
        }

        // GPU 초기화 중 크래시하면 다음 실행에서 CPU로 자동 전환 (마커 파일)
        let gpuMarker = Settings.appSupportDir.appendingPathComponent(".gpu-loading")
        let gpuCrashedBefore = FileManager.default.fileExists(atPath: gpuMarker.path)
        var params = whisper_context_default_params()
        params.use_gpu = !gpuCrashedBefore
        params.flash_attn = params.use_gpu
        FileLog.write("load: use_gpu=\(params.use_gpu) (marker=\(gpuCrashedBefore)) model=\(modelURL.lastPathComponent)")
        let start = Date()
        if params.use_gpu { FileManager.default.createFile(atPath: gpuMarker.path, contents: nil) }
        var c = whisper_init_from_file_with_params(modelURL.path, params)
        try? FileManager.default.removeItem(at: gpuMarker)
        if c == nil && params.use_gpu {
            FileLog.write("load: GPU init returned nil, retrying CPU")
            params.use_gpu = false
            params.flash_attn = false
            c = whisper_init_from_file_with_params(modelURL.path, params)
        }
        guard let c else { FileLog.write("load: FAILED"); throw DictoError.modelLoadFailed }
        ctx = c
        FileLog.write("load: OK in \(String(format: "%.2f", Date().timeIntervalSince(start)))s gpu=\(params.use_gpu)")
        log.info("whisper model loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
    }

    /// 16kHz mono Float32 샘플 → 텍스트
    func transcribe(_ input: [Float], language: String, hint: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.transcribeSync(input, language: language, hint: hint)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func transcribeSync(_ input: [Float], language: String, hint: String?) throws -> String {
        guard let ctx else { throw DictoError.modelLoadFailed }

        // whisper는 최소 1초 이상 필요 → 짧으면 무음 패딩
        var samples = input
        let minSamples = Int(AudioRecorder.sampleRate * 1.2)
        if samples.count < minSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minSamples - samples.count))
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.translate = false
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = 0.2
        params.no_speech_thold = 0.6
        params.detect_language = false

        let langC = strdup(language)
        defer { free(langC) }
        params.language = UnsafePointer(langC)

        var hintC: UnsafeMutablePointer<CChar>? = nil
        if let hint, !hint.isEmpty { hintC = strdup(hint) }
        defer { if let hintC { free(hintC) } }
        params.initial_prompt = UnsafePointer(hintC)

        let start = Date()
        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { throw DictoError.transcribeFailed(rc) }

        let n = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<n {
            if let s = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: s)
            }
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("whisper: \(n) segments in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s: \(result, privacy: .private)")
        return result
    }
}
