import Foundation

/// Obsidian through its official CLI (`obsidian eval`). Each call spawns the
/// CLI (~60 ms `version`, ~150 ms eval measured) with arguments passed
/// directly (no shell). The socket (`~/.obsidian-cli.sock`) is not used: its
/// protocol is undocumented. Latch only; the context read for ordinary
/// dictation stays on Accessibility.
public struct ObsidianBridge: LatchingBridge {
    public let id = BridgeID.obsidianCLI
    public let bundleIDs: Set<String> = [ObsidianLatchJS.bundleID]
    public let documentNoun = "note"
    public var cli = ObsidianCLI()

    public init() {}

    public func pin(_ request: LatchPinRequest) throws(BridgeError) -> any LatchTarget {
        guard let version = cli.appVersion() else { throw .notEnabled }
        guard ObsidianLatchJS.supported(version) else {
            throw .unsupportedVersion(found: version, minimum: ObsidianLatchJS.minimumVersion)
        }
        guard let reply = cli.eval(ObsidianLatchJS.pin(id: request.token)) else { throw .notRunning }
        guard reply.ok == true else { throw .noTarget }   // not a markdown editor leaf
        let pin = LatchPin(method: id, bundleID: request.bundleID, appName: request.appName,
                           documentName: reply.name ?? "note", handle: reply.path ?? "", documentNoun: documentNoun)
        return ObsidianLatchTarget(pin: pin, cli: cli, token: request.token)
    }

    public func refusalPill(for error: BridgeError) -> String? {
        switch error {
        case .notEnabled: return ObsidianLatchJS.cliOffPill
        case .unsupportedVersion: return ObsidianLatchJS.versionPill
        default: return nil
        }
    }
}

/// The Obsidian CLI, through the shared process transport.
public struct ObsidianCLI: Sendable {
    public var path = "/usr/local/bin/obsidian"
    public var timeout: TimeInterval = 3

    public init() {}

    /// stdout only: CLI diagnostics on stderr must never be parsed as a reply.
    public func run(_ args: [String]) -> String? {
        ProcessRunner().run(path, args, timeout: timeout)?.stdout
    }

    public func eval(_ js: String) -> ObsidianLatchJS.Reply? {
        run(["eval", "code=" + js]).flatMap(ObsidianLatchJS.decode)
    }

    /// The app version from the CLI (not the bundle short version); nil
    /// when the CLI is missing or disabled.
    public func appVersion() -> [Int]? { run(["version"]).flatMap(ObsidianLatchJS.appVersion) }
}

/// A latched Obsidian markdown leaf; the pin offset is mapped through the
/// user's edits inside Obsidian (see ObsidianLatchJS).
public final class ObsidianLatchTarget: LatchTarget {
    public let pin: LatchPin
    private let cli: ObsidianCLI
    private let token: Int

    init(pin: LatchPin, cli: ObsidianCLI, token: Int) {
        self.pin = pin
        self.cli = cli
        self.token = token
    }

    private static func map(_ reply: ObsidianLatchJS.Reply?, _ value: (ObsidianLatchJS.Reply) -> String?) -> LatchBridgeReply {
        guard let reply else { return .unavailable }
        if reply.gone == true { return .gone }
        return value(reply).map { .value($0) } ?? .unavailable
    }

    public func context() -> LatchBridgeReply { Self.map(cli.eval(ObsidianLatchJS.context(id: token))) { $0.ctx } }
    public func insert(_ text: String) -> LatchBridgeReply {
        Self.map(cli.eval(ObsidianLatchJS.insert(id: token, text: text))) { $0.back }
    }
    public func release() { _ = cli.eval(ObsidianLatchJS.release(id: token)) }
}
