import SwiftUI

/// 强调橙：浅色主题下的主色（按钮/恢复时间高亮），保证白字按钮对比与文字可读
private let highlightOrange = Color(red: 0.72, green: 0.33, blue: 0.10)

/// 主面板：单屏展示用量、倒计时、暂停对话与操作（浅色轻拟物主题）
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 右上角「设置」回调（由 MenuBarController 注入：打开独立设置窗口）
    private let onOpenSettings: (() -> Void)?
    /// 全部对话模块展开状态（默认收起）
    @State private var allExpanded = false
    /// 自定义指令输入区展开状态（默认收起）
    @State private var commandExpanded = false
    /// 当前 Tab：0=概览 1=用量历史 2=日志
    @State private var selectedTab = 0
    /// 是否在概览中显示「全部对话」模块
    @AppStorage("showAllThreads") private var showAllThreads = true

    init(onOpenSettings: (() -> Void)? = nil) {
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // 用量摘要固定在顶部，切换 Tab 时仍保留
            usageSection
            Divider()
            Picker("", selection: $selectedTab) {
                Text(L("概览", "Overview")).tag(0)
                Text(L("用量历史", "Usage History")).tag(1)
                Text(L("日志", "Log")).tag(2)
            }
            .pickerStyle(.segmented)
            // Tab 内容占满剩余高度：顶部对齐，概览内「立即继续」卡片置底
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380, height: 720, alignment: .top)
        // 浅色主题：全不透明浅色背景
        .background(Color(red: 0.95, green: 0.945, blue: 0.93))
        .preferredColorScheme(.light)
        .onAppear { model.refreshAllThreads() }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0: overviewTab
        case 1: historyTab
        default: logTab
        }
    }

    /// 概览：暂停对话 + 全部对话（可隐藏）+ 自动继续模块（沉底）
    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            pausedSection
            Divider()
            if showAllThreads {
                allSection
            }
            // 自动继续卡片始终置底
            Spacer(minLength: 8)
            controlsSection
        }
    }

    /// 用量历史：5 小时窗口时间线
    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("5小时窗口时间线", "5-hour window timeline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("共 \(model.resetHistory.count) 个窗口", "\(model.resetHistory.count) windows"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if model.resetHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("暂无记录", "No records yet"))
                    Text(L("App 启动后每 30 秒采样一次，用量窗口重置时自动记录一个点",
                           "Sampled every 30s after launch; a point is recorded automatically when a usage window resets."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.resetHistory.enumerated()), id: \.element.id) { idx, evt in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(idx == 0 ? Color.blue : Color.gray.opacity(0.6))
                                        .frame(width: 8, height: 8)
                                    if idx < model.resetHistory.count - 1 {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.25))
                                            .frame(width: 2, height: 30)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(L("\(timeText(evt.windowStart)) 窗口开始", "\(timeText(evt.windowStart)) window start"))
                                            .font(.subheadline)
                                        if idx == 0 {
                                            Text(L("当前", "Now"))
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    Text(L("下次重置：\(timeText(evt.nextResetAt)) · 记录时用量 \(Int(evt.usedPercent))%",
                                           "Next reset: \(timeText(evt.nextResetAt)) · usage at record: \(Int(evt.usedPercent))%"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 底部：辅助功能状态（左）+ 退出（右）
    private var footer: some View {
        HStack(spacing: 8) {
            if model.accessibilityAuthorized {
                Label(L("辅助功能已授权", "Accessibility granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(L("辅助功能未授权", "Accessibility not granted"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(L("授权", "Grant")) {
                    model.openAccessibilitySettings()
                }
                .font(.caption)
            }
            Spacer()
            Button(L("退出", "Quit")) {
                model.quit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
    }

    // MARK: - 状态头

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            // 右上角：设置（打开独立设置窗口）
            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("设置", "Settings"))
        }
    }

    private var statusColor: Color {
        guard let primary = model.rateLimits?.rateLimits.primary else { return .gray }
        return primary.usedPercent >= 100 ? .red : (primary.usedPercent >= 80 ? .orange : .green)
    }

    private var statusText: String {
        guard let rl = model.rateLimits else {
            return model.lastError ?? L("连接中…", "Connecting…")
        }
        let used = rl.rateLimits.primary?.usedPercent ?? 0
        if used >= 100 {
            if let cd = model.countdownText() {
                return L("已到用量上限 · \(cd)后恢复", "Usage limit reached · resets in \(cd)")
            }
            return L("已到用量上限", "Usage limit reached")
        }
        return L("用量正常", "Usage OK")
    }

    // MARK: - 用量（固定显示在顶部）

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rl = model.rateLimits {
                windowBar(title: L("5小时用量", "5h usage"), window: rl.rateLimits.primary, color: .orange)
                windowBar(title: L("1周用量", "1 week"), window: rl.rateLimits.secondary, color: .blue)
                HStack {
                    Text(L("计划：", "Plan: ") + (rl.rateLimits.planType ?? "?"))
                    Spacer()
                    if let balance = rl.rateLimits.credits?.balance {
                        Text(L("点数余额：", "Credit balance: ") + balance)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("读取用量中…", "Reading usage…")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func windowBar(title: String, window: RateLimitWindow?, color: Color) -> some View {
        let percent = window?.usedPercent ?? 0
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 64, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .tint(percent >= 100 ? .red : color)
            Text("\(percent)%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Text(resetText(window))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
    }

    private func resetText(_ window: RateLimitWindow?) -> String {
        guard let resetsAt = window?.resetsAt else { return "--" }
        let date = Date(timeIntervalSince1970: Double(resetsAt))
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: - 暂停对话（按项目分组）

    /// 按项目路径分组，保留「最新在前」的原始顺序
    private func groupByProject(_ threads: [PausedThread]) -> [(name: String, threads: [PausedThread])] {
        var order: [(name: String, threads: [PausedThread])] = []
        var seen = Set<String>()
        for paused in threads {
            let key = paused.cwd
            if !seen.contains(key) {
                seen.insert(key)
                let name = key.isEmpty ? L("未分类", "Uncategorized") : (key as NSString).lastPathComponent
                order.append((name, threads.filter { $0.cwd == key }))
            }
        }
        return order
    }

    private var pausedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("暂停的对话（\(model.pausedThreads.count)）", "Paused chats (\(model.pausedThreads.count))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.pausedThreads.isEmpty {
                    let pausedIds = Set(model.pausedThreads.map { $0.threadId })
                    Button(pausedIds.isSubset(of: model.selectedThreadIds)
                           ? L("取消全选", "Clear all")
                           : L("全选", "Select all")) {
                        if pausedIds.isSubset(of: model.selectedThreadIds) {
                            model.selectedThreadIds.subtract(pausedIds)
                        } else {
                            model.selectedThreadIds.formUnion(pausedIds)
                        }
                    }
                    .font(.caption)
                }
            }
            if model.pausedThreads.isEmpty {
                Text(L("未找到因用量暂停的对话", "No usage-paused chats found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 列头
                HStack(spacing: 6) {
                    Text(L("项目", "Project"))
                        .frame(width: 88, alignment: .leading)
                    Text(L("对话", "Chat"))
                    Spacer()
                    Text(L("恢复时间", "Recovery"))
                        .frame(width: 74, alignment: .trailing)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(groupByProject(model.pausedThreads).enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                ForEach(group.threads, id: \.threadId) { paused in
                                    threadRow(paused, showRecovery: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    // MARK: - 全部对话（默认收起，可勾选任意对话参与自动继续）

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // 标题行：点击折叠/展开
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { allExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: allExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(L("全部对话（\(model.allThreads.count)）", "All chats (\(model.allThreads.count))"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(allExpanded
                      ? L("收起", "Collapse")
                      : L("展开全部对话", "Expand all chats"))

                Spacer()

                if allExpanded, !model.allThreads.isEmpty {
                    let allIds = Set(model.allThreads.map { $0.threadId })
                    Button(allIds.isSubset(of: model.selectedThreadIds)
                           ? L("取消全选", "Clear all")
                           : L("全选", "Select all")) {
                        if allIds.isSubset(of: model.selectedThreadIds) {
                            model.selectedThreadIds.subtract(allIds)
                        } else {
                            model.selectedThreadIds.formUnion(allIds)
                        }
                    }
                    .font(.caption)
                }
            }

            if allExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(groupByProject(model.allThreads).enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                ForEach(group.threads, id: \.threadId) { thread in
                                    threadRow(thread, showRecovery: false)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func threadRow(_ paused: PausedThread, showRecovery: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { model.selectedThreadIds.contains(paused.threadId) },
            set: { on in
                if on {
                    model.selectedThreadIds.insert(paused.threadId)
                } else {
                    model.selectedThreadIds.remove(paused.threadId)
                }
            }
        )) {
            HStack(spacing: 6) {
                Text("–")
                    .foregroundStyle(.secondary)
                Text(paused.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showRecovery, let hint = paused.recoveryHint {
                    Text(cleanHint(hint))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(highlightOrange)
                }
            }
            .contentShape(Rectangle())
            // 双击在 Codex 中打开该对话
            .onTapGesture(count: 2) {
                model.openInCodex(threadId: paused.threadId)
            }
            .help(L("双击在 Codex 中打开该对话", "Double-click to open in Codex"))
        }
        .toggleStyle(.checkbox)
    }

    /// 去掉恢复提示末尾的句点，如 "7:27 PM." -> "7:27 PM"
    private func cleanHint(_ hint: String) -> String {
        hint.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    // MARK: - 控制（自动继续模块，轻拟物主卡片：纯白、不使用阴影）

    /// 轻拟物卡片：纯白背景 + 细描边（无渐变、无阴影）
    private func softCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white, Color.black.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }

    private var controlsSection: some View {
        softCard {
            // 主开关：用量恢复后自动继续
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("用量恢复后自动继续", "Auto-continue after usage resets"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(L("用量窗口重置后，自动把指令发送到已勾选的对话",
                           "When the usage window resets, the command is sent to all selected chats automatically."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.autoContinue)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()
                .overlay(Color.black.opacity(0.05))

            // 指令输入（默认收起，点标题展开）
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { commandExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: commandExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(L("指令", "Command"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !commandExpanded, !model.continueCommand.isEmpty {
                            Text(model.continueCommand)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(maxWidth: 140, alignment: .trailing)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("展开自定义指令", "Show custom command"))

                if commandExpanded {
                    TextField(L("继续", "Continue"), text: $model.continueCommand)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }

            // 立即继续（大按钮）
            Button {
                Task { await model.manualContinue() }
            } label: {
                HStack(spacing: 6) {
                    if model.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text(L("继续中…", "Continuing…"))
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text(L("立即继续", "Continue Now"))
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.86, green: 0.45, blue: 0.15), highlightOrange],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .opacity(model.isWorking ? 0.75 : 1)
        }
    }

    // MARK: - 日志 Tab（文案按当前语言显示，切换语言后旧日志也会跟随切换）

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("运行日志", "Activity log"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("共 \(model.logLines.count) 条", "\(model.logLines.count) entries"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if model.logLines.isEmpty {
                Text(L("暂无日志", "No logs yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.logLines.enumerated().reversed()), id: \.offset) { _, entry in
                            Text("[\(entry.time)] \(entry.display)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 400)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.03))
                .cornerRadius(6)
            }
        }
    }
}
