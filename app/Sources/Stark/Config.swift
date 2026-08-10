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
    var hotkey: String = "cmd+d"
    var preset: String = "polish" // style for one-shot rewrites outside personas
    /// Frontmost-app bundle id → style tags applied in order.
    var personas: [String: [String]] = Config.defaultPersonas
    /// Words the model must never alter; restored by a post-pass if mangled.
    var dictionary: [String] = []
    /// Aura: log accepted rewrites as local training pairs.
    ///
    /// On by default. Both this and `completion` used to default off, on the
    /// theory that anything watching what you type should be opt-in. But they
    /// never leave the machine, they are the two features that make Stark feel
    /// like more than a spellchecker, and defaulting them off meant most people
    /// never saw them at all. Both are one click away in the menu bar.
    var aura: Bool = true
    /// Predictive typing: suggestions that finish your sentence as you type.
    var completion: Bool = true
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
    /// Explicit path, then weights inside the bundle, then weights the user
    /// downloaded on first run. Most people are on the third: the app ships
    /// without the model so the download is ~30 MB instead of 1.28 GB.
    var modelPath: String {
        if !model.isEmpty {
            return model.hasPrefix("~") ? (model as NSString).expandingTildeInPath : model
        }
        if let bundled = Config.bundledModel { return bundled }
        return Config.downloadedModel ?? ""
    }

    /// Mirrors `ModelStore.installedPath()` without needing the main actor,
    /// so `ServerManager` can ask from wherever it happens to be.
    static var downloadedModel: String? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Stark/stark-1.7b-Q5_K_M.gguf")
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > 1_000_000_000 else { return nil }
        return url.path
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
