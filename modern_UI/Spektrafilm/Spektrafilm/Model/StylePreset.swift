//  StylePreset.swift — a named Layer 2 grade, saved and applied on its own.
//
//  The settings clipboard deliberately does not carry `adjustments`
//  (`SettingsClipboard.notCopied`): Post-Dev is outside that copy's
//  positioning, and a paste of film, paper and placement must not also
//  paste a grade. A style is the other path. It writes `Sidecar.adjustments`
//  and nothing else — not film, paper, crop, masks or decode — and it lives
//  in its own file, `style-presets.json`, not in a clipboard group.
//
//  The store is a value with an injected URL so a test never reads or writes
//  the user's Application Support (trap 24).

import Foundation

struct StylePreset: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var adjustments: Adjustments
    var created: Date

    /// `name` trimmed, at most 80 characters. Nil when the trimmed name is
    /// empty — a style with no name is not a style.
    static func make(name: String, adjustments: Adjustments,
                     id: UUID = UUID(), created: Date = Date()) -> StylePreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return StylePreset(id: id, name: String(trimmed.prefix(80)),
                           adjustments: adjustments, created: created)
    }

    /// `sidecar` with this grade and nothing else replaced.
    func applied(to sidecar: Sidecar) -> Sidecar {
        var out = sidecar
        out.adjustments = adjustments
        return out
    }
}

enum StylePresetStore {
    struct Document: Codable, Equatable, Sendable {
        var version: Int = 1
        var presets: [StylePreset] = []
    }

    /// `~/Library/Application Support/SpektraLab/style-presets.json`.
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SpektraLab")
            .appending(path: "style-presets.json")
    }

    /// A file that is missing or unreadable is an empty list, not a throw:
    /// a hand-edited preset file must not take the grade rail down.
    static func load(from url: URL) -> [StylePreset] {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return doc.presets
    }

    static func save(_ presets: [StylePreset], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Document(version: 1, presets: presets)).write(to: url, options: .atomic)
    }
}
