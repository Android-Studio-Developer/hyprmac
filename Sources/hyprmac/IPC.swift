import Foundation
import HyprmacCore

/// Unix socket helpers shared by the request server and the event server.
enum UnixSocket {
    static func listen(path: String) -> Int32? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, Darwin.listen(fd, 16) == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

/// Request/response socket: client writes one command line, server answers and closes.
final class IPCServer {
    private let path: String
    private let handler: (String) -> String

    init(path: String, handler: @escaping (String) -> String) {
        self.path = path
        self.handler = handler
    }

    func start() -> Bool {
        guard let fd = UnixSocket.listen(path: path) else { return false }
        let handler = self.handler
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var buf = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while data.count < 65536 {
                    let n = read(client, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                    if data.contains(UInt8(ascii: "\n")) { break }
                }
                let request = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let reply = DispatchQueue.main.sync { handler(request) }
                _ = UnixSocket.writeAll(client, Data(reply.utf8))
                close(client)
            }
        }
        return true
    }

    func stop() { unlink(path) }
}

/// Event stream like Hyprland's socket2: every client gets lines such as `workspace>>2`.
final class EventServer {
    private let path: String
    private var clients: [Int32] = []
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func start() -> Bool {
        guard let fd = UnixSocket.listen(path: path) else { return false }
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // Never let a slow reader block the main thread: drop it instead.
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
                guard let self else { close(c); return }
                self.lock.lock()
                self.clients.append(c)
                self.lock.unlock()
            }
        }
        return true
    }

    func emit(_ event: String, _ data: String) {
        let line = Data("\(event)>>\(data)\n".utf8)
        lock.lock()
        clients.removeAll { fd in
            if UnixSocket.writeAll(fd, line) { return false }
            close(fd)
            return true
        }
        lock.unlock()
    }

    func stop() { unlink(path) }
}
