import Foundation
import AppKit
import ApplicationServices

/// GUI 自动化回退（Path B）：先用深链打开 Codex 对应对话，再粘贴「继续」并回车。
/// 依赖辅助功能权限（System Events）。
struct AppleScriptAutomation {
    static func sendContinue(threadId: String, command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // 1) 深链打开/切换到对应对话，并等待界面加载（大对话可能需要一点时间）
        if let url = URL(string: "codex://threads/\(threadId)") {
            NSWorkspace.shared.open(url)
        }
        Thread.sleep(forTimeInterval: 3.0)
        // 2) 激活 Codex（进程名为 ChatGPT）→ 点击输入框确保焦点 → 粘贴「继续」→ Cmd+Enter 发送
        //    关键：必须先点击输入框，否则 keystroke v 会粘贴到当前焦点（可能是对话列表）而静默失效
        let script = """
        set the clipboard to "\(escaped)"
        tell application id "com.openai.codex" to activate
        delay 2.0
        tell application "System Events"
            tell process "ChatGPT"
                set frontmost to true
                try
                    set win to front window
                    set p to position of win
                    set s to size of win
                    set cx to (item 1 of p) + (item 1 of s) / 2
                    set cy to (item 2 of p) + (item 2 of s) - 55
                    click at {cx, cy}
                end try
            end tell
            delay 0.6
            keystroke "v" using command down
            delay 0.5
            key code 36 using command down
        end tell
        """
        try runAppleScript(script)
    }

