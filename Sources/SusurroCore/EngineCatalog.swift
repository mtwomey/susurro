import Foundation

// The engine catalog (review F6/R6): the one file that says which engines
// exist and what each can do. Everything else asks an engine's
// `capabilities` / `descriptor` instead of comparing `EngineKind` values.
// Adding an engine: see "Adding an engine" in docs/ARCHITECTURE.md.

/// Which engine a catalog entry runs on, and therefore what its on-disk
/// artifact looks like. Declaration order is the Model menu's section order
/// and the order `kind(ofPath:)` searches.
public enum EngineKind: String, Sendable, Equatable, CaseIterable {
    /// whisper.cpp: a single ggml `.bin` file.
    case whisper
    /// FluidAudio Parakeet TDT: a directory of Core ML `.mlmodelc` bundles
    /// plus a vocabulary file. Apple Silicon only.
    case parakeet

    /// Everything engine-specific the app, CLI and model manager need.
    public var descriptor: EngineDescriptor {
        switch self {
        case .whisper:
            EngineDescriptor(
                menuSectionTitle: "Whisper (whisper.cpp)",
                capabilities: EngineCapabilities(
                    artifact: .file, requiresAppleSilicon: false,
                    emitsPunctuation: true, doesITN: false, supportsPrompt: true,
                    streaming: false, emitsBracketTokens: true),
                defaultModelID: "small.en",
                extraLookupPaths: [],
                load: { path in try WhisperEngine(modelPath: path) })
        case .parakeet:
            EngineDescriptor(
                menuSectionTitle: "NVIDIA Parakeet (Apple Silicon)",
                capabilities: EngineCapabilities(
                    artifact: .directory, requiresAppleSilicon: true,
                    emitsPunctuation: true, doesITN: true, supportsPrompt: false,
                    streaming: false, emitsBracketTokens: false),
                defaultModelID: "parakeet-tdt-v2",
                // FluidAudio's own cache (BEA-632 spike) — handy on dev machines.
                extraLookupPaths: ["FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml"],
                load: { path in try ParakeetEngine(modelDirectory: URL(fileURLWithPath: path, isDirectory: true)) })
        }
    }

    public var capabilities: EngineCapabilities { descriptor.capabilities }

    /// Section header for this engine's group in the Model menu (and the
    /// Help window's description of it).
    public var menuSectionTitle: String { descriptor.menuSectionTitle }
}

/// What an engine's output and artifact look like, so callers branch on a
/// property rather than on which engine it is.
public struct EngineCapabilities: Sendable, Equatable {
    /// On-disk shape of a model: one file, or a directory of entries.
    public enum Artifact: Sendable, Equatable { case file, directory }

    public var artifact: Artifact
    /// Core ML / ANE engines: hidden from the catalog on Intel Macs.
    public var requiresAppleSilicon: Bool
    /// Output carries its own punctuation and sentence casing.
    public var emitsPunctuation: Bool
    /// Engine does inverse text normalisation (numbers, currency, times).
    public var doesITN: Bool
    /// Accepts a vocabulary / initial prompt.
    public var supportsPrompt: Bool
    /// Can emit partial results while audio is still arriving.
    public var streaming: Bool
    /// Emits whisper-style non-speech tokens ("[BLANK_AUDIO]") that
    /// `TranscriptFilter` must strip; otherwise brackets are kept as text.
    public var emitsBracketTokens: Bool

    public init(artifact: Artifact, requiresAppleSilicon: Bool, emitsPunctuation: Bool,
                doesITN: Bool, supportsPrompt: Bool, streaming: Bool, emitsBracketTokens: Bool) {
        self.artifact = artifact
        self.requiresAppleSilicon = requiresAppleSilicon
        self.emitsPunctuation = emitsPunctuation
        self.doesITN = doesITN
        self.supportsPrompt = supportsPrompt
        self.streaming = streaming
        self.emitsBracketTokens = emitsBracketTokens
    }
}

/// One engine's catalog row: capabilities, UI text, CLI defaults and loader.
public struct EngineDescriptor: Sendable {
    public let menuSectionTitle: String
    public let capabilities: EngineCapabilities
    /// Catalog model the CLI's `--engine <kind>` uses when no `--model` is given.
    public let defaultModelID: String
    /// Extra places (relative to Application Support) the CLI looks for that
    /// model after Susurro's own models directory.
    public let extraLookupPaths: [String]
    /// Warm-loads the engine from a model path (file or directory).
    public let load: @Sendable (String) throws -> any TranscriptionEngine
}
