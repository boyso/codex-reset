import Foundation

/// app-server JSON-RPC 错误
struct JSONRPCError: Swift.Error, CustomStringConvertible {
    let code: Int
    let message: String
    let data: Any?

    var description: String {
        if let data = data {
            return "\(message) (data: \(data))"
        }
        return message
    }
}

/// 基于 WebSocket 的 Codex app-server JSON-RPC 客户端。
/// 消息为 JSON-RPC 2.0，但不带 "jsonrpc" 字段；先 initialize 再 initialized。
final class AppServerClient {
    private let ws: WebSocketClient
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Swift.Error>] = [:]
    private let lock = NSLock()

    /// 收到的服务端通知回调 (method, params)
    var onNotification: ((String, [String: Any]) -> Void)?

    init(ws: WebSocketClient) {
        self.ws = ws
        ws.onText = { [weak self] text in self?.handle(text) }
    }

    /// 建立 WebSocket 连接并完成握手
    func connect() throws {
        try ws.connect()
    }

    func close() {
        ws.close()
    }

    /// 协议握手：initialize 请求 + initialized 通知
    func initialize() async throws {
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "CodexReset", "version": "1.0.0"],
            "capabilities": ["experimentalApi": true]
        ])
        try notify("initialized", params: [:])
    }

    /// 发送请求并等待响应
    func request(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id: Int
        lock.lock()
        id = nextId
        nextId += 1
        lock.unlock()

        var body: [String: Any] = ["method": method, "id": id]
        if let params { body["params"] = params }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            do {
                let text = try Self.jsonText(body)
                try ws.sendText(text)
                #if DEBUG
                FileHandle.standardError.write("[RPC-SENT] \(method) id=\(id)\n".data(using: .utf8)!)
                #endif
            } catch {
                lock.lock()
                pending.removeValue(forKey: id)
                lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }

    /// 发送请求并解码为指定模型
    func requestDecoded<T: Decodable>(_ method: String, params: [String: Any]? = nil, as type: T.Type) async throws -> T {
        let dict = try await request(method, params: params)
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(type, from: data)
    }

    /// 发送通知（无需响应）
    func notify(_ method: String, params: [String: Any]) throws {
        var body: [String: Any] = ["method": method]
        if !params.isEmpty { body["params"] = params }
        try ws.sendText(try Self.jsonText(body))
    }

    // MARK: - 内部

    private static func jsonText(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONRPCError(code: -1, message: "JSON 编码失败", data: nil)
        }
        return text
    }

    private func handle(_ text: String) {
        #if DEBUG
        FileHandle.standardError.write("[RPC-RECV] \(text.prefix(200))\n".data(using: .utf8)!)
        #endif
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            FileHandle.standardError.write("[RPC-PARSE-FAIL] \(text.prefix(200))\n".data(using: .utf8)!)
            #endif
            return
        }

        if let method = obj["method"] as? String {
            onNotification?(method, obj["params"] as? [String: Any] ?? [:])
            return
        }
        guard let id = obj["id"] as? Int else { return }

        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()

        if let error = obj["error"] as? [String: Any] {
            cont?.resume(throwing: JSONRPCError(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "未知错误",
                data: error["data"]
            ))
        } else if let result = obj["result"] as? [String: Any] {
            cont?.resume(returning: result)
        } else {
            cont?.resume(returning: [:])
        }
    }
}
