import Foundation

// Where the text before the cursor comes from (BEA-648).
//
// The app target only *collects* raw Accessibility facts about the focused
// element into a `FieldSnapshot`. Deciding what those facts mean is done here,
// by an ordered list of pure `ContextProvider`s: the first one that can say
// what precedes the cursor wins. Providers key on the *shape* of what an app
// exposes (value + selection, text markers, value without a cursor), never on
// a bundle ID, so they apply to any app with that shape.
//
//   shape                                   provider                 examples
//   value + selected range                  SelectionRangeProvider   TextEdit, Zen/Firefox, Safari fields
//   empty value                             EmptyValueProvider       any cleared field (Enter-to-send)
//   text markers (WebKit/Chromium)          TextMarkerProvider       Chrome, Electron
//   value, no cursor                        AnchoredValueProvider    Warp, Terminal, Emacs (NS port)
//   app answers itself (per-app bridge)     AppBridgeProvider        Emacs (server socket)
//   nothing readable                        MemoryProvider           Susurro's own record of what it typed
//
// Adding a case means adding a provider, not editing the others.

/// Raw facts from one Accessibility read of the focused element. No
/// interpretation; never logged except via `detail`, which holds lengths and
/// positions only.
public struct FieldSnapshot: Sendable, Equatable {
    /// The element's whole `kAXValueAttribute`, if it is a string.
    public var value: String?
    /// `kAXSelectedTextRangeAttribute` (UTF-16 offsets), if readable.
    public var selection: NSRange?
    /// Text from the start of the element to the selection start, via the
    /// WebKit/Chromium text-marker API, if readable.
    public var markerBefore: String?
    public var role: String?
    /// The focused element is a secure (password) field; nothing was read.
    public var secure: Bool
    /// Text before the cursor reported by the app itself through an app
    /// bridge (per-app, last resort — e.g. the Emacs server), and its name.
    public var appBefore: String?
    public var appBridge: String?
    /// Placeholder strings the field may echo as its value when empty:
    /// `kAXPlaceholderValueAttribute`, plus CSS-generated text the reader
    /// found inside an editable web field (BEA-673). Never logged.
    public var placeholders: [String]

    public init(value: String? = nil, selection: NSRange? = nil, markerBefore: String? = nil,
                role: String? = nil, secure: Bool = false,
                appBefore: String? = nil, appBridge: String? = nil,
                placeholders: [String] = []) {
        self.placeholders = placeholders
        self.value = value
        self.selection = selection
        self.markerBefore = markerBefore
        self.role = role
        self.secure = secure
        self.appBefore = appBefore
        self.appBridge = appBridge
    }

    public static let secureField = FieldSnapshot(secure: true)

    /// A value containing U+0000 is not real text: Emacs 30's NS port
    /// publishes a stale buffer copy cut at a NUL and padded with NULs, which
    /// does not follow the cursor. Such a value (and any selection measured
    /// against it) is dropped, so the memory fallback applies instead of
    /// anchoring inside garbage.
    public var sanitized: FieldSnapshot {
        guard let value else { return self }
        if !value.contains("\u{0}") {
            guard FieldSnapshot.looksEmpty(value, placeholders: placeholders) else { return self }
            // An empty-looking field (BEA-673): only newlines / zero-width
            // scaffolding, or an echo of its own placeholder. Treat it as
            // truly empty so no leading space is added; the marker prefix
            // would echo the same placeholder, so it is dropped too.
            var copy = self
            copy.value = ""
            copy.selection = NSRange(location: 0, length: 0)
            copy.markerBefore = nil
            copy.emptyEcho = true
            return copy
        }
        var copy = self
        copy.value = nil
        copy.selection = nil
        copy.markerBefore = nil
        copy.corruptValue = true
        return copy
    }

