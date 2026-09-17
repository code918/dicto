import AVFoundation

/// 마이크 입력을 16kHz mono Float32로 변환해 누적한다. Whisper 입력 포맷.
final class AudioRecorder {
    /// 잠자기/장치 변경 후 꼬인 상태를 피하려고 녹음마다 새 엔진을 만든다
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// 오디오 스레드에서 호출됨. 0...1 정도의 RMS 레벨.
    var onLevel: ((Float) -> Void)?
    /// 오디오 스레드에서 호출됨. 원본 포맷 버퍼 (스트리밍 STT용)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    static let sampleRate: Double = 16_000
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// 백그라운드에서 엔진 시작, timeout 안에 안 되면 실패 처리 (메인 스레드 멈춤 방지)
    func startAsync(timeout: TimeInterval = 3) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            let lockDone = NSLock()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.start() }
                lockDone.lock(); defer { lockDone.unlock() }
                guard !done else { return }
                done = true
                cont.resume(with: result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                lockDone.lock(); defer { lockDone.unlock() }
                guard !done else { return }
                done = true
                cont.resume(throwing: NSError(domain: "Dicto", code: 2, userInfo: [NSLocalizedDescriptionKey: "마이크 시작 시간 초과 (오디오 장치 확인)"]))
            }
        }
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Dicto", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 입력을 열 수 없어요 (권한 확인)"])
        }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        buffersReceived = 0
        try engine.start()
        isRecording = true
        log.info("recording started: \(inFormat.sampleRate)Hz x\(inFormat.channelCount)")
    }

    /// 녹음을 멈추고 누적된 16kHz 샘플을 반환
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        log.info("recording stopped: \(out.count) samples (\(Double(out.count) / AudioRecorder.sampleRate, format: .fixed(precision: 1))s)")
        return out
    }

    private(set) var buffersReceived = 0

    private func process(_ buffer: AVAudioPCMBuffer) {
        buffersReceived += 1
        onBuffer?(buffer)
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let ptr = UnsafeBufferPointer(start: ch[0], count: n)
        var sum: Float = 0
        for v in ptr { sum += v * v }
        let rms = (sum / Float(n)).squareRoot()

        lock.lock(); samples.append(contentsOf: ptr); lock.unlock()
        onLevel?(rms)
    }
}
