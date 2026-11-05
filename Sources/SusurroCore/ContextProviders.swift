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

    public init(value: String? = nil, selection: NSRange? = nil, markerBefore: String? = nil,
                role: String? = nil, secure: Bool = false) {
        self.value = value
        self.selection = selection
        self.markerBefore = markerBefore
        self.role = role
        self.secure = secure
    }

    public static let secureField = FieldSnapshot(secure: true)
    /// Nothing focused, or the read timed out.
    public static let nothing = FieldSnapshot()

    /// Shape summary for the coverage log: lengths and positions only.
    public var detail: String {
        if secure { return "secure" }
        var parts = ["role=\(role ?? "?")"]
        if let value { parts.append("valueLen=\((value as NSString).length)") }
        if let selection { parts.append("caret=\(selection.location)") }
        if let markerBefore { parts.append("markerLen=\(markerBefore.count)") }
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
    /// `memoryTail` is what Susurro last typed into this same app (nil if
    /// nothing, or another app since).
    func context(_ snapshot: FieldSnapshot, memoryTail: String?) -> ProvidedContext?
}

/// Value + selection: the standard Cocoa contract. A caret past the end of
/// the reported value means whitespace the value doesn't show (Gecko drops a
/// trailing typed space from contenteditable values).
public struct SelectionRangeProvider: ContextProvider {
    public let name = "selectionRange"
    public init() {}
    public func context(_ s: FieldSnapshot, memoryTail: String?) -> ProvidedContext? {
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
    public func context(_ s: FieldSnapshot, memoryTail: String?) -> ProvidedContext? {
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
    public func context(_ s: FieldSnapshot, memoryTail: String?) -> ProvidedContext? {
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

    public func context(_ s: FieldSnapshot, memoryTail: String?) -> ProvidedContext? {
        guard let value = s.value, !value.isEmpty, let memoryTail, !memoryTail.isEmpty else { return nil }
        if let before = endAnchored(value: value, tail: memoryTail) {
            return ProvidedContext(before: before, after: nil, source: .anchoredValue, provider: name + ".end")
        }
        if let (before, after) = uniqueInterior(value: value, tail: memoryTail) {
            return ProvidedContext(before: before, after: after, source: .anchoredValue, provider: name + ".interior")
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

    func uniqueInterior(value: String, tail: String) -> (String, String)? {
        let haystack = value.count > searchLimit ? String(value.suffix(searchLimit)) : value
        for prefix in prefixes(tail) {
            guard let first = haystack.range(of: prefix) else { continue }
            if haystack.range(of: prefix, range: haystack.index(after: first.lowerBound)..<haystack.endIndex) != nil {
                return nil   // ambiguous: don't guess
            }
            return (String(haystack[..<first.upperBound]), String(haystack[first.upperBound...]))
        }
        return nil
    }
}

/// Last resort: what Susurro itself last typed into this same app.
public struct MemoryProvider: ContextProvider {
    public let name = "memory"
    public init() {}
    public func context(_ s: FieldSnapshot, memoryTail: String?) -> ProvidedContext? {
        guard let memoryTail else { return nil }
        return ProvidedContext(before: memoryTail, after: nil, source: .selfTracked, provider: name)
    }
}

public extension InsertContext {
    static let standardProviders: [any ContextProvider] = [
        SelectionRangeProvider(), EmptyValueProvider(), TextMarkerProvider(),
        AnchoredValueProvider(), MemoryProvider(),
    ]

    /// Runs the providers in order; the first answer wins. Secure input or a
    /// secure field yields no context at all; no answer = unknown, which the
    /// stage treats as an empty field.
    static func resolve(snapshot: FieldSnapshot?, memoryTail: String?,
                        pid: pid_t?, bundleID: String?, engine: EngineKind?, secureInput: Bool,
                        providers: [any ContextProvider] = standardProviders) -> (InsertContext, String) {
        let secure = secureInput || (snapshot?.secure ?? false)
        if secure {
            return (InsertContext(before: nil, source: .none, pid: pid, bundleID: bundleID,
                                  engine: engine, secureInput: true), "secure")
        }
        let snap = snapshot ?? .nothing
        for provider in providers {
            if let found = provider.context(snap, memoryTail: memoryTail) {
                return (InsertContext(before: found.before, after: found.after, source: found.source,
                                      pid: pid, bundleID: bundleID, engine: engine, secureInput: false),
                        found.provider)
            }
        }
        return (InsertContext(before: nil, source: .none, pid: pid, bundleID: bundleID,
                              engine: engine, secureInput: false), "none")
    }
}
