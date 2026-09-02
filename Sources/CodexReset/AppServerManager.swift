import Foundation

/// 管理 app-server 连接：
/// 1. 优先连接桌面 Codex app 的 remote-control socket（同一实例，可无缝继续桌面持有的线程）
/// 2. 否则自起一个独立 app-server 实例（共享同一 CODEX_HOME 的 auth 与 sqlite）
final class AppServerManager {
    enum Mode: String {
        case desktopControl = "desktop-control"
        case ownServer = "own-server"
        case none = "none"
    }

    let codexHome: String
    private var ownProcess: Process?
    private(set) var mode: Mode = .none
    /// 最近一次 spawn 的错误输出（stderr）
    private var lastSpawnError: String?

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    /// remote-control 控制 socket 路径
    var controlSocketPath: String {
        codexHome + "/app-server-control/app-server-control.sock"
    }

    func controlSocketExists() -> Bool {
        FileManager.default.fileExists(atPath: controlSocketPath)
    }

    /// 尝试连接桌面 app 的控制 socket（Path A）
    func connectToDesktopControl() throws -> AppServerClient? {
        guard controlSocketExists() else { return nil }
        let ws = WebSocketClient(transport: .unix(path: controlSocketPath))
        let client = AppServerClient(ws: ws)
        do {
            try client.connect()
            mode = .desktopControl
            return client
        } catch {
            return nil
        }
    }

    /// 自起一个独立 app-server 实例（Path 备用 / 只读查询）
    func startOwnServer() throws -> AppServerClient {
        let port = try Self.freePort()
        let binary = Self.codexBinaryPath()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        // launchd 等最小环境下 PATH 不含 /usr/local/bin，显式补全
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        // 捕获 stderr 便于排查（EOF 时必须移除 handler，避免空转）
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let s = String(data: data, encoding: .utf8) {
                self?.lastSpawnError = (self?.lastSpawnError ?? "") + s
            }
        }
        try proc.run()
        ownProcess = proc

        // 等待 /readyz
        let deadline = Date().addingTimeInterval(20)
        var ready = false
        while Date() < deadline {
            if Self.pingReady(port: port) { ready = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        if !ready {
            proc.terminate()
            throw WebSocketClient.Error.connectionFailed("独立 app-server 启动超时: \(lastSpawnError ?? "无输出")")
        }

        let ws = WebSocketClient(transport: .tcp(host: "127.0.0.1", port: port))
        let client = AppServerClient(ws: ws)
        try client.connect()
        mode = .ownServer
        return client
    }

    func stopOwnServer() {
        if let proc = ownProcess, proc.isRunning {
            proc.terminate()
        }
        ownProcess = nil
    }

    // MARK: - 辅助

    /// 探测端口是否已可连接（等价于 readyz 200；用裸 TCP 避免主线程 URLSession 死锁）
    private static func pingReady(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// 获取一个空闲端口
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw WebSocketClient.Error.connectionFailed("bind 失败")
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var out = sockaddr_in()
        withUnsafeMutablePointer(to: &out) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(fd, sa, &len)
            }
        }
        return CFSwapInt16BigToHost(out.sin_port)
    }

    static func codexBinaryPath() -> String {
        // 优先使用真实的原生二进制，避免 node 包装器在 launchd 等最小环境下找不到 node
        let vendorBinary = "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
            vendorBinary,
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        for path in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/local/bin/codex"
    }
}
