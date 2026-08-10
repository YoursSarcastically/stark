import Foundation

/// Runtime configuration. Defaults work out of the box; any subset of fields
/// can be overridden via ~/.stark/config.json (missing fields keep defaults).
struct Config: Codable {
    var port: Int = 8765
    var python: String = "~/mlx-finetune/.venv/bin/python"
    /// Empty means "use the model shipped inside the app", which is the case
    /// for anyone who downloaded Stark rather than building it. Set it only to
    /// point at a different GGUF.
    var model: String = ""
    var adapterPath: String = "" // only needed when serving an unfused base
    var maxTokens: Int = 4096 // headroom for multi-page rewrites
    var temperature: Double = 0.2
    var hotkey: String = "ctrl+alt+s"
    var preset: String = "polish" // style for one-shot rewrites outside personas
    /// Frontmost-app bundle id → style tags applied in order.
    var personas: [String: [String]] = Config.defaultPersonas
    /// Words the model must never alter; restored by a post-pass if mangled.
    var dictionary: [String] = []
    /// Aura: log accepted rewrites as local training pairs (opt-in).
    var aura: Bool = false
    /// Predictive typing: ghost-text suggestions as you type, anywhere (opt-in).
    var completion: Bool = false
    var onboarded: Bool = false

    static let defaultPersonas: [String: [String]] = [
        "com.tinyspeck.slackmacgap": ["friendly", "concise"],
        "com.hnc.Discord": ["friendly"],
        "com.apple.MobileSMS": ["friendly"],
        "com.apple.mail": ["formal"],
        "com.microsoft.Outlook": ["formal"],
        "com.apple.Notes": ["bullets"],
        "md.obsidian": ["bullets"],
        "com.apple.dt.Xcode": ["typos"],
        "com.microsoft.VSCode": ["typos"],
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        python = try c.decodeIfPresent(String.self, forKey: .python) ?? d.python
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        adapterPath = try c.decodeIfPresent(String.self, forKey: .adapterPath) ?? d.adapterPath
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? d.preset
        personas = try c.decodeIfPresent([String: [String]].self, forKey: .personas) ?? d.personas
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
        aura = try c.decodeIfPresent(Bool.self, forKey: .aura) ?? d.aura
        completion = try c.decodeIfPresent(Bool.self, forKey: .completion) ?? d.completion
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
    }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stark/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    func save() {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url) }
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var pythonPath: String { (python as NSString).expandingTildeInPath }
    /// Resolution order: an explicit path in config.json, then the model bundled
    /// in the app. A downloaded Stark has no config file at all, so the bundled
    /// weights have to be the default rather than something the user configures.
    var modelPath: String {
        if !model.isEmpty {
            return model.hasPrefix("~") ? (model as NSString).expandingTildeInPath : model
        }
        return Config.bundledModel ?? ""
    }

    static var bundledModel: String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("model"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let gguf = files.first(where: { $0.hasSuffix(".gguf") })
        else { return nil }
        return dir.appendingPathComponent(gguf).path
    }
    var adapterAbsPath: String {
        adapterPath.isEmpty ? "" : (adapterPath as NSString).expandingTildeInPath
    }
}
