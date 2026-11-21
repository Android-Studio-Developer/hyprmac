import Foundation
#if canImport(Darwin)
import Darwin

public struct ControlError: Error, CustomStringConvertible {
    public let description: String
}

/// Client side of the hyprmac control socket.
public enum Control {
    public static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError(description: "socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ControlError(description: "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else {
            close(fd)
            throw ControlError(description: "hyprmac is not running (no socket at \(path))")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Sends one request line and returns the full reply.
    public static func send(_ request: String, socket path: String) throws -> String {
        let fd = try connect(path)
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let line = Array((request + "\n").utf8)
        guard line.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == line.count else {
            throw ControlError(description: "write failed")
        }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
#endif
