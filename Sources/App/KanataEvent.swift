import Foundation

/// Parsed TCP event from kanata.
enum KanataEvent: Equatable {
    case layerChange(String)
    case configReload
    /// A tap-hold key resolved as hold; `key` is kanata's OsCode name (`leftmeta`).
    case holdActivated(String)
    /// A tap-hold key resolved as tap.
    case tapActivated(String)
    /// Outcome of a `Reload{wait:true}` request. `timedOut` means kanata gave
    /// up waiting for the reload to complete; `ok` then reflects the previous reload.
    case reloadResult(ok: Bool, timedOut: Bool)
    /// kanata rejected a request (immediate `Error` reply) or reported a server-side error.
    case error(String)

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
        } else if let hold = json["HoldActivated"] as? [String: Any], let key = hold["key"] as? String {
            return .holdActivated(key.lowercased())
        } else if let tap = json["TapActivated"] as? [String: Any], let key = tap["key"] as? String {
            return .tapActivated(key.lowercased())
        } else if let result = json["ReloadResult"] as? [String: Any], let ok = result["ok"] as? Bool {
            return .reloadResult(ok: ok, timedOut: result["timeout_ms"] != nil)
        } else if let err = json["Error"] as? [String: Any], let msg = err["msg"] as? String {
            return .error(msg)
        }

        return nil
    }
}
