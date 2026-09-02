import Foundation

/// 极简 WebSocket 客户端：支持 TCP (ws://host:port) 与 Unix domain socket 两种传输，
/// 用于连接 Codex app-server（协议：HTTP Upgrade 握手 + WebSocket 帧承载 JSON-RPC）。
final class WebSocketClient {
    enum Transport {
        case tcp(host: String, port: UInt16)
        case unix(path: String)
    }

    enum Error: Swift.Error {
        case handshakeFailed(String)
        case connectionFailed(String)
        case closed
        case notConnected
    }

    private let transport: Transport
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var readThread: Thread?
    private var isClosed = false

    /// 收到文本消息回调
    var onText: ((String) -> Void)?
    /// 连接关闭回调
    var onClose: ((Error?) -> Void)?

    init(transport: Transport) {
        self.transport = transport
    }

    /// 建立底层连接并完成 WebSocket 握手
    func connect() throws {
        let newFd: Int32
        switch transport {
        case .tcp(let host, let port):
            newFd = try Self.openTCP(host: host, port: port)
        case .unix(let path):
            newFd = try Self.openUnix(path: path)
        }
        fd = newFd
        try performHandshake()
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "ws-read"
        thread.start()
        readThread = thread
    }

    func sendText(_ text: String) throws {
        guard fd >= 0 else { throw Error.notConnected }
        let payload = Array(text.utf8)
        let frame = Self.makeMaskedFrame(payload: payload, opcode: 0x1)
        writeLock.lock()
        defer { writeLock.unlock() }
        try frame.withUnsafeBytes { buf in
            try Self.writeAll(fd, buf.bindMemory(to: UInt8.self).baseAddress!, buf.count)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if fd >= 0 {
            if let frame = try? Self.makeMaskedFrame(payload: [], opcode: 0x8) {
                writeLock.lock()
                _ = frame.withUnsafeBytes { buf in
                    try? Self.writeAll(fd, buf.bindMemory(to: UInt8.self).baseAddress!, buf.count)
                }
                writeLock.unlock()
            }
            Darwin.close(fd)
            fd = -1
        }
        onClose?(nil)
    }

    // MARK: - 握手

    private func performHandshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var req = "GET / HTTP/1.1\r\n"
        req += "Host: localhost\r\n"
        req += "Upgrade: websocket\r\n"
        req += "Connection: Upgrade\r\n"
        req += "Sec-WebSocket-Key: \(key)\r\n"
        req += "Sec-WebSocket-Version: 13\r\n"
        req += "\r\n"
        try writeAllString(req)

        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { throw Error.handshakeFailed("handshake 期间连接关闭") }
            buffer.append(byte)
        }
        guard let header = String(data: buffer, encoding: .utf8),
              header.hasPrefix("HTTP/1.1 101") else {
            throw Error.handshakeFailed(String(data: buffer, encoding: .utf8) ?? "无效握手响应")
        }
    }

    // MARK: - 读取循环

    private func readLoop() {
        while !isClosed {
            do {
                let (opcode, payload) = try Self.readFrame(fd)
                switch opcode {
                case 0x1: // text
                    if let text = String(data: Data(payload), encoding: .utf8) {
                        onText?(text)
                    }
                case 0x8: // close
                    close()
                    return
                case 0x9: // ping -> pong
                    writeLock.lock()
                    if let pong = try? Self.makeMaskedFrame(payload: payload, opcode: 0xA) {
                        _ = pong.withUnsafeBytes { buf in
                            try? Self.writeAll(fd, buf.bindMemory(to: UInt8.self).baseAddress!, buf.count)
                        }
                    }
                    writeLock.unlock()
                default:
                    break
                }
            } catch {
                #if DEBUG
                FileHandle.standardError.write("[WS-READ-ERROR] \(error)\n".data(using: .utf8)!)
                #endif
                close()
                return
            }
        }
    }

    // MARK: - 底层 socket

    private static func openTCP(host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.connectionFailed("socket() 失败") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            throw Error.connectionFailed("TCP 连接失败 errno=\(errno)")
        }
        return fd
    }

    private static func openUnix(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.connectionFailed("socket() 失败") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            Darwin.close(fd)
            throw Error.connectionFailed("socket 路径过长")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: UInt8.self, capacity: maxLen) { buf in
                for (i, b) in pathBytes.enumerated() { buf[i] = b }
                buf[pathBytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            Darwin.close(fd)
            throw Error.connectionFailed("Unix socket 连接失败 errno=\(errno)")
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ len: Int) throws {
        var offset = 0
        while offset < len {
            let n = write(fd, buf + offset, len - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw Error.closed
            }
            offset += n
        }
    }

    private func writeAllString(_ s: String) throws {
        let data = Array(s.utf8)
        try data.withUnsafeBytes { buf in
            try Self.writeAll(fd, buf.bindMemory(to: UInt8.self).baseAddress!, buf.count)
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { throw Error.closed }
            out.append(byte)
        }
        return out
    }

    private static func readFrame(_ fd: Int32) throws -> (Int, [UInt8]) {
        let hdr = try readExact(fd, 2)
        let opcode = Int(hdr[0] & 0x0f)
        let masked = (hdr[1] & 0x80) != 0
        var len = Int(hdr[1] & 0x7f)
        if len == 126 {
            let ext = try readExact(fd, 2)
            len = (Int(ext[0]) << 8) | Int(ext[1])
        } else if len == 127 {
            let ext = try readExact(fd, 8)
            var v: UInt64 = 0
            for b in ext { v = (v << 8) | UInt64(b) }
            len = Int(v)
        }
        var mask: [UInt8] = []
        if masked { mask = try readExact(fd, 4) }
        let payload = try readExact(fd, len)
        if masked {
            return (opcode, payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        return (opcode, payload)
    }

    private static func makeMaskedFrame(payload: [UInt8], opcode: Int) -> Data {
        var frame = Data()
        frame.append(UInt8(0x80 | opcode))
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(0x80 | len))
        } else if len < 65536 {
            frame.append(UInt8(0x80 | 126))
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(UInt8(0x80 | 127))
            var big = UInt64(len)
            var bytes = [UInt8]()
            for _ in 0..<8 { bytes.append(UInt8(big & 0xff)); big >>= 8 }
            frame.append(contentsOf: bytes.reversed())
        }
        frame.append(contentsOf: mask)
        for (i, b) in payload.enumerated() {
            frame.append(b ^ mask[i % 4])
        }
        return frame
    }
}
