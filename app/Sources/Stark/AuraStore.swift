import Foundation

/// Aura: the local learning loop. Accepted rewrites append to
/// ~/.stark/aura/pairs.jsonl as training pairs; an undo appends the same
/// pair marked rejected (training keeps the last record per pair). Nothing
/// ever leaves the machine; deleting the folder forgets everything.
struct AuraPair: Codable {
    let ts: Date
    let app: String?
    let tag: String // chained personas join as "friendly+concise"
    let input: String
    let output: String
    var accepted: Bool
}

@MainActor
final class AuraStore {
    static let shared = AuraStore()
    private var last: AuraPair?
    private var cachedCount: Int?

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stark/aura")
    }
    static var file: URL { dir.appendingPathComponent("pairs.jsonl") }

    func record(app: String?, tags: [String], input: String, output: String) {
        let pair = AuraPair(ts: Date(), app: app, tag: tags.joined(separator: "+"),
                            input: input, output: output, accepted: true)
        append(pair)
        last = pair
    }

    /// The user undid the last rewrite — log it as a rejection.
    func markLastRejected() {
        guard var pair = last else { return }
        pair.accepted = false
        append(pair)
        last = nil
    }

    func count() -> Int {
        if let cachedCount { return cachedCount }
        let n = (try? String(contentsOf: Self.file, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        cachedCount = n
        return n
    }

    func forget() {
        try? FileManager.default.removeItem(at: Self.dir)
        last = nil
        cachedCount = 0
    }

    private func append(_ pair: AuraPair) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(pair) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.file)
        }
        cachedCount = (cachedCount ?? 0) + 1
    }
}
