import Foundation

/// Owns the local `mlx_lm server` subprocess: starts it with the fine-tuned
/// adapter, polls /v1/models until healthy, and kills it on quit.
final class ServerManager: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, running, failed(String)

        var label: String {
            switch self {
            case .stopped: return "stopped"
            case .starting: return "starting…"
            case .running: return "running"
            case .failed(let msg): return "failed — \(msg)"
            }
        }
    }

    @Published private(set) var status: Status = .stopped

    private let config: Config
    private var process: Process?
    private var stopping = false

    init(config: Config) { self.config = config }

    func start() {
        guard process == nil else { return }
        stopping = false
        setStatus(.starting)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.pythonPath)
        var args = ["-m", "mlx_lm", "server",
                    "--model", config.modelPath,
                    "--host", "127.0.0.1",
                    "--port", String(config.port)]
        if !config.adapterAbsPath.isEmpty,
           FileManager.default.fileExists(atPath: config.adapterAbsPath) {
            args += ["--adapter-path", config.adapterAbsPath]
        }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
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
        process?.terminate()
        process = nil
        setStatus(.stopped)
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
