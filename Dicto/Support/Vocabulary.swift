import AppKit

/// 개인 사전 + 자동 학습
///
/// - dictionary.txt (사용자가 직접 편집)
///   - `Supabase`                      : 단어
///   - `Supabase: 수파베이스, 슈파베이스` : 잘못 들린 표기(별칭) → 올바른 표기로 자동 치환
///   - `!MVP`                          : 자동 학습 금지 (잘못 학습된 단어 막기)
/// - learned.txt (앱이 관리, `횟수<TAB>단어`)
///   - 받아쓴 결과에서 특이한 영문 단어(Supabase, MVP, iOS …)를 서로 다른 받아쓰기에서 센다
///   - `promoteCount`회 이상 나오면 사전에 포함 (한 번 나온 오인식 쓰레기는 걸러짐)
struct Vocabulary {
    /// 수동 단어 → 학습 단어(빈도순) 순서. 프롬프트/힌트에 앞에서부터 잘라 씀.
    var terms: [String]
    /// 올바른 표기 → 잘못 들린 표기들
    var aliases: [String: [String]]
    var blocked: Set<String> // 소문자

    static let promoteCount = 2
    static var learnedURL: URL { Settings.appSupportDir.appendingPathComponent("learned.txt") }

    // MARK: - 로드

    static func load() -> Vocabulary {
        var terms: [String] = []
        var aliases: [String: [String]] = [:]
        var blocked = Set<String>()
        for line in readLines(Settings.dictionaryURL) {
            if line.hasPrefix("!") {
                let w = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !w.isEmpty { blocked.insert(w.lowercased()) }
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let term = line[..<colon].trimmingCharacters(in: .whitespaces)
                let al = line[line.index(after: colon)...].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !term.isEmpty else { continue }
                terms.append(term)
                if !al.isEmpty { aliases[term, default: []] += al }
            } else {
                terms.append(line)
            }
        }
        var seen = Set(terms.map { $0.lowercased() })
        for (term, _) in learnedCounts().filter({ $0.1 >= promoteCount }) {
            let k = term.lowercased()
            guard !seen.contains(k), !blocked.contains(k) else { continue }
            seen.insert(k)
            terms.append(term)
        }
        return Vocabulary(terms: terms, aliases: aliases, blocked: blocked)
    }

