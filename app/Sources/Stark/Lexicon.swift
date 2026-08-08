import Foundation

/// Deterministic post-pass for the personal dictionary: words the model must
/// never alter. If the source contained a protected word and the rewrite
/// mangled it (small edit distance), the user's spelling is restored.
enum Lexicon {
    static func enforce(_ words: [String], source: String, output: String) -> String {
        guard !words.isEmpty else { return output }
        var result = output
        for word in words {
            guard !word.isEmpty,
                  contains(source, word: word),
                  !contains(result, word: word) else { continue }
            result = restore(word, in: result)
        }
        return result
    }

    private static func contains(_ text: String, word: String) -> Bool {
        tokens(of: text).contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    private static func tokens(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func restore(_ word: String, in text: String) -> String {
        let limit = max(1, word.count / 3)
        var best: (token: String, dist: Int)?
        for token in Set(tokens(of: text)) {
            guard abs(token.count - word.count) <= limit else { continue }
            let d = distance(token.lowercased(), word.lowercased())
            if d > 0, d <= limit, d < (best?.dist ?? Int.max) { best = (token, d) }
        }
        guard let best else { return text }
        return text.replacingOccurrences(of: best.token, with: word)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
