import Foundation

/// Minimal S-expression of a kanata `.kbd` file.
indirect enum SExpr: Equatable {
    case atom(String)
    case list([SExpr])

    var atom: String? {
        if case .atom(let s) = self { return s }
        return nil
    }

    var list: [SExpr]? {
        if case .list(let l) = self { return l }
        return nil
    }

    /// Human-readable rendering, used for tooltips of actions the HUD can't label.
    var rendered: String {
        switch self {
        case .atom(let s): return s
        case .list(let l): return "(" + l.map(\.rendered).joined(separator: " ") + ")"
        }
    }
}

/// What a key does in a layer, reduced to what the HUD can draw.
indirect enum KanataAction: Equatable {
    /// Plain key output, with optional modifier prefixes (`C-`, `S-`, …).
    case key(name: String, mods: Set<String>)
    /// `_`: fall through to the layer below.
    case transparent
    /// `XX` / `•`: swallow the key.
    case noop
    case tapHold(tap: KanataAction, hold: KanataAction)
    case layerWhileHeld(String)
    case layerSwitch(String)
    case oneShot(KanataAction)
    case unicode(String)
    /// `fork a b keys`: `a` normally, `b` when any of `keys` is held.
    case fork(KanataAction, KanataAction)
    case multi([KanataAction])
    case tapDance([KanataAction])
    case macro(String)
    /// Anything the HUD doesn't model (`switch`, `cmd`, chords, mouse, …).
    case other(String)
}

/// Everything the HUD needs from a parsed config.
struct KanataLayout: Equatable {
    var processUnmappedKeys = false
    var blockUnmappedKeys = false
    var delegateToFirstLayer = false
    /// Keys in `defsrc`, canonical kanata names, in order.
    var sourceKeys: [String] = []
    /// Layer names in definition order; the first is the base layer.
    var layerNames: [String] = []
    /// Per layer, per source key, the action.
    var layers: [String: [String: KanataAction]] = [:]

    var firstLayer: String? { layerNames.first }

    func action(layer: String, key: String) -> KanataAction? {
        layers[layer]?[key]
    }
}

enum KanataConfigError: Error, Equatable {
    case unbalanced
    case unreadable(String)
}

