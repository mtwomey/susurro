import Foundation

/// The one list of compiled-in bridges (docs/BRIDGES.md). Adding a bridge:
/// one file under Bridges/ plus one line in `standard`. Whether latch may
/// engage is decided separately by `LatchAllowlist` (policy). Lookups are
/// dictionaries built once, so apps without a bridge cost one lookup.
public struct BridgeRegistry: Sendable {
    public static let standard = BridgeRegistry([
        EmacsBridge(),
        ObsidianBridge(),
        AXSelectedTextBridge(),
    ])

    private let contextByBundle: [String: any ContextReadingBridge]
    private let latchByID: [BridgeID: any LatchingBridge]

    public init(_ bridges: [any AppBridge]) {
        var context: [String: any ContextReadingBridge] = [:]
        var latch: [BridgeID: any LatchingBridge] = [:]
        for bridge in bridges {
            if let reader = bridge as? any ContextReadingBridge {
                for bundleID in reader.bundleIDs where context[bundleID] == nil { context[bundleID] = reader }
            }
            if let latching = bridge as? any LatchingBridge, latch[latching.id] == nil {
                latch[latching.id] = latching
            }
        }
        contextByBundle = context
        latchByID = latch
    }

    public func contextReader(for bundleID: String?) -> (any ContextReadingBridge)? {
        bundleID.flatMap { contextByBundle[$0] }
    }

    public func latchBridge(_ id: BridgeID) -> (any LatchingBridge)? { latchByID[id] }
}
