import Foundation

/// Minimal TOML parser. Supports: key = "string", integers, booleans,
/// single-line string arrays, comments, ~ expansion. No tables/sections.
enum TOMLParser {
    static func parse(_ text: String) -> [String: Any] {
        var result: [String: Any] = [:]

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Find key = value
            guard let eqRange = trimmed.range(of: "=") else {
                print("warning: skipping unrecognized config line: \(trimmed)")
                continue
            }

            let key = trimmed[trimmed.startIndex..<eqRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[eqRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)

            if key.isEmpty {
                print("warning: skipping unrecognized config line: \(trimmed)")
                continue
            }

            if let parsed = parseValue(rawValue) {
                result[key] = parsed
            } else {
                print("warning: could not parse value for key '\(key)': \(rawValue)")
            }
        }

        return result
    }

    private static func parseValue(_ raw: String) -> Any? {
        // Boolean
        if raw == "true" { return true }
        if raw == "false" { return false }

        // Integer
        if let i = Int(raw) { return i }

        // Quoted string (double quotes)
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            return Config.expandTilde(inner)
        }

        // Literal string (single quotes)
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            return Config.expandTilde(inner)
        }

        // Array of strings (single-line)
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return [String]() }
            var items: [String] = []
            for element in inner.components(separatedBy: ",") {
                let el = element.trimmingCharacters(in: .whitespaces)
                if (el.hasPrefix("\"") && el.hasSuffix("\"")) ||
                   (el.hasPrefix("'") && el.hasSuffix("'")) {
                    items.append(String(el.dropFirst().dropLast()))
                } else {
                    items.append(el)
                }
            }
            return items
        }

        return nil
    }
}
