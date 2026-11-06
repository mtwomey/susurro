import Testing
@testable import SusurroCore

@Suite struct LatchTokenTests {
    @Test func tokensShareTheLaunchPrefixAndAreUnique() {
        let a = LatchToken.next(), b = LatchToken.next()
        #expect(a != b)
        #expect(LatchToken.nonce(of: a) == LatchToken.nonce && LatchToken.nonce(of: b) == LatchToken.nonce)
        #expect(String(a).hasPrefix(String(LatchToken.nonce)) && String(a).count == 9)
        #expect(LatchToken.make(nonce: 123, counter: 4) == 123_000_004)
    }

    @Test func pinsSweepOtherLaunches() {
        let token = LatchToken.make(nonce: 456, counter: 1)
        #expect(EmacsLatchLisp.pin(id: token).contains(#"(not (string-prefix-p "susurro--latch-456" n))"#))
        #expect(ObsidianLatchJS.pin(id: token).contains("if(!k.startsWith('456'))delete S[k];"))
        #expect(ObsidianLatchJS.pin(id: token).contains("delete c.update"))
    }

    @Test func versionCacheSkipsFailuresAndCachesSuccess() {
        let cache = ObsidianBridge.VersionCache()
        var calls = 0
        #expect(cache.version(pid: 1) { calls += 1; return nil } == nil)
        #expect(cache.version(pid: 1) { calls += 1; return [1, 14, 5] } == [1, 14, 5])
        #expect(cache.version(pid: 1) { calls += 1; return [9] } == [1, 14, 5])
        #expect(calls == 2)
    }
}