    /// Set by `sanitized` when the value was dropped.
    public var corruptValue = false
    /// Set by `sanitized` when a non-empty value was recognised as an empty
    /// field (placeholder echo or newline/zero-width scaffolding).
    public var emptyEcho = false

    /// Characters editors leave in an empty field that are not text.
    static let scaffolding: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    /// The value with zero-width scaffolding removed and surrounding line
    /// breaks trimmed (a cleared contenteditable keeps a `<br>`).
    static func visibleBody(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.filter { !scaffolding.contains($0) })
        return String(scalars).trimmingCharacters(in: .newlines)
    }

    /// True when `value` is what an empty field reports: nothing but line
    /// breaks / zero-width characters, or exactly one of its placeholders
    /// (Chromium exposes CSS `::before { content: attr(data-placeholder) }`
    /// as the value of an empty contenteditable — BEA-673).
    public static func looksEmpty(_ value: String, placeholders: [String]) -> Bool {
        if value.isEmpty { return false } // already empty; nothing to rewrite
        let body = visibleBody(value)
        if body.isEmpty { return true }
        return placeholders.contains { !$0.isEmpty && visibleBody($0) == body }
    }
    /// Nothing focused, or the read timed out.
    public static let nothing = FieldSnapshot()

    /// Shape summary for the coverage log: lengths and positions only.
    public var detail: String {
        if secure { return "secure" }
        var parts = ["role=\(role ?? "?")"]
        if let value { parts.append("valueLen=\((value as NSString).length)") }
        if let selection { parts.append("caret=\(selection.location)") }
        if let markerBefore { parts.append("markerLen=\(markerBefore.count)") }
        if corruptValue { parts.append("corruptValue") }
        if emptyEcho { parts.append("emptyEcho") }
        if let appBefore { parts.append("bridge=\(appBridge ?? "?") len=\(appBefore.count)") }
        return parts.joined(separator: " ")
    }
}

/// What a provider worked out.
public struct ProvidedContext: Sendable, Equatable {
    public var before: String
    public var after: String?
    public var source: ContextSource
    public var provider: String
}

public protocol ContextProvider: Sendable {
    var name: String { get }
    /// `memory` is what Susurro last typed into this same app, and where
    /// (nil if nothing, or another app since).
    func context(_ snapshot: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext?
}

/// Text the app itself reported through an app bridge. The only per-app
/// source: used where an app's Accessibility data is unusable and the app
/// offers its own exact answer (Emacs server). Exact, so it goes first.
public struct AppBridgeProvider: ContextProvider {
    public let name = "appBridge"
    public init() {}
    public func context(_ s: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext? {
        guard let before = s.appBefore else { return nil }
        return ProvidedContext(before: before, after: nil, source: .appBridge,
                               provider: name + "." + (s.appBridge ?? "?"))
    }
}

/// Value + selection: the standard Cocoa contract. A caret past the end of
/// the reported value means whitespace the value doesn't show (Gecko drops a
/// trailing typed space from contenteditable values).
public struct SelectionRangeProvider: ContextProvider {
    public let name = "selectionRange"
    public init() {}
    public func context(_ s: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext? {
        guard let value = s.value, let sel = s.selection, sel.location != NSNotFound else { return nil }
        let ns = value as NSString
        let start = max(0, min(sel.location, ns.length))
        let end = max(start, min(sel.location + max(sel.length, 0), ns.length))
        var before = ns.substring(to: start)
        if sel.location > ns.length { before += " " }
        return ProvidedContext(before: before, after: ns.substring(from: end),
                               source: .accessibility, provider: name)
    }
}

/// An empty value settles the empty-field case even where the cursor isn't
/// readable (the stray leading space after Enter-to-send).
public struct EmptyValueProvider: ContextProvider {
    public let name = "emptyValue"
    public init() {}
    public func context(_ s: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext? {
        guard let value = s.value, value.isEmpty else { return nil }
        return ProvidedContext(before: "", after: "", source: .accessibility, provider: name)
    }
}

/// WebKit/Chromium text markers. The marker start can be the document start
/// rather than the field start, so when the value is known the result must be
/// a prefix of it.
public struct TextMarkerProvider: ContextProvider {
    public let name = "textMarkers"
    public init() {}
    public func context(_ s: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext? {
        guard let before = s.markerBefore else { return nil }
        if let value = s.value {
            guard value.hasPrefix(before) else { return nil }
            return ProvidedContext(before: before, after: String(value.dropFirst(before.count)),
                                   source: .accessibility, provider: name)
        }
        return ProvidedContext(before: before, after: nil, source: .accessibility, provider: name)
    }
}

/// A readable value with no readable cursor: terminal emulators (Warp,
/// Terminal, iTerm) and editors that publish the buffer as the window value
/// (Emacs NS port). The cursor is located by anchoring on what Susurro last
/// typed into this app:
/// 1. at the end of the value (ignoring trailing newlines), allowing up to
///    `maxUserEdit` characters of the user's own edits after it (a typed
///    space, a deleted full stop) — the terminal/prompt case;
/// 2. otherwise, if the remembered text (or a prefix of it, for deletions)
///    occurs exactly once anywhere in the value, the cursor is taken to be
///    right after it — the editor case, where the cursor sits mid-buffer.
/// No anchor (nothing typed yet, or the text is gone/ambiguous) = nil.
public struct AnchoredValueProvider: ContextProvider {
    public let name = "anchoredValue"
    public var maxUserEdit = 8
    public var minAnchor = 4
    /// Searching a huge buffer is cheap, but cap it anyway.
    public var searchLimit = 200_000
    public init() {}