    static func activateApp() throws {
        try runAppleScript(#"tell application id "com.openai.codex" to activate"#)
    }

    /// 检测辅助功能权限
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    static func runAppleScript(_ script: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8) ?? "AppleScript 失败"
            throw JSONRPCError(code: -1, message: msg, data: nil)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 自动继续引擎：
/// - Path A（首选）：连接桌面 app 的 app-server（remote_control），thread/resume + turn/start("继续")
/// - Path A 失效（无 socket / active writer / 未初始化）：回退 Path B（AppleScript GUI 自动化）
final class AutoContinueEngine {
    let codexHome: String
    /// 已处理过的线程，避免重复继续
    private var handledThreads: Set<String> = []

    var onLog: ((String, String) -> Void)?
    /// 需要重启 Codex 以启用 remote_control 时的回调（用于弹通知引导）
    var onNeedRestartCodex: (() -> Void)?
    /// 需要用户在系统设置授权辅助功能时的回调（不自动弹设置，由 UI 引导）
    var onNeedAccessibility: (() -> Void)?
    /// 最近一次继续失败的原因
    private(set) var lastFailureReason: String?

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    func alreadyHandled(_ threadId: String) -> Bool {
        handledThreads.contains(threadId)
    }

    /// 继续指定线程。返回是否成功。
    /// - Parameters:
    ///   - client: 当前已连接的 app-server 客户端（可能是桌面 control 或独立实例）
    ///   - threadId: 目标线程
    ///   - command: 注入的指令（默认「继续」）
    ///   - fallbackToGUI: 是否允许回退 GUI 自动化
    func continueThread(client: AppServerClient?, threadId: String, command: String, fallbackToGUI: Bool) async -> Bool {
        var lastError = "无可用连接"
        lastFailureReason = nil

        // Path A1: 使用当前 app-server 客户端（优先桌面 control socket）
        if let client {
            if await tryContinueViaAppServer(client: client, threadId: threadId, command: command) {
                handledThreads.insert(threadId)
                return true
            } else {
                lastError = "app-server 通道失败"
            }
        }

        // Path A2: 尝试连接桌面 control socket（可能上次未连上）
        let manager = AppServerManager(codexHome: codexHome)
        if let desktopClient = try? manager.connectToDesktopControl() {
            do {
                try await desktopClient.initialize()
                if await tryContinueViaAppServer(client: desktopClient, threadId: threadId, command: command) {
                    handledThreads.insert(threadId)
                    return true
                }
                lastError = "桌面 app-server 通道失败"
            } catch {
                lastError = "桌面 app-server 初始化失败: \(error)"
            }
        }

        // Path B: GUI 自动化回退
        if fallbackToGUI {
            if AppleScriptAutomation.hasAccessibilityPermission() {
                do {
                    try AppleScriptAutomation.sendContinue(threadId: threadId, command: command)
                    onLog?("已通过 GUI 自动化发送「\(command)」（深链打开对话并粘贴）",
                           "Sent \"\(command)\" via GUI automation (deep-linked into the chat and pasted)")
                    handledThreads.insert(threadId)
                    return true
                } catch {
                    lastError = "GUI 自动化失败: \(error)"
                }
            } else {
                let config = CodexConfig.load(codexHome: codexHome)
                if config.remoteControlEnabled {
                    // remote_control 已启用但 Codex 未重启（control socket 未出现）→ 引导重启 Codex
                    lastError = "辅助功能授权未生效，且 remote_control 已启用但 Codex 未重启。请重启 Codex 桌面 app，之后将走官方协议通道（无需辅助功能权限）；若仍要使用辅助功能，请在系统设置重新勾选授权（注意：重新打包会改变签名导致授权失效）"
                    onNeedRestartCodex?()
                } else {
                    lastError = "辅助功能未授权，无法在 Codex 中输入。请在面板「辅助功能」状态点「授权」勾选本 App（若勾选过仍提示，请重新勾选一次）"
                    onNeedAccessibility?()
                }
            }
        }

        lastFailureReason = lastError
        if let err = lastAttemptError {
            lastFailureReason = "\(lastError)（\(err)）"
        }
        onLog?("继续失败：\(lastFailureReason ?? lastError)", "Continue failed: \(lastFailureReason ?? lastError)")
        return false
    }

    private func tryContinueViaAppServer(client: AppServerClient, threadId: String, command: String) async -> Bool {
        do {
            // 1) resume 加载线程
            _ = try await client.request("thread/resume", params: ["threadId": threadId])
            onLog?("已 resume 线程 \(threadId)", "Resumed thread \(threadId)")
            // 2) 开启新轮次
            let result = try await client.requestDecoded("turn/start", params: [
                "threadId": threadId,
                "input": [["type": "text", "text": command]]
            ], as: TurnStartResult.self)
            onLog?("turn/start 成功，turn 状态: \(result.turn.status)",
                   "turn/start succeeded, turn status: \(result.turn.status)")
            // 3) 后台监控 turn 完成，完成后释放线程写锁（否则 Codex 桌面 app 无法打开该对话）
            let turnId = result.turn.id
            Task {
                await Self.waitTurnCompletion(client: client, threadId: threadId, turnId: turnId)
                try? await client.request("thread/unsubscribe", params: ["threadId": threadId])
                onLog?("线程 \(threadId) 的 turn 已结束，已释放线程（Codex 可重新打开该对话）",
                       "Turn ended for thread \(threadId); thread released (Codex can reopen it)")
            }
            return true
        } catch {
            // 降噪：A 通道失败是预期（如 active writer），不输出「失败」日志，
            // 由 continueThread 记录 lastError；若 B 兜底成功则整体视为成功
            lastAttemptError = error
            // 失败时释放可能残留的 writer 锁
            try? await client.request("thread/unsubscribe", params: ["threadId": threadId])
            return false
        }
    }

    /// 最近一次 A 通道失败的具体原因（供排查；不直接打日志）
    private var lastAttemptError: Error?

    /// 轮询 turn 状态，直到非 inProgress/queued（completed/failed/interrupted）
    private static func waitTurnCompletion(client: AppServerClient, threadId: String, turnId: String) async {
        let deadline = Date().addingTimeInterval(6 * 3600) // 最多 6 小时
        while Date() < deadline {
            do {
                let dict = try await client.request("thread/turns/list", params: ["threadId": threadId])
                if let data = dict["data"] as? [[String: Any]],
                   let turn = data.first(where: { ($0["id"] as? String) == turnId }),
                   let status = turn["status"] as? String,
                   status != "inProgress", status != "queued", status != "pending" {
                    return
                }
            } catch {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 每 10 秒查一次
        }
    }
}
