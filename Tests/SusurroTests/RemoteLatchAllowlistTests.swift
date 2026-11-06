import CryptoKit
import Foundation
import Testing
@testable import SusurroCore

/// BEA-692: signed remote capability list layered over the bundled allowlist.
@Suite struct RemoteLatchAllowlistTests {
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var keys: [String: Curve25519.Signing.PublicKey] { ["k1": key.publicKey] }

    func envelope(_ doc: RemoteLatchAllowlist.Document, keyID: String = "k1",
                  signer: Curve25519.Signing.PrivateKey? = nil, tamper: Bool = false) throws -> Data {
        var payload = try RemoteLatchAllowlist.encoder().encode(doc)
        let signature = try (signer ?? key).signature(for: payload)
        if tamper { payload = try RemoteLatchAllowlist.encoder().encode(
            RemoteLatchAllowlist.Document(serial: doc.serial, expires: doc.expires, entries: [])) }
        return try RemoteLatchAllowlist.encoder().encode(
            RemoteLatchAllowlist.Envelope(keyID: keyID, payload: payload, signature: signature))
    }

    func doc(serial: Int = 1, expiresIn: TimeInterval = 86_400,
             _ entries: [RemoteLatchAllowlist.Entry]) -> RemoteLatchAllowlist.Document {
        RemoteLatchAllowlist.Document(serial: serial, expires: now.addingTimeInterval(expiresIn), entries: entries)
    }

    let textEdit = RemoteLatchAllowlist.Entry(bundleID: "com.apple.TextEdit", method: .axSelectedText,
                                              minAppVersion: [1, 19])

    @Test func thisBuildTrustsNoKeySoTheLayerIsInert() throws {
        #expect(RemoteLatchAllowlist.trustedKeys.isEmpty)
        let data = try envelope(doc([textEdit]))
        let r = RemoteLatchAllowlist.resolve(fetched: data, cached: data, now: now)
        #expect(r.source == .bundled)
        #expect(r.allowlist == .bundled)
        #expect(r.rejections == [.unknownKey("k1"), .unknownKey("k1")])
    }

    @Test func verifiedFetchAddsAndIsCached() throws {
        let data = try envelope(doc([textEdit]))
        let r = RemoteLatchAllowlist.resolve(fetched: data, cached: nil, trustedKeys: keys, now: now)
        #expect(r.source == .fetched)
        #expect(r.toCache == data)
        #expect(r.serialFloor == 1)
        #expect(r.allowlist.method(for: "com.apple.TextEdit") == .axSelectedText)
        #expect(r.allowlist.method(for: EmacsBridgeInfo.bundleID) == .emacsServer)
    }

    @Test func nilMethodRemovesABundledEntry() throws {
        let off = RemoteLatchAllowlist.Entry(bundleID: ObsidianLatchJS.bundleID, method: nil)
        let merged = RemoteLatchAllowlist.merge(doc([off]), over: .bundled)
        #expect(merged.method(for: ObsidianLatchJS.bundleID) == nil)
        #expect(merged.method(for: EmacsBridgeInfo.bundleID) == .emacsServer)
    }

    @Test(arguments: ["badSignature", "tampered", "unknownKey", "expired", "schema", "garbage"])
    func rejectedFetchFallsBackToBundled(_ kind: String) throws {
        let other = Curve25519.Signing.PrivateKey()
        let data: Data
        let expected: RemoteLatchAllowlist.Rejection
        switch kind {
        case "badSignature": data = try envelope(doc([textEdit]), signer: other); expected = .badSignature
        case "tampered": data = try envelope(doc([textEdit]), tamper: true); expected = .badSignature
        case "unknownKey": data = try envelope(doc([textEdit]), keyID: "k9"); expected = .unknownKey("k9")
        case "expired": data = try envelope(doc(expiresIn: -1, [textEdit])); expected = .expired
        case "schema":
            data = try envelope(RemoteLatchAllowlist.Document(schema: 2, serial: 1, expires: now + 60, entries: []))
            expected = .unsupportedSchema(2)
        default: data = Data("not json".utf8); expected = .malformed
        }
        let r = RemoteLatchAllowlist.resolve(fetched: data, cached: nil, trustedKeys: keys, now: now)
        #expect(r.source == .bundled)
        #expect(r.allowlist == .bundled)
        #expect(r.toCache == nil)
        #expect(r.rejections == [expected])
    }