    public func context(_ s: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext? {
        guard let value = s.value, !value.isEmpty, let memory, !memory.tail.isEmpty else { return nil }
        if let before = endAnchored(value: value, tail: memory.tail) {
            return ProvidedContext(before: before, after: nil, source: .anchoredValue, provider: name + ".end")
        }
        if let found = interior(value: value, memory: memory) {
            return ProvidedContext(before: found.before, after: found.after, source: .anchoredValue,
                                   provider: name + found.how)
        }
        return nil
    }

    private func prefixes(_ tail: String) -> [String] {
        let chars = Array(tail)
        let minLen = min(minAnchor, chars.count)
        return stride(from: chars.count, through: minLen, by: -1).map { String(chars[0..<$0]) }
    }

    func endAnchored(value: String, tail: String) -> String? {
        var buffer = Substring(value)
        while let last = buffer.last, last.isNewline { buffer = buffer.dropLast() }
        let window = String(buffer.suffix(tail.count + maxUserEdit))
        for prefix in prefixes(tail) {
            guard let r = window.range(of: prefix, options: .backwards) else { continue }
            let edit = window[r.upperBound...]
            if edit.count <= maxUserEdit, !edit.contains(where: \.isNewline) { return String(buffer) }
            return nil
        }
        return nil
    }

    /// Cursor mid-buffer. The anchor is the longest prefix of the remembered
    /// text found in the value. Several matches (the same phrase dictated
    /// twice) are resolved by the remembered insertion position: the match
    /// nearest to it wins, if it is clearly nearest; otherwise no answer.
    /// When the value grew by a few characters beyond what the anchor
    /// accounts for, and they sit right after the anchor and are all whitespace,
    /// the user typed them there (a space before the next dictation), so
    /// they belong to the text before the cursor.
    func interior(value: String, memory: RememberedInsertion) -> (before: String, after: String, how: String)? {
        let ns = value as NSString
        let limit = ns.length > searchLimit ? ns.length - searchLimit : 0
        for prefix in prefixes(memory.tail) {
            var ends: [Int] = []
            var search = NSRange(location: limit, length: ns.length - limit)
            while true {
                let r = ns.range(of: prefix, options: [], range: search)
                if r.location == NSNotFound { break }
                ends.append(r.location + r.length)
                let next = r.location + 1
                if next >= ns.length { break }
                search = NSRange(location: next, length: ns.length - next)
            }
            guard !ends.isEmpty else { continue }
            var end: Int
            var how = ".interior"
            if ends.count == 1 {
                end = ends[0]
            } else {
                guard let target = memory.position?.caretOffset else { return nil }
                let sorted = ends.sorted { abs($0 - target) < abs($1 - target) }
                guard abs(sorted[0] - target) < abs(sorted[1] - target) else { return nil }
                end = sorted[0]
                how = ".interior.nearest"
            }
            if let remembered = memory.position?.valueLength {
                // Characters the user deleted from the end of Susurro's text
                // (a full stop) are already missing from the anchor.
                let deleted = (memory.tail as NSString).length - (prefix as NSString).length
                let grown = ns.length - (remembered - deleted)
                if grown > 0, grown <= maxUserEdit, end + grown <= ns.length {
                    let typed = ns.substring(with: NSRange(location: end, length: grown))
                    if typed.allSatisfy(\.isWhitespace) { end += grown }
                }
            }
            return (ns.substring(to: end), ns.substring(from: end), how)
        }
        return nil
    }
}

/// Last resort: what Susurro itself last typed into this same app — only
/// when the app exposes no readable value. When a value is readable and the
/// anchored-value provider could not place the cursor after Susurro's text,
/// the value is evidence the memory is stale (the user cleared the line, ran
/// the command, or new output arrived — BEA-673, Warp), so the memory is not
/// trusted and the empty-field policy applies (no space, capitalise).
public struct MemoryProvider: ContextProvider {
    public let name = "memory"
    public init() {}
    public func context(_ s: FieldSnapshot, memory: RememberedInsertion?) -> ProvidedContext? {
        guard let memory else { return nil }
        if let value = s.value, !value.isEmpty { return nil }
        return ProvidedContext(before: memory.tail, after: nil, source: .selfTracked, provider: name)
    }
}

public extension InsertContext {
    static let standardProviders: [any ContextProvider] = [
        AppBridgeProvider(), SelectionRangeProvider(), EmptyValueProvider(), TextMarkerProvider(),
        AnchoredValueProvider(), MemoryProvider(),
    ]

