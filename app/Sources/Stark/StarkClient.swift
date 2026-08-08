import Foundation

enum StarkError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self { case .server(let s): return s }
    }
}

/// Streams a rewrite from the local OpenAI-compatible mlx_lm server.
struct StarkClient {
    let config: Config

    /// The fine-tune was trained on short pairs; past a few hundred words in
    /// one request it drops paragraphs and stops fixing. Long texts are
    /// therefore rewritten chunk-by-chunk and reassembled.
    func rewrite(text: String, tag: String,
                 onToken: @escaping (String) -> Void) async throws -> String {
        var out = ""
        for chunk in Self.chunks(of: text) {
            try Task.checkCancellation()
            if !chunk.joiner.isEmpty {
                out += chunk.joiner
                onToken(chunk.joiner)
            }
            if chunk.passthrough {
                out += chunk.text
                onToken(chunk.text)
            } else {
                out += try await rewriteChunk(text: chunk.text, tag: tag, onToken: onToken)
            }
        }
        return Lexicon.enforce(config.dictionary, source: text, output: out)
    }

    struct Chunk: Equatable {
        let joiner: String // what precedes this chunk when reassembling
        let text: String
        var passthrough = false // structured content the model must not touch
    }

    /// Markdown tables, headings, and fenced code lose their structure when
    /// the model rewrites them — they pass through verbatim instead.
    static func isProtected(_ block: String) -> Bool {
        let lines = block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let structured = lines.filter {
            $0.hasPrefix("|") || $0.hasPrefix("#") || $0.hasPrefix("```")
        }
        return structured.count * 2 >= lines.count
    }

    /// Blank-line paragraphs, each its own chunk; paragraphs over `limit`
    /// characters are further split on sentence boundaries (rejoined with a
    /// space, not a paragraph break). Short texts pass through whole.
    static func chunks(of text: String, limit: Int = 500) -> [Chunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return [Chunk(joiner: "", text: trimmed)] }
        var result: [Chunk] = []
        var inFence = false
        for para in trimmed.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            let fenceMarks = p.components(separatedBy: "```").count - 1
            if inFence || isProtected(p) {
                result.append(Chunk(joiner: result.isEmpty ? "" : "\n\n",
                                    text: p, passthrough: true))
                if fenceMarks % 2 == 1 { inFence.toggle() }
                continue
            }
            if fenceMarks % 2 == 1 { inFence = true }
            let pieces = p.count <= limit ? [p] : sentenceSplit(p, limit: limit)
            for (i, piece) in pieces.enumerated() {
                let joiner = result.isEmpty ? "" : (i == 0 ? "\n\n" : " ")
                result.append(Chunk(joiner: joiner, text: piece))
            }
        }
        return result.isEmpty ? [Chunk(joiner: "", text: trimmed)] : result
    }

    private static func sentenceSplit(_ text: String, limit: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(s) }
        }
        var chunks: [String] = []
        var current = ""
        for s in sentences {
            if current.isEmpty || current.count + s.count <= limit {
                current += s
            } else {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = s
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { chunks.append(last) }
        return chunks.isEmpty ? [text] : chunks
    }

    private func rewriteChunk(text: String, tag: String,
                              onToken: @escaping (String) -> Void) async throws -> String {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        // A rewrite's output is proportional to its input. Budgeting tokens
        // per chunk means a degeneration loop dies in seconds, not minutes.
        let inputTokens = max(50, text.count / 3)
        let body: [String: Any] = [
            "stream": true,
            "temperature": config.temperature,
            "max_tokens": min(config.maxTokens, inputTokens * 3),
            "repetition_penalty": 1.15,
            "messages": [
                ["role": "system", "content": tag],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw StarkError.server("server returned HTTP \(code)")
        }

        var out = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty else { continue }
            out += piece
            onToken(piece)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