/// Parses the subset of kanata's config grammar the HUD needs: `defcfg` flags,
/// `defsrc`, `deflayer`, `deflayermap`, `defalias`, `defvar`, `deflocalkeys-*`
/// and `include`. Templates, chords, sequences etc. are skipped; actions the HUD
/// doesn't model become `.other` with their source text.
struct KanataConfigParser {
    /// Reads `include`d files relative to the config's directory.
    var fileReader: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }

    func parse(text: String, baseDir: String? = nil) throws -> KanataLayout {
        let forms = try Self.tokenize(text)
        return try build(forms: expandIncludes(forms, baseDir: baseDir))
    }

    // MARK: - Tokenizer

    static func tokenize(_ text: String) throws -> [SExpr] {
        var state = TokenizerState(chars: Array(text) + ["\n"])
        while state.i < state.chars.count {
            let c = state.chars[state.i]
            if state.atom.isEmpty, state.skipComment() { continue }
            switch c {
            case "(":
                state.flush()
                state.stack.append([])
            case ")":
                state.flush()
                guard state.stack.count > 1 else { throw KanataConfigError.unbalanced }
                let list = state.stack.removeLast()
                state.stack[state.stack.count - 1].append(.list(list))
            case "\"":
                state.flush()
                state.readString()
            case " ", "\t", "\n", "\r":
                state.flush()
            default:
                state.atom.append(c)
            }
            state.i += 1
        }
        state.flush()
        guard state.stack.count == 1 else { throw KanataConfigError.unbalanced }
        return state.stack[0]
    }

    private struct TokenizerState {
        let chars: [Character]
        var i = 0
        var atom = ""
        var stack: [[SExpr]] = [[]]

        mutating func flush() {
            guard !atom.isEmpty else { return }
            stack[stack.count - 1].append(.atom(atom))
            atom = ""
        }

        /// Skips `;; …` line comments and `#| … |#` block comments at `i`.
        /// A lone `;` is a key name, not a comment.
        mutating func skipComment() -> Bool {
            guard i + 1 < chars.count else { return false }
            if chars[i] == "#", chars[i + 1] == "|" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "|" && chars[i + 1] == "#") { i += 1 }
                i += 2
                return true
            }
            if chars[i] == ";", chars[i + 1] == ";" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                return true
            }
            return false
        }

        /// Reads a `"…"` string starting at the opening quote; leaves `i` on the closing quote.
        mutating func readString() {
            i += 1
            var s = ""
            while i < chars.count, chars[i] != "\"" {
                s.append(chars[i])
                i += 1
            }
            stack[stack.count - 1].append(.atom(s))
        }
    }

    // MARK: - Includes

    private func expandIncludes(_ forms: [SExpr], baseDir: String?) -> [SExpr] {
        var out: [SExpr] = []
        for form in forms {
            guard let list = form.list, list.first?.atom == "include", list.count >= 2,
                  let path = list[1].atom else {
                out.append(form)
                continue
            }
            let resolved: String
            if path.hasPrefix("/") {
                resolved = path
            } else if let baseDir {
                resolved = baseDir + "/" + path
            } else {
                resolved = path
            }
            if let text = fileReader(resolved), let sub = try? Self.tokenize(text) {
                out += expandIncludes(sub, baseDir: baseDir)
            }
        }
        return out
    }

    // MARK: - Builder

    private struct Env {
        var vars: [String: SExpr] = [:]
        var aliases: [String: SExpr] = [:]
        var localKeys: Set<String> = []
    }

    private func build(forms: [SExpr]) throws -> KanataLayout {
        var layout = KanataLayout()
        var env = Env()
        // Definitions first: layers refer to aliases/vars declared anywhere.
        for form in forms {
            guard let list = form.list, let head = list.first?.atom else { continue }
            collectDefinition(head: head, list: list, into: &layout, env: &env)
        }
        for form in forms {
            guard let list = form.list, let head = list.first?.atom, list.count >= 2 else { continue }
            if head == "deflayer" {
                guard let name = list[1].atom else { continue }
                let actions = Array(list.dropFirst(2))
                var map: [String: KanataAction] = [:]
                for (i, key) in layout.sourceKeys.enumerated() where i < actions.count {
                    map[key] = resolve(actions[i], env: env)
                }
                addLayer(name, map, to: &layout)
            } else if head == "deflayermap" {
                guard let name = list[1].list?.first?.atom ?? list[1].atom else { continue }
                var map: [String: KanataAction] = [:]
                for (key, action) in Self.pairs(Array(list.dropFirst(2))) where !["_", "__", "___"].contains(key) {
                    map[Self.keyName(key, env: env)] = resolve(action, env: env)
                }
                addLayer(name, map, to: &layout)
            }
        }
        return layout
    }

    private func collectDefinition(head: String, list: [SExpr], into layout: inout KanataLayout, env: inout Env) {
        let body = Array(list.dropFirst())
        switch head {
        case "defcfg":
            readCfg(body, into: &layout)
        case "defvar":
            for pair in Self.pairs(body) { env.vars[pair.0] = pair.1 }
        case "defalias":
            for pair in Self.pairs(body) { env.aliases[pair.0] = pair.1 }
        case "defsrc":
            layout.sourceKeys = body.compactMap(\.atom).map { Self.keyName($0, env: env) }
        case _ where head.hasPrefix("deflocalkeys"):
            for pair in Self.pairs(body) { env.localKeys.insert(pair.0) }
        default:
            break
        }
    }

    private func addLayer(_ name: String, _ map: [String: KanataAction], to layout: inout KanataLayout) {
        if layout.layers[name] == nil { layout.layerNames.append(name) }
        layout.layers[name] = map
    }

    private func readCfg(_ items: [SExpr], into layout: inout KanataLayout) {
        var i = 0
        while i + 1 < items.count {
            guard let key = items[i].atom else { i += 1; continue }
            let value = items[i + 1].atom ?? ""
            let on = ["yes", "true"].contains(value.lowercased())
            switch key {
            case "process-unmapped-keys": layout.processUnmappedKeys = on
            case "block-unmapped-keys": layout.blockUnmappedKeys = on
            case "delegate-to-first-layer": layout.delegateToFirstLayer = on
            default: break
            }
            i += 2
        }
    }

    private static func pairs(_ items: [SExpr]) -> [(String, SExpr)] {
        var out: [(String, SExpr)] = []
        var i = 0
        while i + 1 < items.count {
            if let name = items[i].atom { out.append((name, items[i + 1])) }
            i += 2
        }
        return out
    }

    /// Canonical name for a defsrc entry; local keys and unknown names pass through.
    private static func keyName(_ raw: String, env: Env) -> String {
        KeyNames.canonical(raw) ?? raw
    }

    // MARK: - Actions

    static let transparentSpellings: Set<String> = ["_", "‗", "≝"]
    static let noopSpellings: Set<String> = ["XX", "✗", "∅", "•"]
    static let modifierPrefixes = ["RC-", "RA-", "RS-", "RM-", "AG-", "C-", "A-", "S-", "M-"]

    private func resolve(_ expr: SExpr, env: Env, depth: Int = 0) -> KanataAction {
        guard depth < 32 else { return .other(expr.rendered) }
        switch expr {
        case .atom(let raw):
            return resolveAtom(raw, env: env, depth: depth)
        case .list(let items):
            guard let head = items.first?.atom else { return .other(expr.rendered) }
            let args = Array(items.dropFirst())
            return resolveList(head: head, args: args, env: env, depth: depth, source: expr)
        }
    }

    private func resolveAtom(_ raw: String, env: Env, depth: Int) -> KanataAction {
        if Self.transparentSpellings.contains(raw) { return .transparent }
        if Self.noopSpellings.contains(raw) { return .noop }
        if raw.hasPrefix("@"), let alias = env.aliases[String(raw.dropFirst())] {
            return resolve(alias, env: env, depth: depth + 1)
        }
        if raw.hasPrefix("$"), let value = env.vars[String(raw.dropFirst())] {
            return resolve(value, env: env, depth: depth + 1)
        }
        var rest = raw
        var mods: Set<String> = []
        var stripped = true
        while stripped {
            stripped = false
            for prefix in Self.modifierPrefixes where rest.hasPrefix(prefix) && rest.count > prefix.count {
                mods.insert(String(prefix.dropLast()))
                rest = String(rest.dropFirst(prefix.count))
                stripped = true
                break
            }
        }
        if let name = KeyNames.canonical(rest) { return .key(name: name, mods: mods) }
        if env.localKeys.contains(rest) { return .key(name: rest, mods: mods) }
        return .other(raw)
    }

    private func resolveList(head: String, args: [SExpr], env: Env, depth: Int, source: SExpr) -> KanataAction {
        let resolveExpr = { (expr: SExpr) -> KanataAction in self.resolve(expr, env: env, depth: depth + 1) }
        let sub = { (i: Int) -> KanataAction in i < args.count ? resolveExpr(args[i]) : .other(source.rendered) }
        let fallback = KanataAction.other(source.rendered)
        switch head {
        case _ where head.hasPrefix("tap-hold"):
            // Every variant: tap-timeout hold-timeout tap-action hold-action [...]
            return args.count >= 4 ? .tapHold(tap: sub(2), hold: sub(3)) : fallback
        case "layer-while-held", "layer-toggle":
            return args.first?.atom.map { .layerWhileHeld($0) } ?? fallback
        case "layer-switch":
            return args.first?.atom.map { .layerSwitch($0) } ?? fallback
        case _ where head.hasPrefix("one-shot"), "sticky":
            return args.count >= 2 ? .oneShot(sub(1)) : fallback
        case "unicode", "🔣":
            return args.first?.atom.map { .unicode($0) } ?? fallback
        case "unshift", "unmod":
            // (unshift key) / (unmod key) / (unmod (mods) key): the key is last.
            return args.isEmpty ? fallback : sub(args.count - 1)
        default:
            return resolveCombinator(head: head, args: args, sub: sub, resolveExpr: resolveExpr, fallback: fallback)
        }
    }

    private func resolveCombinator(head: String, args: [SExpr], sub: (Int) -> KanataAction,
                                   resolveExpr: (SExpr) -> KanataAction, fallback: KanataAction) -> KanataAction {
        switch head {
        case "fork":
            return args.count >= 2 ? .fork(sub(0), sub(1)) : fallback
        case "multi":
            return .multi(args.indices.map(sub))
        case "tap-dance", "tap-dance-eager":
            guard args.count >= 2, let list = args[1].list else { return fallback }
            return .tapDance(list.map(resolveExpr))
        case _ where head.hasPrefix("macro"):
            if case .other(let text) = fallback { return .macro(text) }
            return fallback
        default:
            return fallback
        }
    }
}
