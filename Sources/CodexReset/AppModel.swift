import Foundation
import AppKit

/// 一条日志：同时保存中英文，展示时按当前语言渲染（切换语言后旧日志也会跟随切换）
struct LogEntry {
    let time: String
    let zh: String
    let en: String
    /// 按当前语言取展示文案
    var display: String { L(zh, en) }
}

/// 全局应用状态与编排：连接 app-server → 轮询用量 → 定位暂停线程 → 到点自动继续
@MainActor
final class AppModel: ObservableObject {
    @Published var connectionMode: String = "connecting"
    @Published var rateLimits: AccountRateLimits?
    @Published var lastError: String?
    /// 所有因用量暂停的对话（最新在前）
    @Published var pausedThreads: [PausedThread] = []
    /// 所有对话（含未暂停），可按项目勾选任意对话参与自动继续
    @Published var allThreads: [PausedThread] = []
    /// 勾选、需要在恢复后自动继续的对话
    @Published var selectedThreadIds: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(selectedThreadIds), forKey: "selectedThreadIds")
            updateIdleSleepPrevention()
        }
    }
    @Published var logLines: [LogEntry] = []
    @Published var autoContinue: Bool {
        didSet {
            UserDefaults.standard.set(autoContinue, forKey: "autoContinue")
            updateIdleSleepPrevention()
        }
    }
    /// Optional, scoped idle-sleep protection. Off until the user opts in.
    @Published var keepAwakeForSelectedTasks: Bool {
        didSet {
            UserDefaults.standard.set(keepAwakeForSelectedTasks, forKey: "keepAwakeForSelectedTasks")
            updateIdleSleepPrevention()
        }
    }
    @Published private(set) var idleSleepPreventionActive = false
    @Published var continueCommand: String {
        didSet { UserDefaults.standard.set(continueCommand, forKey: "continueCommand") }
    }
    @Published var isWorking = false {
        didSet { updateIdleSleepPrevention() }
    }
    @Published var remoteControlEnabled: Bool
    /// 语言设置：system / zh / en（切换后写回 UserDefaults 并通过 objectWillChange 触发界面刷新）
    @Published var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            // 默认指令跟随语言：仅当指令仍为内置默认值（继续/Continue）时自动同步切换，用户自定义指令不受影响
            if continueCommand == "继续" || continueCommand == "Continue" {
                continueCommand = L("继续", "Continue")
            }
        }
    }
    /// 本 App 是否已获得辅助功能授权（GUI 兜底通道所需；无参检测不弹窗）
    @Published var accessibilityAuthorized: Bool = false
    /// 5 小时窗口时间线（每次用量重置记录一个点）
    @Published var resetHistory: [UsageResetEvent] = []

    let codexHome: String
    let manager: AppServerManager
    private let reader: SQLiteReader
    private let engine: AutoContinueEngine
    private let idleSleepManager = IdleSleepManager()
    private var client: AppServerClient?
    private var timer: Timer?
    /// 记录上一次是否处于「已到上限」状态，用于恢复检测
    private var wasLimited = false
    private var autoContinueRunning = false

    init(codexHome: String = AppModel.defaultCodexHome()) {
        self.codexHome = codexHome
        self.manager = AppServerManager(codexHome: codexHome)
        self.reader = SQLiteReader(codexHome: codexHome)
        self.engine = AutoContinueEngine(codexHome: codexHome)
        self.selectedThreadIds = Set(UserDefaults.standard.stringArray(forKey: "selectedThreadIds") ?? [])
        self.autoContinue = UserDefaults.standard.object(forKey: "autoContinue") as? Bool ?? true
        self.keepAwakeForSelectedTasks = UserDefaults.standard.bool(forKey: "keepAwakeForSelectedTasks")
        self.continueCommand = UserDefaults.standard.string(forKey: "continueCommand") ?? L("继续", "Continue")
        self.remoteControlEnabled = CodexConfig.load(codexHome: codexHome).remoteControlEnabled
        self.language = UserDefaults.standard.string(forKey: "language") ?? "system"
        engine.onLog = { [weak self] zh, en in
            Task { @MainActor in self?.appendLog(zh, en) }
        }
        engine.onNeedRestartCodex = { [weak self] in
            Task { @MainActor in self?.notifyRestartCodex() }
        }
        engine.onNeedAccessibility = { [weak self] in
            Task { @MainActor in self?.notifyNeedAccessibility() }
        }
        loadResetHistory()
    }

    nonisolated static func defaultCodexHome() -> String {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory() + "/.codex"
    }

    // MARK: - 启动

    func start() {
        appendLog("CodexReset 启动，CODEX_HOME=\(codexHome)", "CodexReset started, CODEX_HOME=\(codexHome)")
        // 清理上次残留的 app-server 进程（app 异常退出后其子进程可能仍持有线程写锁）
        cleanupOrphanAppServers()
        // 暂停对话列表来自本地 sqlite，不依赖 app-server，立即加载
        refreshPausedThreads()
        refreshAllThreads()
        Task { await connectAndBegin() }
    }

    /// 杀掉残留的 "codex app-server --listen" 进程并等待其释放线程写锁。
    /// 桌面 Codex 的 app-server 是 stdio 模式（无 --listen），不会被误杀。
    private func cleanupOrphanAppServers() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "app-server --listen"]
        try? proc.run()
        Thread.sleep(forTimeInterval: 1)
    }

    func connectAndBegin() async {
        // 1) 优先桌面 control socket（Path A）
        if let desktop = try? manager.connectToDesktopControl() {
            client = desktop
            do {
                try await desktop.initialize()
                connectionMode = "desktop-control"
                appendLog("已连接桌面 Codex app-server（remote-control）", "Connected to the desktop Codex app-server (remote-control)")
            } catch {
                appendLog("桌面 control 初始化失败，改用独立实例: \(error)", "Desktop control init failed; falling back to a standalone instance: \(error)")
                client = nil
                await startOwnServerFallback()
            }
        } else {
            await startOwnServerFallback()
        }
        startPolling()
    }

    /// 无头查询：连接、读取用量与暂停线程并打印
    func runHeadlessQuery() async {
        await connectAndBegin()
        // 轮询等待用量返回（最多 20 秒）
        for _ in 0..<20 {
            if rateLimits != nil || connectionMode == "none" { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("mode=\(connectionMode)")
        print("lastError=\(lastError ?? "nil")")
        if let rl = rateLimits {
            print("plan=\(rl.rateLimits.planType ?? "?")")
            print("primary.usedPercent=\(rl.rateLimits.primary?.usedPercent ?? -1) resetsAt=\(rl.rateLimits.primary?.resetsAt ?? 0) windowMins=\(rl.rateLimits.primary?.windowDurationMins ?? 0)")
            print("secondary.usedPercent=\(rl.rateLimits.secondary?.usedPercent ?? -1) resetsAt=\(rl.rateLimits.secondary?.resetsAt ?? 0) windowMins=\(rl.rateLimits.secondary?.windowDurationMins ?? 0)")
            print("reached=\(rl.rateLimits.rateLimitReachedType ?? "nil") credits=\(rl.rateLimits.credits?.balance ?? "nil")")
        }
        for entry in logLines { print("log: [\(entry.time)] \(entry.display)") }
        refreshPausedThreads()
        print("pausedCount=\(pausedThreads.count)")
        for p in pausedThreads {
            print("pausedThread=\(p.threadId) | \(p.title) | \(p.cwd) | \(p.recoveryHint ?? "")")
        }
        manager.stopOwnServer()
    }

    /// 无头模式：连接后立即继续指定线程，打印结果
    func runHeadlessContinue(threadId: String) async {
        await connectAndBegin()
        let ok = await engine.continueThread(
            client: client,
            threadId: threadId,
            command: continueCommand,
            fallbackToGUI: false
        )
        print("continueResult=\(ok)")
        manager.stopOwnServer()
    }

    /// 退出：清理自起的 app-server 子进程
    func quit() {
        idleSleepManager.stop()
        manager.stopOwnServer()
        NSApp.terminate(nil)
    }

    /// 收到终止信号时的清理（launchd 停止 / kill）
    func stopAndExit() {
        idleSleepManager.stop()
        manager.stopOwnServer()
        exit(0)
    }

    /// 开关 remote_control（写入 config.toml，需重启 Codex 桌面 app 后生效）
    func setRemoteControl(_ enabled: Bool) {
        if CodexConfig.setRemoteControl(codexHome: codexHome, enabled: enabled) {
            remoteControlEnabled = enabled
            let v = enabled ? "true" : "false"
            appendLog("已写入 [features] remote_control = \(v)，请重启 Codex 桌面 app 后生效",
                      "Wrote [features] remote_control = \(v); restart the Codex desktop app to take effect")
            notify(title: enabled ? "已启用 remote_control" : "已关闭 remote_control",
                   body: enabled ? "请重启 Codex 桌面 app，之后即可通过官方协议自动继续对话" : "已关闭，之后使用 app-server + GUI 兜底通道")
        } else {
            appendLog("写入 config.toml 失败", "Failed to write config.toml")
        }
    }

    private func startOwnServerFallback() async {
        do {
            let own = try manager.startOwnServer()
            client = own
            do {
                try await own.initialize()
                connectionMode = "own-server"
                appendLog("已自起独立 app-server 实例", "Started a standalone app-server instance")
            } catch {
                connectionMode = "none"
                appendLog("独立 app-server 初始化失败: \(error)", "Standalone app-server init failed: \(error)")
            }
        } catch {
            connectionMode = "none"
            let zhMsg = "app-server 启动失败: \(error)"
            let enMsg = "app-server failed to start: \(error)"
            lastError = zhMsg
            appendLog(zhMsg, enMsg)
        }
    }

    private func startPolling() {
        refreshNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    // MARK: - 刷新

    /// 刷新用量与暂停列表（暂停列表本地读取，不依赖 app-server 连接）
    func refreshNow() {
        refreshPausedThreads()
        // 全部对话列表同样定时刷新，对话标题保持最新（在 Codex 里重命名后自动跟上）
        refreshAllThreads()
        accessibilityAuthorized = AppleScriptAutomation.hasAccessibilityPermission()
        checkControlSocketUpgrade()
        warnRestartCodexIfNeeded()
        guard let client else { return }
        Task {
            await refreshRateLimits(client: client)
        }
    }

    /// 是否已提示过重启 Codex（避免每 30s 重复弹）
    private var warnedRestartCodex = false

    /// remote_control 已配置但 socket 未出现：提示用户重启 Codex 桌面 app
    private func warnRestartCodexIfNeeded() {
        guard !warnedRestartCodex, connectionMode != "desktop-control" else { return }
        if remoteControlEnabled && !manager.controlSocketExists() {
            warnedRestartCodex = true
            notifyRestartCodex()
        }
    }

    private func notifyRestartCodex() {
        appendLog("remote_control 已启用但未生效：请重启 Codex 桌面 app，之后自动继续将走官方协议（无需辅助功能权限）",
                  "remote_control is enabled but not active yet: restart the Codex desktop app so auto-continue uses the official protocol (no accessibility permission needed)")
        notify(title: "请重启 Codex 桌面 app", body: "remote_control 已开启，重启后本 App 会自动切换到官方协议通道继续对话")
    }

    /// 检测到 remote_control socket 出现时，自动从独立实例切换到桌面 app-server
    private func checkControlSocketUpgrade() {
        guard connectionMode != "desktop-control" else { return }
        guard manager.controlSocketExists(),
              let desktop = try? manager.connectToDesktopControl() else { return }
        Task {
            do {
                try await desktop.initialize()
                let old = client
                client = desktop
                connectionMode = "desktop-control"
                appendLog("检测到 Codex remote-control socket，已切换到桌面 app-server 通道",
                          "Detected the Codex remote-control socket; switched to the desktop app-server channel")
                old?.close()
                manager.stopOwnServer()
                await refreshRateLimits(client: desktop)
            } catch {
                appendLog("连接桌面 control socket 失败: \(error)", "Failed to connect to the desktop control socket: \(error)")
            }
        }
    }

    private func refreshRateLimits(client: AppServerClient) async {
        do {
            let rl = try await client.requestDecoded("account/rateLimits/read", as: AccountRateLimits.self)
            rateLimits = rl
            lastError = nil
            checkRecovery(rl)
            trackWindowReset(rl)
            await autoContinueIfNeeded()
        } catch {
            lastError = "读取用量失败: \(error)"
            appendLog("读取用量失败: \(error)", "Failed to read usage: \(error)")
        }
    }

    // MARK: - 用量历史（5h 窗口时间线）

    /// 上次观测到的 primary 窗口重置时间（Unix 秒）
    private var lastResetsAt: Int?

    /// 检测 5 小时窗口重置：resetsAt 变化即记录一个新窗口点
    private func trackWindowReset(_ rl: AccountRateLimits) {
        guard let primary = rl.rateLimits.primary, let resetsAt = primary.resetsAt else { return }
        guard lastResetsAt != resetsAt else { return }
        // 5 小时窗口起点 = 下次重置时间 - 5h
        let windowStart = resetsAt - 5 * 3600
        appendResetEvent(windowStart: windowStart, nextResetAt: resetsAt, usedPercent: Double(primary.usedPercent))
        lastResetsAt = resetsAt
    }

    /// 追加一个窗口点并持久化（保留最近 200 条）
    private func appendResetEvent(windowStart: Int, nextResetAt: Int, usedPercent: Double) {
        let evt = UsageResetEvent(
            windowStart: Date(timeIntervalSince1970: TimeInterval(windowStart)),
            nextResetAt: Date(timeIntervalSince1970: TimeInterval(nextResetAt)),
            usedPercent: usedPercent
        )
        resetHistory.insert(evt, at: 0)
        if resetHistory.count > 200 {
            resetHistory.removeLast(resetHistory.count - 200)
        }
        saveResetHistory()
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        appendLog("记录用量窗口：\(f.string(from: evt.windowStart)) 开始，下次重置 \(f.string(from: evt.nextResetAt))（用量 \(Int(usedPercent))%）",
                  "Recorded usage window: start \(f.string(from: evt.windowStart)), next reset \(f.string(from: evt.nextResetAt)) (usage \(Int(usedPercent))%)")
    }

    private func loadResetHistory() {
        guard let data = UserDefaults.standard.data(forKey: "usageResetHistory"),
              let history = try? JSONDecoder().decode([UsageResetEvent].self, from: data) else {
            return
        }
        resetHistory = history
    }

    private func saveResetHistory() {
        if let data = try? JSONEncoder().encode(resetHistory) {
            UserDefaults.standard.set(data, forKey: "usageResetHistory")
        }
    }

    /// 刷新暂停对话列表（不自动勾选；勾选完全由用户控制）
    func refreshPausedThreads() {
        pausedThreads = reader.usageLimitedThreads()
        updateIdleSleepPrevention()
    }

    /// Assert only when an opted-in selected chat has a pending quota failure or
    /// an active turn; release automatically on completion/deselection/disable.
    private func updateIdleSleepPrevention() {
        let monitoring = keepAwakeForSelectedTasks && autoContinue && !selectedThreadIds.isEmpty
        let hasPendingFailure = monitoring && pausedThreads.contains {
            selectedThreadIds.contains($0.threadId)
        }
        let hasRunningTurn = monitoring &&
            !reader.activeThreadIds(for: selectedThreadIds).isEmpty
        let shouldPrevent = IdleSleepPolicy.shouldPreventIdleSleep(
            enabled: keepAwakeForSelectedTasks,
            autoContinueEnabled: autoContinue,
            hasSelectedQuotaFailure: hasPendingFailure,
            hasSelectedRunningTurn: hasRunningTurn,
            isSendingContinue: isWorking && !selectedThreadIds.isEmpty
        )
        guard idleSleepManager.setActive(shouldPrevent) else { return }
        idleSleepPreventionActive = idleSleepManager.isActive
        appendLog(
            shouldPrevent
                ? "已阻止 Mac 因空闲进入睡眠（已勾选任务等待恢复或正在执行）"
                : "已释放防空闲睡眠限制（没有需要等待或执行的已勾选任务）",
            shouldPrevent
                ? "Preventing idle system sleep for a selected waiting or running task"
                : "Released idle sleep protection; no selected task requires it"
        )
    }

    /// 刷新「全部对话」列表（面板每次打开时调用）
    func refreshAllThreads() {
        allThreads = reader.allThreads()
    }

    /// Automatic recovery must never target merely selected, already-completed conversations.
    private func selectedTargets(onlyUsageLimited: Bool = false) -> [PausedThread] {
        var seen = Set<String>()
        var result: [PausedThread] = []
        let candidates = onlyUsageLimited ? pausedThreads : pausedThreads + allThreads
        for t in candidates where selectedThreadIds.contains(t.threadId) {
            if seen.insert(t.threadId).inserted { result.append(t) }
        }
        return result
    }

    private func isRateLimited(_ rl: AccountRateLimits) -> Bool {
        let reachedType = rl.rateLimits.rateLimitReachedType
        return (reachedType != nil && reachedType != "none") ||
            (rl.rateLimits.primary?.usedPercent ?? 0) >= 100 ||
            (rl.rateLimits.secondary?.usedPercent ?? 0) >= 100
    }

    /// 用量恢复检测 + 自动继续
    private func checkRecovery(_ rl: AccountRateLimits) {
        let primary = rl.rateLimits.primary
        let isLimited = isRateLimited(rl)
        if wasLimited && !isLimited {
            appendLog("检测到用量恢复！usedPercent=\(primary?.usedPercent ?? -1)%",
                      "Usage recovered! usedPercent=\(primary?.usedPercent ?? -1)%")
            notify(title: "Codex 用量已恢复", body: "正在检查仍因额度耗尽暂停的对话…")
        }
        wasLimited = isLimited
    }

    /// Recheck on each usage poll so relaunching after a reset doesn't miss a pending failure.
    /// A handled failure never runs twice; a later failure in the same thread can resume again.
    func autoContinueIfNeeded() async {
        guard autoContinue, !selectedThreadIds.isEmpty, !autoContinueRunning,
              let rl = rateLimits, !isRateLimited(rl) else { return }
        autoContinueRunning = true
        defer { autoContinueRunning = false }
        refreshPausedThreads()
        for paused in selectedTargets(onlyUsageLimited: true) {
            if engine.alreadyHandled(paused.threadId, failedTurnId: paused.failedTurnId) {
                continue
            }
            await continueOne(paused: paused, auto: true)
        }
    }

    /// 对单个对话执行继续
    private func continueOne(paused: PausedThread, auto: Bool) async {
        isWorking = true
        appendLog("\(auto ? "自动" : "手动")继续：\(paused.title)",
                  "\(auto ? "Auto" : "Manual") continue: \(paused.title)")
        let ok = await engine.continueThread(
            client: client,
            threadId: paused.threadId,
            failedTurnId: paused.failedTurnId,
            command: continueCommand,
            fallbackToGUI: true
        )
        isWorking = false
        if ok {
            notify(title: "Codex 已继续", body: "已对「\(paused.title)」发送「\(continueCommand)」")
        } else {
            // 手动/自动失败都要明确反馈（辅助功能引导走 engine.onNeedAccessibility 通知，不自动弹系统设置）
            let reason = engine.lastFailureReason ?? "未知原因"
            notify(title: "继续失败", body: "「\(paused.title)」\n\(reason)")
        }
    }

    /// 手动立即继续：对所有勾选的对话（暂停 + 全部）执行继续
    func manualContinue() async {
        refreshPausedThreads()
        let targets = selectedTargets()
        guard !targets.isEmpty else {
            appendLog("没有勾选的对话", "No chats selected")
            return
        }
        for paused in targets {
            await continueOne(paused: paused, auto: false)
        }
    }

    /// 在 Codex 桌面 app 中打开指定对话（官方深链 codex://threads/<id>）
    func openInCodex(threadId: String) {
        guard let url = URL(string: "codex://threads/\(threadId)") else { return }
        NSWorkspace.shared.open(url)
        appendLog("已在 Codex 中打开对话 \(threadId)", "Opened chat \(threadId) in Codex")
    }

    // MARK: - 辅助功能授权监控（授权后自动重启生效）

    private var accessibilityMonitorTimer: Timer?

    /// 辅助功能未授权时的通知（不自动弹系统设置，避免反复打扰）
    func notifyNeedAccessibility() {
        accessibilityAuthorized = AppleScriptAutomation.hasAccessibilityPermission()
        let note = NSUserNotification()
        note.title = "CodexReset"
        note.informativeText = "辅助功能未授权，无法在 Codex 中输入「继续」。请点面板「授权辅助功能」勾选本 App（若勾选过仍提示，请重新勾选一次）。"
        NSUserNotificationCenter.default.deliver(note)
    }

    /// 手动打开系统设置引导授权，并轮询检测；一旦授权完成自动重启本 App
    func openAccessibilitySettings() {
        guard !AppleScriptAutomation.hasAccessibilityPermission() else {
            appendLog("辅助功能已授权", "Accessibility granted")
            return
        }
        AppleScriptAutomation.openAccessibilitySettings()
        appendLog("请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选本 App，授权后会自动重启生效",
                  "Please check this app in System Settings → Privacy & Security → Accessibility; it will restart automatically once granted")
        accessibilityMonitorTimer?.invalidate()
        accessibilityMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AppleScriptAutomation.hasAccessibilityPermission() {
                    self.accessibilityMonitorTimer?.invalidate()
                    self.accessibilityMonitorTimer = nil
                    self.restartAfterAuthorization()
                }
            }
        }
    }

    /// 授权完成：清理子进程并用 launchctl 重启（由 LaunchAgent 管理）
    private func restartAfterAuthorization() {
        appendLog("检测到辅助功能已授权，自动重启生效…", "Accessibility granted detected; restarting to apply…")
        manager.stopOwnServer()
        let uid = getuid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "-k", "gui/\(uid)/com.codexreset.CodexReset"]
        do {
            try proc.run()
        } catch {
            appendLog("自动重启失败，请手动重启：\(error)", "Auto-restart failed; please restart manually: \(error)")
            return
        }
        exit(0)
    }

    // MARK: - 工具

    private func appendLog(_ zh: String, _ en: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stamp = formatter.string(from: Date())
        logLines.append(LogEntry(time: stamp, zh: zh, en: en))
        if logLines.count > 100 { logLines.removeFirst(logLines.count - 100) }
    }

    private func notify(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? AppleScriptAutomation.runAppleScript(
            #"display notification "\#(escapedBody)" with title "\#(escapedTitle)""#
        )
    }

    /// 格式化恢复倒计时
    func countdownText() -> String? {
        guard let primary = rateLimits?.rateLimits.primary,
              let resetsAt = primary.resetsAt else { return nil }
        let now = Date().timeIntervalSince1970
        let remain = Double(resetsAt) - now
        if remain <= 0 { return L("已恢复", "recovered") }
        let totalMinutes = Int(remain) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return L("\(hours)小时\(minutes)分", "\(hours)h \(minutes)m") }
        return L("\(minutes)分钟", "\(minutes)m")
    }
}
