import Foundation
import AVFoundation
import Speech

/// macOS 26 SpeechAnalyzer: 녹음 중 실시간 스트리밍 받아쓰기 (온디바이스, 무료)
/// 녹음이 끝나는 시점에 텍스트가 거의 완성돼 있어서 fn 뗀 뒤 대기 시간이 거의 0.
@available(macOS 26, *)
final class AppleSpeechTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var finalText = ""
    private var volatileText = ""
    private let lock = NSLock()
    private(set) var isRunning = false

    static func locale(for language: String) -> Locale {
        switch language {
        case "en": return Locale(identifier: "en-US")
        default: return Locale(identifier: "ko-KR")
        }
    }

    /// 앱 시작 시 한 번: 언어 모델 에셋 설치 확인 (없으면 다운로드)
    static func prepare(language: String) async -> String? {
        let loc = locale(for: language)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == loc.identifier(.bcp47) }) else {
            return "Apple 받아쓰기: \(loc.identifier) 미지원"
        }
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                FileLog.write("apple-stt: downloading assets for \(loc.identifier)")
                try await req.downloadAndInstall()
            }
            return nil
        } catch {
            return "Apple 받아쓰기 에셋 오류: \(error.localizedDescription)"
        }
    }

    func start(language: String) async throws {
        let loc = Self.locale(for: language)
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let a = SpeechAnalyzer(modules: [t])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw DictoError.claudeFailed("Apple 받아쓰기 오디오 포맷 없음")
        }
        analyzerFormat = fmt
        converter = nil
        lock.lock(); finalText = ""; volatileText = ""; lock.unlock()

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont
        resultsTask = Task { [weak self] in
            for try await result in t.results {
                let text = String(result.text.characters)
                guard let self else { return }
                self.lock.lock()
                if result.isFinal { self.finalText += text; self.volatileText = "" } else { self.volatileText = text }
                self.lock.unlock()
            }
        }
        try await a.start(inputSequence: stream)
        analyzer = a
        transcriber = t
        isRunning = true
    }

    /// 오디오 스레드에서 호출: 입력 버퍼를 analyzer 포맷으로 변환해 전달
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let fmt = analyzerFormat, let continuation else { return }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: fmt) }
        guard let converter else { return }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    /// 입력 종료 후 최종 텍스트
    func stop() async throws -> String {
        guard isRunning else { return "" }
        isRunning = false
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await resultsTask?.value
        analyzer = nil; transcriber = nil
        lock.lock(); defer { lock.unlock() }
        return (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
