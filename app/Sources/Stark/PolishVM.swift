import AppKit
import Foundation

@MainActor
final class PolishVM: ObservableObject {
    enum State: Equatable { case empty, pickPreset, generating, done, error(String) }

    @Published var input = ""
    @Published var output = ""
    @Published var state: State = .pickPreset
    @Published var activePreset: Preset?
    @Published var inPlace = false
    @Published var suggestOrganize = false
    /// Tags of the chain that produced the current output (Aura logging).
    private(set) var lastTags: [String] = []

    /// Fired on successful completion in in-place mode (paste-back hook).
    var onDone: ((String) -> Void)?

    /// The rewrite finished but failed `RewriteGuard`, so nothing was pasted.
    /// The panel stays open showing what came back, so the user can judge it
    /// and copy it themselves if it happens to be what they wanted.
    func reportRejection(_ reason: String) {
        state = .error("Not pasted — \(reason). Your text is unchanged.")
    }

    let server: ServerManager
    private let client: StarkClient
    private var task: Task<Void, Never>?

    init(client: StarkClient, server: ServerManager) {
        self.client = client
        self.server = server
    }

    func reset(with text: String, inPlace: Bool = false) {
        task?.cancel()
        input = text
        output = ""
        activePreset = nil
        self.inPlace = inPlace
        suggestOrganize = Self.looksLikeList(text)
        state = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .empty : .pickPreset
    }

    /// Rambling brain-dump heuristic: long, barely any line breaks, strung
    /// together with connectives — a good candidate for the bullets style.
    static func looksLikeList(_ text: String) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count > 40,
              text.components(separatedBy: "\n").count <= 2 else { return false }
        let lower = " " + text.lowercased() + " "
        let hits = ["and", "also", "then", "plus"].reduce(0) {
            $0 + lower.components(separatedBy: " \($1) ").count - 1
        }
        return hits >= 3
    }

    var canPickPreset: Bool { state == .pickPreset || state == .done }

    /// Panel closed — stop burning tokens in the background.
    func cancel() {
        task?.cancel()
        if state == .generating { state = .pickPreset }
    }

    func run(_ preset: Preset) { runChain([preset]) }

    /// Personas can chain styles (friendly then concise); each pass streams
    /// into the panel, feeding its result to the next.
    func runChain(_ presets: [Preset]) {
        guard canPickPreset, !input.isEmpty, !presets.isEmpty else { return }
        task?.cancel()
        lastTags = presets.map(\.tag)
        activePreset = presets[0]
        output = ""
        state = .generating
        let source = input
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var result = source
                for preset in presets {
                    self.activePreset = preset
                    self.output = ""
                    result = try await self.client.rewrite(text: result, tag: preset.tag) { piece in
                        Task { @MainActor in self.output += piece }
                    }
                    guard !Task.isCancelled else { return }
                }
                self.output = result
                if self.inPlace {
                    // clipboard stays untouched; the paste-back hook owns it
                    self.state = .done
                    self.onDone?(result)
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(result, forType: .string)
                    self.state = .done
                }
            } catch is CancellationError {
                // superseded by a newer run or panel reset
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }
}
