import Foundation

/// One typed façade over Susurro's UserDefaults keys (review F9 / R4).
///
/// The key strings are the persisted names and must never change — existing
/// installs read them as-is, so this façade is migration-free. Inject a
/// scratch `UserDefaults(suiteName:)` in tests.
public struct Settings: @unchecked Sendable {
    /// Persisted key names. Changing any of these strands users' settings.
    public enum Key {
        public static let llmCleanupEnabled = "llmCleanupEnabled"
        public static let copyToClipboard = "copyToClipboard"
        public static let smartSpacingEnabled = "smartSpacingEnabled"
        public static let devFeedHook = "DevFeedHook"
        public static let pttKeyID = "pttKeyID"
        public static let latchKeyID = "latchKeyID"
        /// Owned by `ModelManager` (it keeps its own accessor); listed here so
        /// the whole defaults domain is visible in one place.
        public static let activeModelID = "activeModelID"
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// LLM cleanup of transcripts. Default off.
    public var llmCleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.llmCleanupEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.llmCleanupEnabled) }
    }

    /// Also leave each dictation on the clipboard. Default off.
    public var copyToClipboard: Bool {
        get { defaults.bool(forKey: Key.copyToClipboard) }
        nonmutating set { defaults.set(newValue, forKey: Key.copyToClipboard) }
    }

    /// Smart spacing / capitalisation against the focused field. Default off.
    public var smartSpacingEnabled: Bool {
        get { defaults.bool(forKey: Key.smartSpacingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.smartSpacingEnabled) }
    }

    /// Developer-only feed hook (no UI). Default off.
    public var devFeedHook: Bool {
        defaults.bool(forKey: Key.devFeedHook)
    }

    /// Saved push-to-talk key id, nil when never chosen.
    public var pttKeyID: String? {
        get { defaults.string(forKey: Key.pttKeyID) }
        nonmutating set { defaults.set(newValue, forKey: Key.pttKeyID) }
    }

    /// Saved hands-free latch key id, nil when never chosen.
    public var latchKeyID: String? {
        get { defaults.string(forKey: Key.latchKeyID) }
        nonmutating set { defaults.set(newValue, forKey: Key.latchKeyID) }
    }
}

/// The code-default tuning constants in one place (review F9 / R4). Values are
/// exactly the previous literals; nothing reads them from defaults yet.
public struct Tuning: Sendable, Equatable {
    /// Hands-free pause segmentation.
    public var segmenter = PauseSegmenter.Config()
    /// Hands-free session limits (seconds).
    public var handsFreeSafetyLimit: Double = 7_200
    public var handsFreeIdleLimit: Double = 60
    public var handsFreeWarningLead: Double = 10
    /// Cap on the focused-field Accessibility read during transcription.
    public var axReadCap: Duration = .milliseconds(250)
    /// Per-element AX messaging timeout (seconds).
    public var axMessagingTimeout: Float = 0.2
    /// Model loads slower than this show the "loading model" status.
    public var slowLoadThreshold: TimeInterval = 1.5

    public init() {}

    public static let `default` = Tuning()

    public func makeHandsFreeMachine() -> HandsFreeMachine {
        HandsFreeMachine(safetyLimit: handsFreeSafetyLimit,
                         idleLimit: handsFreeIdleLimit,
                         warningLead: handsFreeWarningLead)
    }

    public func makeSegmenter() -> PauseSegmenter {
        PauseSegmenter(config: segmenter)
    }
}
