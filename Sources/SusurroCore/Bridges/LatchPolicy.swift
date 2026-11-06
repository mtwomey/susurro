import Foundation

/// Why latch did not engage, typed so every path (and its pill) is tested.
public enum LatchRefusal: Error, Sendable, Equatable {
    /// Not on the allowlist (policy): every app without full support.
    case notAllowlisted
    /// Allowlisted, but this build has no such bridge (e.g. a remote list
    /// naming a newer bridge).
    case bridgeMissing(BridgeID)
    /// The bridge could not pin; `pill` is its specific message, if any.
    case bridgeFailed(BridgeError, pill: String?)

    public func pill(appName: String) -> String {
        if case .bridgeFailed(_, let pill?) = self { return pill }
        return LatchDelivery.notSupportedPill(appName: appName)
    }
}

/// The engage decision (docs/BRIDGES.md): policy first (allowlist), then
/// mechanism (registered bridge, its own checks, the pin). Blocking: the
/// bridge talks to the app. Never call on the main thread.
public enum LatchPolicy {
    public static func engage(_ request: LatchPinRequest,
                              allowlist: LatchAllowlist = .bundled,
                              registry: BridgeRegistry = .standard) -> Result<any LatchTarget, LatchRefusal> {
        guard let id = allowlist.method(for: request.bundleID) else { return .failure(.notAllowlisted) }
        guard let bridge = registry.latchBridge(id) else { return .failure(.bridgeMissing(id)) }
        do {
            return .success(try bridge.pin(request))
        } catch {
            return .failure(.bridgeFailed(error, pill: bridge.refusalPill(for: error)))
        }
    }
}
