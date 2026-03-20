import Foundation

/// Simple file-based cache for compact session content
enum SessionCache {
    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(key: String, lines: [FilteredLine]) {
        let entries = lines.map { CacheEntry(text: $0.text, type: $0.type.rawValue) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let file = cacheDir.appendingPathComponent("\(key).json")
        try? data.write(to: file)
    }

    static func load(key: String) -> [FilteredLine] {
        let file = cacheDir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return [] }
        return entries.compactMap { entry in
            guard let type = LineType(rawValue: entry.type) else { return nil }
            return FilteredLine(text: entry.text, type: type)
        }
    }
}

private struct CacheEntry: Codable {
    let text: String
    let type: String
}
