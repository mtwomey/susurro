import CryptoKit
import Foundation

// BEA-692: a signed, remote latch capability list layered over
// `LatchAllowlist.bundled`. Pure and offline: this file verifies, merges and
// caches a list; it never fetches. Hosting is an open decision, and this
// build trusts no signing key (`trustedKeys` is empty), so every remote or
// cached list is rejected and the bundled allowlist stays in force. The
// layer switches on only when a key and a URL ship in a reviewed build.
// Format and rules: docs/BRIDGES.md "Remote capability list".

public enum RemoteLatchAllowlist {
    /// Signing keys this build trusts, by key id. Empty on purpose (open
    /// decision: hosting and key custody); see the doc comment above.
    public static let trustedKeys: [String: Curve25519.Signing.PublicKey] = [:]

    public static let schema = 1

    /// One remote entry. `method` nil disables the bundle ID (a remote kill
    /// switch for a bundled entry); otherwise it adds or replaces the entry.
    public struct Entry: Codable, Sendable, Equatable {
        public var bundleID: String
        public var method: BridgeID?
        public var minAppVersion: [Int]?
        public init(bundleID: String, method: BridgeID?, minAppVersion: [Int]? = nil) {
            self.bundleID = bundleID
            self.method = method
            self.minAppVersion = minAppVersion
        }
    }

    /// The signed payload. `serial` only ever goes up (anti-rollback);
    /// `expires` bounds how long a cached copy may be used offline.
    public struct Document: Codable, Sendable, Equatable {
        public var schema: Int
        public var serial: Int
        public var expires: Date
        public var entries: [Entry]
        public init(schema: Int = RemoteLatchAllowlist.schema, serial: Int, expires: Date, entries: [Entry]) {
            self.schema = schema
            self.serial = serial
            self.expires = expires
            self.entries = entries
        }
    }

    /// What is hosted and cached: the exact payload bytes plus an Ed25519
    /// signature over them (both base64 in JSON). Verifying the bytes, not a
    /// re-encoding, keeps the signature independent of JSON key order.
    public struct Envelope: Codable, Sendable, Equatable {
        public var keyID: String
        public var payload: Data
        public var signature: Data
        public init(keyID: String, payload: Data, signature: Data) {
            self.keyID = keyID
            self.payload = payload
            self.signature = signature
        }
    }

    public enum Rejection: Error, Sendable, Equatable {
        case malformed
        case unknownKey(String)
        case badSignature
        case unsupportedSchema(Int)
        case expired
        case rollback(serial: Int, minimum: Int)
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// Verify an envelope's bytes: known key, valid signature, supported
    /// schema, not expired, serial not below `minimumSerial`.
    public static func verify(_ data: Data,
                              trustedKeys: [String: Curve25519.Signing.PublicKey] = trustedKeys,
                              now: Date, minimumSerial: Int = 0) -> Result<Document, Rejection> {
        guard let envelope = try? decoder().decode(Envelope.self, from: data) else { return .failure(.malformed) }
        guard let key = trustedKeys[envelope.keyID] else { return .failure(.unknownKey(envelope.keyID)) }
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else { return .failure(.badSignature) }
        guard let doc = try? decoder().decode(Document.self, from: envelope.payload) else { return .failure(.malformed) }
        guard doc.schema == schema else { return .failure(.unsupportedSchema(doc.schema)) }
        guard doc.expires > now else { return .failure(.expired) }
        guard doc.serial >= minimumSerial else { return .failure(.rollback(serial: doc.serial, minimum: minimumSerial)) }
        return .success(doc)
    }

    /// Layer a verified document over `base`: entries are applied in order;
    /// a nil method removes the bundle ID, anything else replaces or adds it.
    /// Latch still engages only where this build has the bridge
    /// (`LatchRefusal.bridgeMissing`), so a remote list cannot widen support
    /// past compiled-in code.
    public static func merge(_ doc: Document, over base: LatchAllowlist) -> LatchAllowlist {
        var entries = base.entries
        for remote in doc.entries {
            entries.removeAll { $0.bundleID == remote.bundleID }
            if let method = remote.method {
                entries.append(LatchCapability(bundleID: remote.bundleID, method: method,
                                               minAppVersion: remote.minAppVersion))
            }
        }
        return LatchAllowlist(entries: entries)
    }

    public enum Source: Sendable, Equatable { case bundled, cached, fetched }

    public struct Resolution: Sendable, Equatable {
        public var allowlist: LatchAllowlist
        public var source: Source
        /// Bytes to write to the cache (a newly verified fetch), else nil.
        public var toCache: Data?
        /// Highest serial accepted so far; persist it as the rollback floor.
        public var serialFloor: Int
        public var rejections: [Rejection]
    }

    /// Pick the allowlist: a verified fresh fetch, else a verified cached
    /// copy, else the bundled list. Any failure falls back, never fails open.
    public static func resolve(bundled: LatchAllowlist = .bundled, fetched: Data?, cached: Data?,
                               serialFloor: Int = 0,
                               trustedKeys: [String: Curve25519.Signing.PublicKey] = trustedKeys,
                               now: Date) -> Resolution {
        var rejections: [Rejection] = []
        var floor = serialFloor
        var cachedDoc: Document?
        if let cached {
            switch verify(cached, trustedKeys: trustedKeys, now: now, minimumSerial: floor) {
            case .success(let doc): cachedDoc = doc; floor = max(floor, doc.serial)
            case .failure(let r): rejections.append(r)
            }
        }
        if let fetched {
            switch verify(fetched, trustedKeys: trustedKeys, now: now, minimumSerial: floor) {
            case .success(let doc):
                return Resolution(allowlist: merge(doc, over: bundled), source: .fetched, toCache: fetched,
                                  serialFloor: max(floor, doc.serial), rejections: rejections)
            case .failure(let r): rejections.append(r)
            }
        }
        if let cachedDoc {
            return Resolution(allowlist: merge(cachedDoc, over: bundled), source: .cached, toCache: nil,
                              serialFloor: floor, rejections: rejections)
        }
        return Resolution(allowlist: bundled, source: .bundled, toCache: nil, serialFloor: floor,
                          rejections: rejections)
    }
}

/// File-backed cache of the last verified envelope. Cached bytes are
/// re-verified on every read (`resolve`), so a tampered file only falls back.
public struct RemoteLatchAllowlistCache: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func read() -> Data? { try? Data(contentsOf: fileURL) }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
