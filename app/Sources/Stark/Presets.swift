import Foundation

struct Preset: Equatable {
    let key: String   // number-key shortcut in the panel
    let name: String
    let tag: String   // one-word system tag the fine-tune was trained on
    let icon: String  // SF Symbol
}

enum Presets {
    static func byTag(_ tag: String) -> Preset? {
        all.first { $0.tag == tag }
    }

    static let all: [Preset] = [
        Preset(key: "1", name: "Polish", tag: "polish", icon: "wand.and.stars"),
        Preset(key: "2", name: "Concise", tag: "concise", icon: "scissors"),
        Preset(key: "3", name: "Formal", tag: "formal", icon: "briefcase"),
        Preset(key: "4", name: "Friendly", tag: "friendly", icon: "face.smiling"),
        Preset(key: "5", name: "Fix typos", tag: "typos", icon: "textformat.abc"),
        Preset(key: "6", name: "Bullets", tag: "bullets", icon: "list.bullet"),
        Preset(key: "7", name: "Prompt enhance", tag: "prompt", icon: "sparkles"),
        Preset(key: "8", name: "Expand", tag: "expand", icon: "text.append"),
    ]
}
