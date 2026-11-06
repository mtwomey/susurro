import Foundation
import Testing
@testable import SusurroCore

/// A one-shot Unix-socket server on a temp path that answers with `reply`.
private final class FakeSocketServer: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private(set) var received = Data()

    init(reply: Data, closeAfter: Bool = true, delay: TimeInterval = 0) {
        path = NSTemporaryDirectory() + "susurro-sock-\(UUID().uuidString.prefix(8))"
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(fd, 1)
        let listener = fd
        Thread.detachNewThread { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1   // the client may have given up: no SIGPIPE
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(client, &buf, buf.count, 0)
            if n > 0 { self.received = Data(buf[0..<n]) }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            if closeAfter { close(client) } else { Thread.sleep(forTimeInterval: 2); close(client) }
        }
    }
    deinit { close(fd); unlink(path) }
}

@Suite struct UnixSocketClientTests {
    @Test func roundTripWithEmacsFraming() {
        let printed = "-print " + EmacsServerProtocol.quote("\"" + Data("héllo".utf8).base64EncodedString() + "\"\n") + "\n"
        let server = FakeSocketServer(reply: Data(printed.utf8), closeAfter: false)
        let client = UnixSocketClient(path: server.path)
        let start = Date()
        let reply = client.request(Data("-eval x\n".utf8), timeout: 1) { data in
            EmacsServerProtocol.printedString(reply: String(decoding: data, as: UTF8.self)) != nil
        }
        // Complete reply detected without waiting for the peer to close.
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(reply.flatMap { EmacsServerProtocol.parse(reply: String(decoding: $0, as: UTF8.self)) } == "héllo")
        #expect(server.received == Data("-eval x\n".utf8))
    }

    @Test func noServerIsNil() {
        #expect(UnixSocketClient(path: "/tmp/susurro-no-such-socket").request(Data("x".utf8), timeout: 0.2) { _ in true } == nil)
    }

    @Test func slowServerHitsDeadline() {
        let server = FakeSocketServer(reply: Data("late".utf8), delay: 1.5)
        let start = Date()
        let reply = UnixSocketClient(path: server.path).request(Data("x".utf8), timeout: 0.3) { _ in true }
        #expect(Date().timeIntervalSince(start) < 1.2)
        #expect(reply == Data())
    }
}

@Suite struct ProcessRunnerTests {
    @Test func separatesStdoutAndStderr() {
        let out = ProcessRunner().run("/bin/sh", ["-c", "echo out; echo '{err}' >&2"], timeout: 5)
        #expect(out == .init(status: 0, stdout: "out\n", stderr: "{err}\n"))
    }

    @Test func argumentsAreNotShellParsed() {
        let out = ProcessRunner().run("/bin/echo", ["code=$(rm -rf /) \"x\""], timeout: 5)
        #expect(out?.stdout == "code=$(rm -rf /) \"x\"\n")
    }

    @Test func timeoutKillsAndReturnsNil() {
        let start = Date()
        #expect(ProcessRunner().run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// CI regression: under load, reads finished after a fixed 1 s grace and
    /// an exited tool came back with empty stdout. Never a partial answer.
    @Test func manyConcurrentRunsReturnFullOutput() async {
        let outputs = await withTaskGroup(of: String?.self) { group in
            for i in 0..<24 {
                group.addTask { ProcessRunner().run("/bin/echo", ["run-\(i)"], timeout: 10)?.stdout }
            }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(Set(outputs.compactMap { $0 }) == Set((0..<24).map { "run-\($0)\n" }))
    }

    @Test func missingToolIsNil() {
        #expect(ProcessRunner().run("/no/such/tool", [], timeout: 1) == nil)
    }

    @Test func largeOutputDoesNotDeadlock() {
        let out = ProcessRunner().run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"], timeout: 5)
        #expect(out?.stdout.count == 300_000)
    }
}
