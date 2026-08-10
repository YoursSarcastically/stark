import Foundation

/// Owns the local inference server subprocess: starts it, polls /v1/models
/// until healthy, and kills it on quit.
///
/// The server is `llama-server`, shipped inside the app bundle. It used to be
/// `python -m mlx_lm server`, which meant every user needed a Python with
/// mlx-lm installed — fine on the machine Stark was built on, an immediate
/// failure for anyone who downloaded it. The bundled binary is ~23 MB, needs
/// no runtime on the user's machine, and is Metal-accelerated.
final class ServerManager: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, running, sleeping, failed(String)

        var label: String {
            switch self {
            case .stopped: return "stopped"
            case .sleeping: return "sleeping (wakes on use)"
            case .starting: return "starting…"
            case .running: return "running"
            case .failed(let msg): return "failed. \(msg)"
            }
        }
    }

    @Published private(set) var status: Status = .stopped

    private let config: Config
    private var process: Process?
    private var stopping = false

    init(config: Config) { self.config = config }

    /// Kill any inference server left behind by a previous Stark.
    ///
    /// The server is spawned as a child process, so if Stark is force-quit or
    /// crashes, launchd reparents it (PPID 1) and it lives on — holding ~1 GB
    /// of RAM and, because mlx_lm's server busy-waits when idle, pegging a core
    /// forever. A few of those and macOS starts reporting Stark under "Using
    /// Significant Energy" while the app itself sits at 0%.
    private func reapOrphans() {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Match only our own server on our own port, so a user's unrelated
        // mlx_lm server is never touched.
        probe.arguments = ["-f", "llama-server .*--port \(config.port)"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
    }

    /// The bundled `llama-server`, alongside its dylibs. Its LC_RPATH is
    /// `@loader_path`, so binary and libraries only have to share a directory —
    /// which is what `Resources/llama/` gives us.
    static var bundledServer: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("llama/llama-server")
    }

    func start() {
        guard process == nil else { return }
        stopping = false
        reapOrphans()
        setStatus(.starting)

        guard let server = Self.bundledServer,
              FileManager.default.isExecutableFile(atPath: server.path) else {
            setStatus(.failed("inference engine missing from the app bundle"))
            return
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            setStatus(.failed("model not downloaded yet"))
            return
        }

        let p = Process()
        p.executableURL = server
        p.arguments = [
            "-m", config.modelPath,
            "--host", "127.0.0.1",
            "--port", String(config.port),
            // Small window: Stark rewrites a selection or completes a sentence,
            // never a whole document in one pass, and the KV cache is the bulk
            // of resident memory on an 8 GB machine.
            "-c", "4096",
            // Everything on the GPU. These are small models; splitting layers
            // between CPU and GPU only adds transfer overhead.
            "-ngl", "99",
            // Use the model's own chat template, so the one-word system tags
            // reach the model the same way they did in training.
            "--jinja",
            "--no-warmup",
        ]
        p.environment = ProcessInfo.processInfo.environment
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.setStatus(self.stopping
                    ? .stopped
                    : .failed("server exited (code \(proc.terminationStatus))"))
            }
        }

        do {
            try p.run()
            process = p
            pollHealth(remaining: 180)
        } catch {
            process = nil
            setStatus(.failed(error.localizedDescription))
        }
    }

    func stop() {
        stopping = true
        idleTimer?.invalidate()
        idleTimer = nil
        process?.terminate()
        process = nil
        reapOrphans() // terminate() is a request; make sure it actually died
        setStatus(.stopped)
    }

    // MARK: idle shutdown

    /// mlx_lm's server spins a core even with no requests in flight, so leaving
    /// it resident costs real battery on a laptop. Stark sleeps it after a
    /// quiet period and brings it back on demand; the cost is a one-off model
    /// load on the next rewrite, which beats a permanently pegged CPU.
    private var idleTimer: Timer?
    private var lastUse = Date()
    private let idleTimeout: TimeInterval = 300

    /// Call whenever the model is used, to push the idle deadline out.
    func noteUsed() {
        lastUse = Date()
        if process == nil { start() }
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process != nil else { return }
                    guard Date().timeIntervalSince(self.lastUse) > self.idleTimeout else { return }
                    self.sleepUntilNeeded()
                }
            }
        }
    }

    /// Stop the server but present it as dormant rather than broken, so the
    /// menu doesn't look like something failed.
    private func sleepUntilNeeded() {
        stopping = true
        idleTimer?.invalidate()
        idleTimer = nil
        process?.terminate()
        process = nil
        reapOrphans()
        setStatus(.sleeping)
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
    }

    private func pollHealth(remaining: Int) {
        guard remaining > 0 else {
            setStatus(.failed("server not healthy after 180s"))
            return
        }
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/models"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil, self.status == .starting else { return }
                if (resp as? HTTPURLResponse)?.statusCode == 200 {
                    self.setStatus(.running)
                    self.lastUse = Date()
                    self.armIdleTimer()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.pollHealth(remaining: remaining - 1)
                    }
                }
            }
        }.resume()
    }

    private func setStatus(_ s: Status) {
        if Thread.isMainThread { status = s }
        else { DispatchQueue.main.async { self.status = s } }
    }
}
