import Foundation
import Combine
import CryptoKit
import os

private let modelLog = Logger(subsystem: "com.local.stark", category: "model")

/// Fetches the model weights on first run.
///
/// The alternative is bundling them, which makes the download 1.28 GB — most of
/// which is one file that never changes between releases. Shipping ~30 MB and
/// fetching the weights once means the app itself downloads in seconds, updates
/// stay small, and the weights survive every future update untouched.
///
/// Weights land in Application Support rather than inside the bundle, so an app
/// update doesn't force a re-download and the user can delete them without
/// deleting Stark.
@MainActor
final class ModelStore: ObservableObject {

    /// Shared, because two things need the same answer: onboarding shows the
    /// progress bar, and the server cannot start until the file is on disk.
    static let shared = ModelStore()

    enum State: Equatable {
        case missing
        case downloading(fraction: Double, received: Int64, total: Int64)
        case verifying
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

    /// Set once the bytes on disk have been checked, so the hash is computed
    /// once ever rather than on every launch.
    private static var receiptURL: URL {
        directory.appendingPathComponent(".\(fileName).verified")
    }

    private static let remote = URL(string:
        "https://huggingface.co/suraj10620/stark-1.7b-gguf/resolve/main/\(fileName)?download=true")!

    /// Exact size and digest of the published file. Both are checked: the size
    /// catches a truncated transfer immediately, the digest catches a corrupt
    /// or substituted one. A half-downloaded GGUF does not fail loudly — it
    /// makes llama-server exit with a parse error the user cannot act on.
    static let expectedBytes: Int64 = 1_257_879_776
    private static let expectedSHA256 =
        "7a2af84dd97030b660bcf6ae2d7ec11d0b43c3f5cdb204b2d2eea0663c7697b8"

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    /// Last values published to the UI, so the observer can skip the other
    /// several thousand callbacks a second it receives.
    private nonisolated(unsafe) var lastPublished = Date.distantPast
    private nonisolated(unsafe) var lastFraction = -1.0
    /// Held for the length of the transfer. Stark is an LSUIElement app, so
    /// the moment its window stops being frontmost App Nap throttles it — the
    /// download crawled at ~190 KB/s where curl managed 4.3 MB/s on the same
    /// URL, and appeared to stop outright when the user switched away.
    private var activity: NSObjectProtocol?
    /// Kept when a transfer is interrupted so the next attempt continues rather
    /// than starting a 1.2 GB download again. Written to disk, not just held in
    /// memory: the interruption that matters is the app quitting, and losing
    /// 300 MB of progress because of it is exactly the thing this is for.
    private var resumeData: Data? {
        get { try? Data(contentsOf: Self.resumeURL) }
        set {
            if let newValue { try? newValue.write(to: Self.resumeURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: Self.resumeURL) }
        }
    }

    private static var resumeURL: URL {
        directory.appendingPathComponent(".\(fileName).resume")
    }

    private init() { refresh() }

    /// A model already in the bundle wins: a build made with the weights
    /// included should never ask the user to download them.
    func refresh() {
        if let bundled = Config.bundledModel {
            state = .ready(URL(fileURLWithPath: bundled))
            return
        }
        let dest = Self.destination
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? Int64 else {
            state = .missing
            return
        }
        if size == Self.expectedBytes, Self.hasReceipt() {
            state = .ready(dest)
        } else if size == Self.expectedBytes {
            // Right size, never verified — check the digest once, then record it.
            verify(dest)
        } else {
            // Wrong size means a previous run was interrupted. Leave the file
            // alone so the resume path can still use it, but do not pretend.
            modelLog.notice("model present but \(size) bytes, expected \(Self.expectedBytes)")
            state = .missing
        }
    }

    var isReady: Bool { if case .ready = state { return true }; return false }

    /// True when a previous attempt left something to continue from.
    var canResume: Bool { resumeData != nil }

    /// The weights, wherever they are, or nil if there are none yet.
    static func installedPath() -> String? {
        if let bundled = Config.bundledModel { return bundled }
        let dest = destination
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: dest.path)[.size] as? Int64,
              size == expectedBytes else { return nil }
        return dest.path
    }

