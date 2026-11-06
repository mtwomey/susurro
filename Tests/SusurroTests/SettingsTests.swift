import Foundation
import Testing
@testable import SusurroCore

@Suite final class SettingsTests {
    private let suite = "susurro.settings.test.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }

    /// The persisted key names are the migration contract: existing installs
    /// read these exact strings.
    @Test func testKeyNamesUnchanged() {
        #expect(Settings.Key.llmCleanupEnabled == "llmCleanupEnabled")
        #expect(Settings.Key.copyToClipboard == "copyToClipboard")
        #expect(Settings.Key.smartSpacingEnabled == "smartSpacingEnabled")
        #expect(Settings.Key.devFeedHook == "DevFeedHook")
        #expect(Settings.Key.pttKeyID == "pttKeyID")
        #expect(Settings.Key.latchKeyID == "latchKeyID")
        #expect(Settings.Key.activeModelID == "activeModelID")
    }

    @Test func testDefaultsOffAndNil() {
        let s = Settings(defaults: defaults)
        #expect(!s.llmCleanupEnabled)
        #expect(!s.copyToClipboard)
        #expect(!s.smartSpacingEnabled)
        #expect(!s.devFeedHook)
        #expect(s.pttKeyID == nil)
        #expect(s.latchKeyID == nil)
    }

    /// Values written by the old ad-hoc accessors are read back, and the
    /// façade writes under the same raw keys.
    @Test func testReadsAndWritesRawKeys() {
        defaults.set(true, forKey: "llmCleanupEnabled")
        defaults.set("rightCommand", forKey: "pttKeyID")
        defaults.set(true, forKey: "DevFeedHook")
        let s = Settings(defaults: defaults)
        #expect(s.llmCleanupEnabled)
        #expect(s.pttKeyID == "rightCommand")
        #expect(s.devFeedHook)
        s.copyToClipboard = true
        s.smartSpacingEnabled = true
        s.latchKeyID = "rightControl"
        #expect(defaults.bool(forKey: "copyToClipboard"))
        #expect(defaults.bool(forKey: "smartSpacingEnabled"))
        #expect(defaults.string(forKey: "latchKeyID") == "rightControl")
    }

    /// Tuning carries exactly the previous code defaults.
    @Test func testTuningDefaultsUnchanged() {
        let t = Tuning.default
        #expect(t.segmenter == PauseSegmenter.Config())
        #expect(t.segmenter.minPause == 1.0)
        #expect(t.segmenter.maxSegment == 25)
        #expect(t.handsFreeSafetyLimit == 7_200)
        #expect(t.handsFreeIdleLimit == 60)
        #expect(t.handsFreeWarningLead == 10)
        #expect(t.axReadCap == .milliseconds(250))
        #expect(t.axMessagingTimeout == 0.2)
        #expect(t.slowLoadThreshold == 1.5)
        let m = t.makeHandsFreeMachine(), d = HandsFreeMachine()
        #expect(m.safetyLimit == d.safetyLimit)
        #expect(m.idleLimit == d.idleLimit)
        #expect(m.warningLead == d.warningLead)
    }
}
