import Foundation
import Combine

/// Fetches the model weights on first run.
///
/// The alternative is bundling them, which makes the app 1.2 GB — a download
/// most people abandon before they know whether they want the thing. Shipping
/// ~55 MB and fetching the weights once, with visible progress, trades a
/// one-time wait for a download people will actually finish.
///
/// Weights land in Application Support rather than inside the bundle, so a
/// later app update doesn't force a re-download and the user can delete them
/// without deleting Stark.
@MainActor
final class ModelStore: ObservableObject {

    enum State: Equatable {
        case missing
        case downloading(fraction: Double, received: Int64, total: Int64)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    /// Published so `install.sh` and the app agree on one location.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Stark", isDirectory: true)
    }

    static let fileName = "stark-1.7b-Q5_K_M.gguf"
    static var destination: URL { directory.appendingPathComponent(fileName) }

    private static let remote = URL(string:
        "https://huggingface.co/suraj10620/stark-1.7b-gguf/resolve/main/\(fileName)?download=true")!

    /// Roughly what to expect, for the progress bar before the server sends a
    /// Content-Length (redirects to a CDN often omit it on the first response).
    private static let approximateBytes: Int64 = 1_252_000_000

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    init() { refresh() }

    /// A model already in the bundle wins: a build made with the weights
    /// included should never ask the user to download them.
    func refresh() {
        if let bundled = Config.bundledModel {
            state = .ready(URL(fileURLWithPath: bundled))
            return
        }
        let dest = Self.destination
        if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64,
           size > 500_000_000 {
            state = .ready(dest)
        } else {
            state = .missing
        }
    }

    var isReady: Bool { if case .ready = state { return true }; return false }

    func start() {
        guard case .missing = state else { return }
        state = .downloading(fraction: 0, received: 0, total: Self.approximateBytes)

        try? FileManager.default.createDirectory(at: Self.directory,
                                                 withIntermediateDirectories: true)

        let t = URLSession.shared.downloadTask(with: Self.remote) { [weak self] tmp, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let tmp,
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.state = .failed("download failed (HTTP \(code))")
                    return
                }
                do {
                    // Move into place only once the transfer completed, so an
                    // interrupted download can never look like a valid model.
                    try? FileManager.default.removeItem(at: Self.destination)
                    try FileManager.default.moveItem(at: tmp, to: Self.destination)
                    self.state = .ready(Self.destination)
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
        observation = t.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                let total = progress.totalUnitCount > 0
                    ? progress.totalUnitCount : Self.approximateBytes
                self.state = .downloading(fraction: progress.fractionCompleted,
                                          received: progress.completedUnitCount,
                                          total: total)
            }
        }
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        observation = nil
        refresh()
    }

    static func describe(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }
}
