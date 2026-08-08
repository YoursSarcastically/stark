import Foundation

/// Last line of defence before Stark pastes over text the user cannot get back.
///
/// The fine-tune steers a *chat* model with a one-word system tag, which is a
/// thin leash. When the selection reads like a question ("who is you"), the
/// base model's instinct to ANSWER can win over the instruction to rewrite —
/// and the user's sentence gets replaced by "I'm an AI language model…".
///
/// Rewriting is destructive and silent, so a wrong answer is far worse than no
/// answer. These checks are deliberately cheap and conservative: they only
/// reject output that could not plausibly be a rewrite of the input.
enum RewriteGuard {

    enum Rejection: Equatable {
        case assistantPreamble(String)
        case lengthExplosion(ratio: Double)
        case contentDrift(overlap: Double)
        case answeredQuestion
        case inventedText(wordRatio: Double)

        var reason: String {
            switch self {
            case .assistantPreamble(let s):
                return "the model answered instead of rewriting (\"\(s)…\")"
            case .lengthExplosion(let r):
                return String(format: "the result was %.1f× the original length", r)
            case .contentDrift(let o):
                return String(format: "only %.0f%% of your words survived", o * 100)
            case .answeredQuestion:
                return "you wrote a question and the model answered it"
            case .inventedText(let r):
                return String(format: "the model added words you didn't write (%.1f× as many)", r)
            }
        }
    }

    /// Openings that only ever appear when the model has started a conversation
    /// with the user rather than rewriting their text.
    private static let preambles = [
        "i'm an ai", "i am an ai", "as an ai", "i'm a language model",
        "i am a language model", "i'm claude", "i am claude", "i'm chatgpt",
        "as a language model", "i don't have personal", "i cannot answer",
        "i'm sorry, but i", "i'm unable to", "sure! here", "sure, here",
        "here's the rewritten", "here is the rewritten", "certainly!",
        "of course! here",
    ]

    /// How far each preset is allowed to move from the input. `typos` should be
    /// nearly identical; `expand` is *supposed* to grow. Anything looser than
    /// this range isn't a rewrite of the user's sentence any more.
    /// `maxWordRatio` is the tighter and more useful of the two length checks:
    /// a rewrite of a short sentence should not double its word count, even
    /// when the character count looks innocent.
    private static func limits(for tag: String)
        -> (maxRatio: Double, minOverlap: Double, maxWordRatio: Double) {
        switch tag {
        case "typos":              return (1.6, 0.60, 1.15)
        case "polish", "friendly", "formal": return (2.2, 0.28, 1.45)
        case "concise":            return (1.2, 0.20, 1.05)
        case "bullets":            return (2.5, 0.20, 1.60)
        case "expand":             return (9.0, 0.10, 6.00)
        case "prompt":             return (12.0, 0.0, 12.0) // rewrites wholesale by design
        default:                   return (3.0, 0.20, 1.80)
        }
    }

    /// Presets that are allowed to turn a question into something else.
    private static let mayRestructure: Set<String> = ["prompt", "bullets", "expand"]

    private static let questionWords: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose",
        "is", "are", "was", "were", "do", "does", "did", "can", "could",
        "should", "would", "will", "shall", "am", "have", "has",
    ]

    /// A question is text ending in "?" or opening with an interrogative. The
    /// interrogative test is what catches unpunctuated chat writing ("who is you").
    private static func looksLikeQuestion(_ s: String) -> Bool {
        if s.hasSuffix("?") { return true }
        guard let first = s.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first else { return false }
        return questionWords.contains(String(first))
    }

    /// nil when the rewrite looks legitimate; otherwise why it must not be pasted.
    static func check(input: String, output: String, tag: String) -> Rejection? {
        let inTrim = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outTrim = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inTrim.isEmpty, !outTrim.isEmpty else { return nil }

        let lower = outTrim.lowercased()
        if let hit = preambles.first(where: { lower.hasPrefix($0) }) {
            return .assistantPreamble(String(outTrim.prefix(hit.count)))
        }

        let (maxRatio, minOverlap, maxWordRatio) = limits(for: tag)

        // A question that comes back as a statement means the model answered it
        // rather than tidying it. This is the failure the one-word system tag is
        // weakest against, and word overlap can't see it — an answer reuses the
        // question's own nouns ("what is the capital of france" → "…is Paris").
        if !mayRestructure.contains(tag),
           looksLikeQuestion(inTrim), !looksLikeQuestion(outTrim) {
            return .answeredQuestion
        }

        // Length is the cheapest signal that the model went off and wrote an essay.
        let ratio = Double(outTrim.count) / Double(max(inTrim.count, 1))
        if ratio > maxRatio { return .lengthExplosion(ratio: ratio) }

        // Word count catches continuations the character check waves through —
        // "teh quick brown fox jumpd" → "…jumps over the lazy dog" is only 1.8×
        // the characters but nearly double the words, all of them invented.
        let inWords = inTrim.split(whereSeparator: \.isWhitespace).count
        let outWords = outTrim.split(whereSeparator: \.isWhitespace).count
        if inWords >= 3 {
            let wordRatio = Double(outWords) / Double(max(inWords, 1))
            if wordRatio > maxWordRatio { return .inventedText(wordRatio: wordRatio) }
        }

        // Word overlap catches answers that happen to be short ("A cat." for
        // "what is a cat"). Skipped for very short inputs, where a legitimate
        // typo fix can legitimately share almost nothing ("teh" -> "the").
        guard minOverlap > 0, inTrim.split(separator: " ").count >= 4 else { return nil }
        let overlap = wordOverlap(inTrim, outTrim)
        if overlap < minOverlap { return .contentDrift(overlap: overlap) }
        return nil
    }

    /// Fraction of the input's distinct words that still appear in the output.
    private static func wordOverlap(_ a: String, _ b: String) -> Double {
        let normalise: (String) -> Set<String> = { text in
            Set(text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 })
        }
        let x = normalise(a)
        guard !x.isEmpty else { return 1 }
        let y = normalise(b)
        return Double(x.intersection(y).count) / Double(x.count)
    }
}
