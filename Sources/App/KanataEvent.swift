import Foundation

/// Parsed TCP event from kanata.
enum KanataEvent: Equatable {
    case layerChange(String)
    case configReload

    /// Parses a single JSON line from kanata's TCP stream.
    static func parse(_ line: String) -> KanataEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let layerChange = json["LayerChange"] as? [String: Any],
           let newLayer = layerChange["new"] as? String {
            return .layerChange(newLayer)
        } else if json["ConfigFileReload"] != nil {
            return .configReload
        }

        return nil
    }
}