    /// Runs the providers in order; the first answer wins. Secure input or a
    /// secure field yields no context at all; no answer = unknown, which the
    /// stage treats as an empty field.
    static func resolve(snapshot: FieldSnapshot?, memoryTail: String?,
                        pid: pid_t?, bundleID: String?, engine: EngineKind?, secureInput: Bool,
                        providers: [any ContextProvider] = standardProviders) -> (InsertContext, String) {
        resolve(snapshot: snapshot, memory: memoryTail.map { RememberedInsertion(tail: $0) },
                pid: pid, bundleID: bundleID, engine: engine, secureInput: secureInput, providers: providers)
    }

    static func resolve(snapshot: FieldSnapshot?, memory: RememberedInsertion?,
                        pid: pid_t?, bundleID: String?, engine: EngineKind?, secureInput: Bool,
                        providers: [any ContextProvider] = standardProviders) -> (InsertContext, String) {
        let secure = secureInput || (snapshot?.secure ?? false)
        if secure {
            return (InsertContext(before: nil, source: .none, pid: pid, bundleID: bundleID,
                                  engine: engine, secureInput: true), "secure")
        }
        let snap = (snapshot ?? .nothing).sanitized
        for provider in providers {
            if let found = provider.context(snap, memory: memory) {
                return (InsertContext(before: found.before, after: found.after, source: found.source,
                                      pid: pid, bundleID: bundleID, engine: engine, secureInput: false),
                        found.provider)
            }
        }
        return (InsertContext(before: nil, source: .none, pid: pid, bundleID: bundleID,
                              engine: engine, secureInput: false), "none")
    }
}