    /// 학습 중인 단어 전체 (빈도 내림차순)
    static func learnedCounts() -> [(String, Int)] {
        readLines(learnedURL).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]) else { return nil }
            return (parts[1].trimmingCharacters(in: .whitespaces), n)
        }
        .sorted { $0.1 > $1.1 }
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - 교정

    /// 받아쓴 텍스트를 사전 기준으로 교정. 바뀐 내역은 로그용으로 반환.
    func correct(_ text: String) -> (String, [String]) {
        var out = text
        var changes: [String] = []

        // 1) 별칭 치환 (사용자가 명시한 규칙이라 그대로 신뢰)
        for (term, als) in aliases {
            for alias in als.sorted(by: { $0.count > $1.count }) {
                let replaced: String
                if Self.hasLatin(alias) {
                    // 영문 별칭은 단어 경계로만 (opt → optimize 안 건드림). 한글 조사는 붙어도 됨.
                    let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: alias) + "(?![A-Za-z0-9])"
                    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                    replaced = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                           withTemplate: NSRegularExpression.escapedTemplate(for: term))
                } else {
                    guard alias.count >= 2 else { continue }
                    replaced = out.replacingOccurrences(of: alias, with: term)
                }
                if replaced != out { changes.append("\(alias)→\(term)"); out = replaced }
            }
        }

        // 2) 영문 토큰 퍼지 교정: 대소문자만 다름 / 한 글자 차이 (Supabse → Supabase)
        let single = terms.filter { Self.hasLatin($0) && !$0.contains(" ") }
        let exact = Set(single)
        var result = ""
        var last = out.startIndex
        for r in Self.latinTokenRanges(out) {
            let tok = String(out[r])
            result += out[last..<r.lowerBound]
            last = r.upperBound
            guard !exact.contains(tok), let fix = fuzzyMatch(tok, in: single) else { result += tok; continue }
            changes.append("\(tok)→\(fix)")
            result += fix
        }
        result += out[last...]
        return (result, changes)
    }

    private func fuzzyMatch(_ tok: String, in terms: [String]) -> String? {
        let lower = tok.lowercased()
        guard tok.count >= 3 else { return nil }
        if let t = terms.first(where: { $0.count >= 3 && $0.lowercased() == lower }) { return t }
        // 한 글자 차이는 짧은 단어/실제 영어 단어면 오교정 위험이 커서 제외
        guard tok.count >= 4, !Self.isEnglishWord(lower) else { return nil }
        let near = terms.filter { $0.count >= 5 && abs($0.count - tok.count) <= 1 && Self.editDistance(lower, $0.lowercased()) == 1 }
        return near.count == 1 ? near[0] : nil // 후보가 여럿이면 애매하니 안 건드림
    }

    // MARK: - 학습

    /// 최종 결과에서 특이한 영문 단어를 뽑아 learned.txt 카운트 증가. 새로 사전에 들어간 단어 반환.
    @MainActor
    func learn(from text: String) -> [String] {
        let known = Set(terms.map { $0.lowercased() })
        var candidates: [String: String] = [:] // 소문자 → 표기 (한 받아쓰기에서 한 번만 셈)
        for r in Self.latinTokenRanges(text) {
            let tok = String(text[r])
            let k = tok.lowercased()
            guard !known.contains(k), !blocked.contains(k), Self.looksLikeTerm(tok) else { continue }
            candidates[k] = tok
        }
        guard !candidates.isEmpty else { return [] }

        var counts = Self.learnedCounts()
        var promoted: [String] = []
        for (k, tok) in candidates {
            if let i = counts.firstIndex(where: { $0.0.lowercased() == k }) {
                counts[i].1 += 1
                counts[i].0 = tok // 최근 표기로 갱신
                if counts[i].1 == Self.promoteCount { promoted.append(tok) }
            } else {
                counts.append((tok, 1))
            }
        }
        // 한 번만 나오고 묻힌 것들이 무한히 쌓이지 않게 상한
        counts.sort { $0.1 > $1.1 }
        if counts.count > 500 { counts = Array(counts.prefix(500)) }
        let body = "# Dicto 자동 학습 단어 (횟수<TAB>단어). \(Self.promoteCount)회 이상이면 사전에 반영.\n"
            + "# 잘못 배운 단어는 여기서 지우고 dictionary.txt에 '!단어'로 막으세요.\n"
            + counts.map { "\($0.1)\t\($0.0)" }.joined(separator: "\n") + "\n"
        try? body.write(to: Self.learnedURL, atomically: true, encoding: .utf8)
        return promoted
    }

    /// 사람이 일부러 쓴 고유명사/약어로 보이는가
    /// - iOS, SwiftUI, GitHub (중간 대문자) / MVP, API (전부 대문자) / M4, Next.js (숫자·점)
    /// - Supabase, Claude (첫 글자만 대문자)는 일반 영어 단어가 아닐 때만 (Make, Good 제외)
    @MainActor
    static func looksLikeTerm(_ tok: String) -> Bool {
        guard tok.count >= 2, tok.count <= 30 else { return false }
        let letters = tok.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        if stopwords.contains(tok.lowercased()) { return false }
        let hasInnerUpper = tok.dropFirst().contains { $0.isUppercase } && tok.contains { $0.isLowercase }
        let allUpper = letters.allSatisfy { $0.isUppercase }
        let hasDigitOrDot = tok.contains { $0.isNumber || $0 == "." }
        if hasInnerUpper || hasDigitOrDot { return true }
        if allUpper { return letters.count >= 2 }
        if tok.first!.isUppercase { return tok.count >= 4 && !isEnglishWord(tok.lowercased()) }
        return false // 전부 소문자 일반 단어는 학습 안 함
    }

    private static let stopwords: Set<String> = ["ok", "okay", "hi", "no", "yes", "the", "and", "or", "it"]

    // MARK: - 유틸

    static func hasLatin(_ s: String) -> Bool { s.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) } }

    /// 한글 사이에 섞인 영문 토큰 범위 (Next.js, C++ 등 포함, 문장 끝 마침표 제외)
    static func latinTokenRanges(_ s: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9]*(?:[.+#_-][A-Za-z0-9]+)*\\+*") else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s) }
    }

    private static var englishCache: [String: Bool] = [:]
    /// macOS 영어 맞춤법 사전에 있는 단어인가 (일반 영어 단어는 고유명사로 학습/교정하지 않음)
    static func isEnglishWord(_ w: String) -> Bool {
        if let c = englishCache[w] { return c }
        let run = { () -> Bool in
            let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            return r.location == NSNotFound
        }
        let ok = Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
        englishCache[w] = ok
        return ok
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// 프롬프트용: "Supabase (heard as: 수파베이스)"
    func promptTerms(limit: Int) -> [String] {
        terms.prefix(limit).map { t in
            if let al = aliases[t], !al.isEmpty { return "\(t) (heard as: \(al.joined(separator: "/")))" }
            return t
        }
    }
}
