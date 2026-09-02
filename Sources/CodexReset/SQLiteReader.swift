import Foundation
import SQLite3

/// SQLite 的 SQLITE_TRANSIENT 是 C 宏，Swift 里需手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 从本地 sqlite 定位「因用量用光而暂停」的对话
struct PausedThread {
    let threadId: String
    let title: String
    let cwd: String
    /// 错误消息里的恢复提示原文，如 "try again at 1:17 PM"
    let recoveryHint: String?
    /// 该失败轮次时间（Unix 秒）
    let failedAt: Int
}

final class SQLiteReader {
    let codexHome: String

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    private var threadHistoryPath: String { codexHome + "/thread_history_1.sqlite" }
    private var stateDbPath: String { codexHome + "/state_5.sqlite" }

    /// 找出所有因用量上限(usageLimitExceeded)失败暂停的线程（每线程取最新一次失败）。
    /// thread_turns 中 turn_id 为 ULID，按 turn_id 倒序即按时间倒序。
    func usageLimitedThreads(limit: Int = 20) -> [PausedThread] {
        guard let rows = queryRows(
            path: threadHistoryPath,
            sql: """
            SELECT t.thread_id, t.error_json, t.started_at
            FROM thread_turns t
            JOIN (
                SELECT thread_id, MAX(turn_id) AS max_turn
                FROM thread_turns
                WHERE status = 'failed' AND error_json LIKE '%usageLimitExceeded%'
                GROUP BY thread_id
            ) m ON t.thread_id = m.thread_id AND t.turn_id = m.max_turn
            ORDER BY t.turn_id DESC
            LIMIT ?
            """,
            args: [limit]
        ) else { return [] }

        var result: [PausedThread] = []
        for row in rows {
            let threadId = row[0] as? String ?? ""
            let errorJson = row[1] as? String ?? ""
            let failedAt = row[2] as? Int ?? 0
            guard !threadId.isEmpty else { continue }
            // 过滤子代理线程（主对话派生的 subagent，非用户独立对话，无需单独继续）
            if isSubagentThread(threadId: threadId) { continue }
            let title = displayTitle(threadId: threadId, stateTitle: threadTitle(threadId: threadId))
            let cwd = threadCwd(threadId: threadId) ?? ""
            let hint = Self.extractRecoveryHint(from: errorJson)
            result.append(PausedThread(threadId: threadId, title: title, cwd: cwd,
                                       recoveryHint: hint, failedAt: failedAt))
        }
        return result
    }

    /// 列出所有对话（含未暂停的），按项目分组用；过滤归档与子代理线程，最新在前
    func allThreads(limit: Int = 1000) -> [PausedThread] {
        guard let rows = queryRows(path: stateDbPath, sql: """
            SELECT id, title, cwd, updated_at
            FROM threads
            WHERE archived = 0 AND source NOT LIKE '{"subagent"%'
            ORDER BY updated_at_ms DESC
            LIMIT ?
        """, args: [limit]) else { return [] }

        var result: [PausedThread] = []
        for row in rows {
            let threadId = row[0] as? String ?? ""
            let rawTitle = row[1] as? String
            let cwd = row[2] as? String ?? ""
            let updatedAt = row[3] as? Int ?? 0
            guard !threadId.isEmpty else { continue }
            let title = displayTitle(threadId: threadId, stateTitle: rawTitle)
            result.append(PausedThread(threadId: threadId, title: title, cwd: cwd,
                                       recoveryHint: nil, failedAt: updatedAt))
        }
        return result
    }

