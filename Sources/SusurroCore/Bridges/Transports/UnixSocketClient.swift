import Foundation

/// One request/response exchange over a Unix-domain socket, with a deadline
/// (docs/BRIDGES.md). Blocking: call off the main thread. Used by the Emacs
/// bridge (the emacsclient protocol is one request per connection, ~2 ms to
/// connect); reusable for e.g. a future editor-extension socket.
public struct UnixSocketClient: Sendable {
    public let path: String
    public init(path: String) { self.path = path }

    /// Sends `payload`, then reads until `isComplete` says the reply is whole,
    /// the peer closes, or `timeout` passes. nil = could not connect or send.
    public func request(_ payload: Data, timeout: TimeInterval,
                        isComplete: (Data) -> Bool) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let whole = Int(timeout)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((timeout - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == payload.count else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[0..<n])
            if isComplete(reply) { break }
        }
        return reply
    }
}