    @Test func offlineUsesVerifiedCacheUntilItExpires() throws {
        let cached = try envelope(doc(serial: 3, expiresIn: 3600, [textEdit]))
        let r = RemoteLatchAllowlist.resolve(fetched: nil, cached: cached, trustedKeys: keys, now: now)
        #expect(r.source == .cached)
        #expect(r.toCache == nil)
        #expect(r.allowlist.method(for: "com.apple.TextEdit") == .axSelectedText)
        let later = RemoteLatchAllowlist.resolve(fetched: nil, cached: cached, trustedKeys: keys,
                                                 now: now.addingTimeInterval(7200))
        #expect(later.source == .bundled)
        #expect(later.rejections == [.expired])
    }

    @Test func olderFetchCannotRollBackTheCache() throws {
        let cached = try envelope(doc(serial: 5, [textEdit]))
        let older = try envelope(doc(serial: 4, []))
        let r = RemoteLatchAllowlist.resolve(fetched: older, cached: cached, trustedKeys: keys, now: now)
        #expect(r.source == .cached)
        #expect(r.rejections == [.rollback(serial: 4, minimum: 5)])
        // Persisted floor also blocks an older cache file.
        let r2 = RemoteLatchAllowlist.resolve(fetched: nil, cached: older, serialFloor: 5, trustedKeys: keys, now: now)
        #expect(r2.source == .bundled)
    }

    @Test func cacheRoundTripsBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RemoteLatchAllowlistCache(fileURL: dir.appendingPathComponent("latch.json"))
        #expect(cache.read() == nil)
        let data = try envelope(doc([textEdit]))
        try cache.write(data)
        #expect(cache.read() == data)
    }

    @Test func bundledEntriesDecodeWithoutMinAppVersion() throws {
        let json = Data(#"{"bundleID":"x","method":"emacsServer"}"#.utf8)
        let c = try JSONDecoder().decode(LatchCapability.self, from: json)
        #expect(c.minAppVersion == nil)
        #expect(c.admits(appVersion: nil))
    }

    @Test func minAppVersionGatesEngageFullSupportOrNothing() {
        let c = LatchCapability(bundleID: "x", method: .axSelectedText, minAppVersion: [1, 19])
        #expect(c.admits(appVersion: [1, 19]))
        #expect(c.admits(appVersion: [1, 19, 1]))
        #expect(c.admits(appVersion: [2]))
        #expect(!c.admits(appVersion: [1, 18, 9]))
        #expect(!c.admits(appVersion: nil))
        #expect(LatchAllowlist.parseVersion("1.14.5") == [1, 14, 5])
        #expect(LatchAllowlist.parseVersion("1.2b") == nil)
        #expect(LatchAllowlist.parseVersion(nil) == nil)
    }

    @Test func engageRefusesTooOldAppBeforeTouchingTheBridge() {
        let list = LatchAllowlist(entries: [LatchCapability(bundleID: "x", method: .emacsServer, minAppVersion: [30])])
        let request = LatchPinRequest(pid: 1, bundleID: "x", appName: "Emacs", token: 1, appVersion: [29, 4])
        let result = LatchPolicy.engage(request, allowlist: list, registry: BridgeRegistry([]))
        guard case .failure(let refusal) = result else { Issue.record("engaged"); return }
        #expect(refusal == .appVersionTooOld(minimum: [30]))
        #expect(refusal.pill(appName: "Emacs") == "Latching needs Emacs 30 or later")
        // Version OK: the policy moves on to the registry (empty here).
        let ok = LatchPinRequest(pid: 1, bundleID: "x", appName: "Emacs", token: 1, appVersion: [30, 1])
        guard case .failure(let r2) = LatchPolicy.engage(ok, allowlist: list, registry: BridgeRegistry([])) else { return }
        #expect(r2 == .bridgeMissing(.emacsServer))
    }
}