    /// 判断是否为子代理线程（state 库 source 以 {"subagent" 开头）
    private func isSubagentThread(threadId: String) -> Bool {
        guard let source = threadSource(threadId: threadId) else { return false }
        return source.trimmingCharacters(in: .whitespaces).hasPrefix(#"{"subagent""#)
    }

    private func threadSource(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT source FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    /// 标题回退：state 库无记录时，从该线程最早一条 userMessage 提取前 40 字作为标题
    private func fallbackTitle(threadId: String) -> String? {
        guard let row = queryRow(path: threadHistoryPath, sql: """
            SELECT item_json
            FROM thread_items
            WHERE thread_id = ? AND item_type = 'userMessage'
            ORDER BY rollout_ordinal ASC
            LIMIT 1
        """, args: [threadId]),
        let json = row[0] as? String,
        let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let content = obj["content"] as? [[String: Any]],
        let first = content.first,
        let text = first["text"] as? String else { return nil }

        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }

    /// 显示用标题：Codex 会把对话标题自动更新为最新一条 userMessage（如自动发送的「继续」），
    /// 导致列表标题变成「继续」等无意义短标题。这里做智能回退：
    /// 优先用 state 标题；若它是无意义的短标题（<=2 字，如「继续」），回退到最早 userMessage（原始任务）。
    private func displayTitle(threadId: String, stateTitle: String?) -> String {
        if let stateTitle, !stateTitle.isEmpty, stateTitle.count >= 3 {
            return stateTitle
        }
        if let fb = fallbackTitle(threadId: threadId), !fb.isEmpty {
            return fb
        }
        return stateTitle ?? "未命名对话"
    }

    private func threadTitle(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT title FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    private func threadCwd(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT cwd FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    /// 从错误 JSON 中提取 "try again at ..." 恢复提示
    static func extractRecoveryHint(from errorJson: String) -> String? {
        guard let data = errorJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String else {
            return nil
        }
        if let range = message.range(of: "try again at ") {
            return String(message[range.upperBound...])
        }
        return nil
    }

    // MARK: - 通用查询

    private func queryRow(path: String, sql: String, args: [Any] = []) -> [Any?]? {
        queryRows(path: path, sql: sql, args: args)?.first
    }

    /// 多行查询
    private func queryRows(path: String, sql: String, args: [Any] = []) -> [[Any?]]? {
        guard let db = open(path) else {
            #if DEBUG
            FileHandle.standardError.write("[SQLITE-OPEN-FAIL] \(path)\n".data(using: .utf8)!)
            #endif
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            #if DEBUG
            let err = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "?"
            FileHandle.standardError.write("[SQLITE-PREPARE-FAIL] \(err)\n".data(using: .utf8)!)
            #endif
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            if let s = arg as? String {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            } else if let n = arg as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }

        let count = sqlite3_column_count(stmt)
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: [Any?] = []
                for i in 0..<count {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row.append(Int(sqlite3_column_int64(stmt, i)))
                    case SQLITE_TEXT:
                        if let c = sqlite3_column_text(stmt, i) {
                            row.append(String(cString: c))
                        } else {
                            row.append(nil)
                        }
                    case SQLITE_NULL:
                        row.append(nil)
                    case SQLITE_FLOAT:
                        row.append(sqlite3_column_double(stmt, i))
                    default:
                        if let c = sqlite3_column_text(stmt, i) {
                            row.append(String(cString: c))
                        } else {
                            row.append(nil)
                        }
                    }
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                #if DEBUG
                let err = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "rc=\(rc)"
                FileHandle.standardError.write("[SQLITE-STEP-FAIL] \(err)\n".data(using: .utf8)!)
                #endif
                return nil
            }
        }
        return rows
    }

    private func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // 用 READWRITE 而非 READONLY：WAL 模式数据库在并发写时 readonly 打开可能失败
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK else {
            let msg = (db.flatMap { sqlite3_errmsg($0) }).flatMap { String(cString: $0) } ?? "rc=\(rc)"
            #if DEBUG
            FileHandle.standardError.write("[SQLITE-OPEN-ERR] \(path): \(msg)\n".data(using: .utf8)!)
            #endif
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }
}

// MARK: - config.toml 读取

/// 读取 ~/.codex/config.toml 中的相关配置
struct CodexConfig {
    let remoteControlEnabled: Bool

    static func load(codexHome: String) -> CodexConfig {
        let path = codexHome + "/config.toml"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return CodexConfig(remoteControlEnabled: false)
        }
        var remoteControl = false
        var inFeatures = false
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inFeatures = (line == "[features]")
                continue
            }
            if inFeatures && line.hasPrefix("remote_control") {
                remoteControl = line.lowercased().contains("true")
            }
        }
        return CodexConfig(remoteControlEnabled: remoteControl)
    }

    /// 写入 [features] remote_control = true/false（保留原有内容；需重启 Codex 桌面 app 生效）
    /// 注意：必须复用已有的 [features] 段，不能重复定义，否则 TOML 报 duplicate key
    @discardableResult
    static func setRemoteControl(codexHome: String, enabled: Bool) -> Bool {
        let path = codexHome + "/config.toml"
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = content.components(separatedBy: "\n")
        let value = enabled ? "true" : "false"

        // 找到所有段标题行（以 [ 开头 ] 结尾）
        let sectionIndices = lines.indices.filter {
            let t = lines[$0].trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }
        // 定位 [features] 段
        var featuresStart: Int?
        for idx in sectionIndices where lines[idx].trimmingCharacters(in: .whitespaces) == "[features]" {
            featuresStart = idx
            break
        }

        var modified = false
        if let start = featuresStart {
            // 段范围：start ..< 下一个段标题（或文件末尾）
            let end = sectionIndices.first(where: { $0 > start }) ?? lines.count
            var inserted = false
            for i in start..<end {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("remote_control") {
                    lines[i] = "remote_control = \(value)"
                    inserted = true
                    modified = true
                    break
                }
            }
            if !inserted {
                // 在段内末尾插入
                lines.insert("remote_control = \(value)", at: end)
                modified = true
            }
        } else {
            // 完全没有 [features] 段才追加新段
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            lines.append("")
            lines.append("[features]")
            lines.append("remote_control = \(value)")
            modified = true
        }

        guard modified else { return true }
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