    func start() {
        switch state {
        case .missing, .failed: break
        default: return
        }
        state = .downloading(fraction: 0, received: 0, total: Self.expectedBytes)

        try? FileManager.default.createDirectory(at: Self.directory,
                                                 withIntermediateDirectories: true)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Downloading the Stark model")

        let handler: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self] tmp, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.endActivity()
                if let error {
                    // A cancel hands back enough state to continue later.
                    let ns = error as NSError
                    self.resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    self.state = .failed(error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard let tmp, code == 200 || code == 206 else {
                    self.state = .failed("Download failed (HTTP \(code))")
                    return
                }
                do {
                    self.resumeData = nil
                    // Move into place only once the transfer completed, so an
                    // interrupted download can never look like a valid model.
                    try? FileManager.default.removeItem(at: Self.destination)
                    try FileManager.default.moveItem(at: tmp, to: Self.destination)
                    self.verify(Self.destination)
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }

        let t: URLSessionDownloadTask
        if let resumeData {
            t = URLSession.shared.downloadTask(withResumeData: resumeData,
                                               completionHandler: handler)
            modelLog.notice("resuming download from \(resumeData.count) bytes of state")
            self.resumeData = nil
        } else {
            t = URLSession.shared.downloadTask(with: Self.remote, completionHandler: handler)
        }

        lastPublished = .distantPast
        lastFraction = -1
        observation = t.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            let fraction = progress.fractionCompleted
            // `fractionCompleted` changes on every chunk that lands, and hopping
            // to the main actor for each one starved the very thread doing the
            // work: the transfer ran at ~275 KB/s while curl managed 4.3 MB/s on
            // the same URL. A progress bar does not need more than five updates
            // a second, and the transfer needs the main thread left alone.
            let now = Date()
            guard fraction >= 1
                    || (fraction - self.lastFraction >= 0.002
                        && now.timeIntervalSince(self.lastPublished) >= 0.2)
            else { return }
            self.lastFraction = fraction
            self.lastPublished = now
            // `completedUnitCount` on a URLSession task's Progress reports 0
            // for the whole transfer while `fractionCompleted` climbs quite
            // happily, which showed the user "0 MB of 0 MB" next to a bar at
            // 9%. The fraction is the only number here that can be trusted, so
            // the byte counts are derived from it against the known size.
            // Derived from the fraction, never from the unit counts. Those
            // are not bytes: URLSession reported "9 of 100" here, which the
            // byte formatter rendered as the memorable "0 MB of 0 MB". The
            // published size is known exactly, so the fraction is enough.
            let total = Self.expectedBytes
            let received = Int64(fraction * Double(total))
            Task { @MainActor in
                guard case .downloading = self.state else { return }
                self.state = .downloading(fraction: fraction,
                                          received: received, total: total)
            }
        }
        task = t
        t.resume()
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func cancel() {
        endActivity()
        task?.cancel { [weak self] data in
            Task { @MainActor in self?.resumeData = data }
        }
        task = nil
        observation = nil
        refresh()
    }

    /// Deletes the weights. Offered because 1.2 GB in Application Support is
    /// the kind of thing people want to find and remove deliberately.
    func remove() {
        try? FileManager.default.removeItem(at: Self.destination)
        try? FileManager.default.removeItem(at: Self.receiptURL)
        resumeData = nil
        refresh()
    }

    // MARK: - Integrity

    private static func hasReceipt() -> Bool {
        (try? String(contentsOf: receiptURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == expectedSHA256
    }

    /// Hashes in 4 MB chunks. Reading 1.2 GB into memory to hash it would be a
    /// noticeable spike on the 8 GB machines this is meant to run on.
    private func verify(_ url: URL) {
        state = .verifying
        Task.detached(priority: .utility) {
            var digest = SHA256()
            var ok = false
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    digest.update(data: chunk)
                }
                let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
                ok = hex == Self.expectedSHA256
                if !ok { modelLog.error("digest mismatch: \(hex)") }
            }
            await MainActor.run {
                if ok {
                    try? Self.expectedSHA256.write(to: Self.receiptURL,
                                                   atomically: true, encoding: .utf8)
                    self.state = .ready(url)
                    NotificationCenter.default.post(name: .starkModelReady, object: nil)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    self.state = .failed("The download was damaged. Try again.")
                }
            }
        }
    }

    static func describe(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }
}

extension Notification.Name {
    /// The server cannot start without weights, so it waits for this.
    static let starkModelReady = Notification.Name("starkModelReady")
}
