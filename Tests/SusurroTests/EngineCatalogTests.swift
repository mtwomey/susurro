import Foundation
import Testing
@testable import SusurroCore

/// Review R6: engine-specific behaviour comes from `EngineCapabilities`, and
/// the catalog descriptor is the one place each engine is described.
@Suite struct EngineCatalogTests {
    @Test @MainActor func descriptorsAgreeWithModelCatalog() {
        for kind in EngineKind.allCases {
            let model = ModelManager.model(id: kind.descriptor.defaultModelID)
            #expect(model?.engine == kind)
            #expect(model?.isDirectory == (kind.capabilities.artifact == .directory))
        }
        #expect(EngineKind.whisper.descriptor.defaultModelID == ModelManager.defaultModelID)
        #expect(EngineKind.parakeet.descriptor.defaultModelID == ModelManager.parakeetV2ID)
        #expect(EngineKind.parakeet.descriptor.extraLookupPaths
            == ["FluidAudio/Models/\(ModelManager.parakeetV2DirectoryName)"])
        #expect(EngineKind.whisper.descriptor.extraLookupPaths.isEmpty)
    }

    @Test func capabilitiesPerEngine() {
        #expect(EngineKind.whisper.capabilities.emitsBracketTokens)
        #expect(!EngineKind.parakeet.capabilities.emitsBracketTokens)
        #expect(EngineKind.parakeet.capabilities.doesITN)
        #expect(!EngineKind.parakeet.capabilities.supportsPrompt)
        #expect(EngineKind.parakeet.capabilities.requiresAppleSilicon)
        #expect(!EngineKind.whisper.capabilities.requiresAppleSilicon)
        #expect(EngineKind.allCases.allSatisfy { !$0.capabilities.streaming })
        #expect(EngineKind.whisper.menuSectionTitle == "Whisper (whisper.cpp)")
        #expect(EngineKind.parakeet.menuSectionTitle == "NVIDIA Parakeet (Apple Silicon)")
    }

    /// The filter depends only on capabilities: each engine's kind-based call
    /// equals the capability-based one, and the bracket rule follows the flag.
    @Test(arguments: EngineKind.allCases)
    func filterFollowsCapabilities(kind: EngineKind) {
        let caps = kind.capabilities
        for raw in ["hi [MUSIC] there", "Use arr [0] here", "  Hello   world. ", "[BLANK_AUDIO]"] {
            #expect(TranscriptFilter.stripHallucinations(raw, engine: kind)
                == TranscriptFilter.stripHallucinations(raw, capabilities: caps))
        }
        let out = TranscriptFilter.stripHallucinations("hi [MUSIC] there", capabilities: caps)
        #expect(out == (caps.emitsBracketTokens ? "hi there" : "hi [MUSIC] there"))
        #expect(TranscriptFilter.stripHallucinations("  Hello   world. ", capabilities: caps) == "Hello world.")
    }

    @Test(arguments: [true, false])
    func bracketFlagAloneDrivesTheStrip(flag: Bool) {
        var caps = EngineKind.parakeet.capabilities
        caps.emitsBracketTokens = flag
        #expect(TranscriptFilter.stripHallucinations("a [x] b", capabilities: caps) == (flag ? "a b" : "a [x] b"))
    }
}
