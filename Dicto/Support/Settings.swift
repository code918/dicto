import Foundation
import os

let log = Logger(subsystem: "com.lake514.dicto", category: "app")

/// 파일 로그 (~/Library/Application Support/Dicto/dicto.log) - 콘솔 못 볼 때 디버깅용
enum FileLog {
    static let url = Settings.appSupportDir.appendingPathComponent("dicto.log")
    private static let q = DispatchQueue(label: "com.lake514.dicto.filelog")
    static func write(_ msg: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        q.sync {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

enum DictoError: LocalizedError {
    case modelMissing(URL)
    case modelLoadFailed
    case transcribeFailed(Int32)
    case claudeNotFound
    case claudeFailed(String)
    case tooShort

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url): return "Whisper 모델이 없어요: \(url.path)\n터미널에서 `make model` 실행"
        case .modelLoadFailed: return "Whisper 모델 로드 실패"
        case .transcribeFailed(let rc): return "받아쓰기 실패 (rc=\(rc))"
        case .claudeNotFound: return "claude CLI를 못 찾았어요"
        case .claudeFailed(let msg): return "Claude 정제 실패: \(msg)"
        case .tooShort: return "너무 짧아요"
        }
    }
}

/// UserDefaults 기반 설정
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum ClaudeModel: String, CaseIterable, Identifiable {
        case haiku, sonnet, opus
        var id: String { rawValue }
        var label: String {
            switch self {
            case .haiku: return "Haiku (빠름)"
            case .sonnet: return "Sonnet (균형)"
            case .opus: return "Opus (최고 품질)"
            }
        }
    }

    enum Engine: String, CaseIterable, Identifiable {
        case claude, apple
        var id: String { rawValue }
        var label: String {
            switch self {
            case .claude: return "Claude (구독, 품질↑)"
            case .apple: return "Apple 온디바이스 (빠름)"
            }
        }
    }

    enum STTEngine: String, CaseIterable, Identifiable {
        case whisper, apple
        var id: String { rawValue }
        var label: String {
            switch self {
            case .whisper: return "Whisper large-v3 (정확)"
            case .apple: return "Apple 실시간 (빠름)"
            }
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case ko, en, auto
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ko: return "한국어"
            case .en: return "English"
            case .auto: return "자동 감지"
            }
        }
    }

    @Published var claudeModel: ClaudeModel {
        didSet { d.set(claudeModel.rawValue, forKey: "claudeModel") }
    }
    @Published var sttEngine: STTEngine {
        didSet { d.set(sttEngine.rawValue, forKey: "sttEngine") }
    }
    @Published var engine: Engine {
        didSet { d.set(engine.rawValue, forKey: "engine") }
    }
    @Published var refineEnabled: Bool {
        didSet { d.set(refineEnabled, forKey: "refineEnabled") }
    }
    @Published var restoreClipboard: Bool {
        didSet { d.set(restoreClipboard, forKey: "restoreClipboard") }
    }
    @Published var language: Language {
        didSet { d.set(language.rawValue, forKey: "language") }
    }
    @Published var showIdlePill: Bool {
        didSet { d.set(showIdlePill, forKey: "showIdlePill") }
    }
    @Published var learnVocabulary: Bool {
        didSet { d.set(learnVocabulary, forKey: "learnVocabulary") }
    }
    @Published var playSounds: Bool {
        didSet { d.set(playSounds, forKey: "playSounds") }
    }

    private init() {
        claudeModel = ClaudeModel(rawValue: d.string(forKey: "claudeModel") ?? "") ?? .haiku
        sttEngine = STTEngine(rawValue: d.string(forKey: "sttEngine") ?? "") ?? .whisper
        engine = Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .claude
        refineEnabled = d.object(forKey: "refineEnabled") as? Bool ?? true
        restoreClipboard = d.object(forKey: "restoreClipboard") as? Bool ?? true
        language = .ko // 항상 한국어 (한국어 전용: 다른 언어로 잘못 인식되는 것 방지)
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        learnVocabulary = d.object(forKey: "learnVocabulary") as? Bool ?? true
        showIdlePill = d.object(forKey: "showIdlePill") as? Bool ?? true
    }

    // MARK: - 경로

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dicto", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var modelsDir: URL {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"
    static var modelURL: URL { modelsDir.appendingPathComponent(modelFileName) }

    /// 개인 사전: 한 줄에 한 단어 (Whisper 힌트 + 정제 + 자동 교정에 사용). 문법은 Vocabulary 참고
    static var dictionaryURL: URL { appSupportDir.appendingPathComponent("dictionary.txt") }

    /// 사전 파일이 없으면 기본값으로 만들고, 수동 사전 + 자동 학습 단어를 합쳐 로드
    static func loadVocabulary() -> Vocabulary {
        let url = dictionaryURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let seed = """
            # Dicto 개인 사전 - 한 줄에 한 단어/표현. '#'로 시작하면 주석.
            # 자주 잘못 받아 적히는 고유명사, 기술 용어를 적어두면 정확도가 올라가요.
            # '올바른표기: 잘못들린표기1, 잘못들린표기2' → 받아쓴 뒤 자동 치환
            # '!단어' → 자동 학습 금지
            Supabase: 수파베이스, 슈파베이스
            Next.js
            SwiftUI
            Xcode
            Claude Code
            """
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        return Vocabulary.load()
    }

    /// 마지막 결과 로그 (디버깅용)
    static var historyURL: URL { appSupportDir.appendingPathComponent("history.log") }
}
