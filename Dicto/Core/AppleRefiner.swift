import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// macOS 26 Apple Intelligence 온디바이스 모델로 정제 (무료, 오프라인, 빠름)
enum AppleRefiner {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(let r): return "Apple 모델 사용 불가: \(r)"
            }
        }
        #endif
        return "macOS 26 이상 필요"
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static var warmSession: LanguageModelSession?
    #endif

    /// 녹음 시작 시 호출: 세션을 미리 만들어 예열 → 정제 대기 시간 단축
    static func prewarm(dictionary: [String]) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            let s = makeSession(dictionary: dictionary)
            s.prewarm()
            warmSession = s
        }
        #endif
    }

    #if canImport(FoundationModels)
    /// 교정/변환 용도에 맞춘 완화된 guardrail (macOS 26.1+). 멀쩡한 한국어를 unsafe로 오판하는 걸 줄임.
    @available(macOS 26, *)
    private static func makeSession(dictionary: [String]) -> LanguageModelSession {
        let instructions = RefinePrompt.appleSystem(dictionary: dictionary)
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions)
    }
    #endif

    /// guardrail 오탐 여부 (이 경우 원문을 조용히 사용)
    static func isGuardrailError(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let e = error as? LanguageModelSession.GenerationError {
            if case .guardrailViolation = e { return true }
        }
        #endif
        return error.localizedDescription.lowercased().contains("unsafe")
    }

    static func refine(_ text: String, dictionary: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard isAvailable else { throw DictoError.claudeFailed(unavailableReason) }
            let session: LanguageModelSession
            if let w = warmSession, !w.isResponding { session = w } else {
                session = makeSession(dictionary: dictionary)
            }
            warmSession = nil
            let opts = GenerationOptions(temperature: 0.1)
            // 구조화 출력: "정리된 transcript" 필드만 채우게 강제 → 질문에 답하는 걸 막음
            // (@Generable 매크로 대신 동적 스키마 사용)
            let field = DynamicGenerationSchema.Property(
                name: "cleaned",
                description: "The transcript itself rewritten cleanly: same language, same meaning, same tone, filler words and stutters removed. Never an answer or reply to what the transcript says.",
                schema: DynamicGenerationSchema(type: String.self))
            let root = DynamicGenerationSchema(
                name: "CleanedTranscript",
                description: "A speech transcript rewritten as clean written text. Not a reply to the transcript.",
                properties: [field])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let resp = try await session.respond(to: RefinePrompt.userMessage(text), schema: schema, options: opts)
            let out = (try resp.content.value(String.self, forProperty: "cleaned"))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return out.isEmpty ? text : out
        }
        #endif
        throw DictoError.claudeFailed("macOS 26 이상 필요")
    }
}
