import SwiftUI

/// 高亮橙：深色面板上恢复时间的醒目色（避免系统橙饱和度过低看不清）
private let highlightOrange = Color(red: 1.0, green: 0.72, blue: 0.28)

/// 主面板：单屏展示用量、倒计时、暂停对话与操作（深色主题）
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 日志区展开状态（默认收起）
    @State private var logExpanded = false
    /// 当前 Tab：0=概览 1=用量历史
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $selectedTab) {
                Text("概览").tag(0)
                Text("用量历史").tag(1)
            }
            .pickerStyle(.segmented)
            if selectedTab == 0 {
                overviewTab
            } else {
                historyTab
            }
            Divider()
            logSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshAllThreads() }
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            usageSection
            Divider()
            pausedSection
            Divider()
            allSection
            Divider()
            controlsSection
        }
    }

    /// 用量历史：5 小时窗口时间线
    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("5小时窗口时间线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("共 \(model.resetHistory.count) 个窗口")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if model.resetHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂无记录")
                    Text("App 启动后每 30 秒采样一次，用量窗口重置时自动记录一个点")
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
                                        Text(timeText(evt.windowStart) + " 窗口开始")
                                            .font(.subheadline)
                                        if idx == 0 {
                                            Text("当前")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    Text("下次重置：\(timeText(evt.nextResetAt)) · 记录时用量 \(Int(evt.usedPercent))%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 430)
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("退出 CodexReset") {
                model.quit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 状态头

    private var header: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.headline)
            Spacer()
        }
    }

    private var statusColor: Color {
        guard let primary = model.rateLimits?.rateLimits.primary else { return .gray }
        return primary.usedPercent >= 100 ? .red : (primary.usedPercent >= 80 ? .orange : .green)
    }

    private var statusText: String {
        guard let rl = model.rateLimits else {
            return model.lastError ?? "连接中…"
        }
        let used = rl.rateLimits.primary?.usedPercent ?? 0
        if used >= 100 {
            return "已到用量上限 · \(model.countdownText() ?? "")后恢复"
        }
        return "用量正常"
    }

    // MARK: - 用量

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rl = model.rateLimits {
                windowBar(title: "5小时用量", window: rl.rateLimits.primary, color: .orange)
                windowBar(title: "1周用量", window: rl.rateLimits.secondary, color: .blue)
                HStack {
                    Text("计划：\(rl.rateLimits.planType ?? "?")")
                    Spacer()
                    if let balance = rl.rateLimits.credits?.balance {
                        Text("点数余额：\(balance)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("读取用量中…").font(.caption).foregroundStyle(.secondary)
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
                let name = key.isEmpty ? "未分类" : (key as NSString).lastPathComponent
                order.append((name, threads.filter { $0.cwd == key }))
            }
        }
        return order
    }

    private var pausedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("暂停的对话（\(model.pausedThreads.count)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.pausedThreads.isEmpty {
                    let pausedIds = Set(model.pausedThreads.map { $0.threadId })
                    Button(pausedIds.isSubset(of: model.selectedThreadIds) ? "取消全选" : "全选") {
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
                Text("未找到因用量暂停的对话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 列头
                HStack(spacing: 6) {
                    Text("项目")
                        .frame(width: 88, alignment: .leading)
                    Text("对话")
                    Spacer()
                    Text("恢复时间")
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

    // MARK: - 全部对话（按项目分组，可勾选任意对话参与自动继续）

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("全部对话（\(model.allThreads.count)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.allThreads.isEmpty {
                    let allIds = Set(model.allThreads.map { $0.threadId })
                    Button(allIds.isSubset(of: model.selectedThreadIds) ? "取消全选" : "全选") {
                        if allIds.isSubset(of: model.selectedThreadIds) {
                            model.selectedThreadIds.subtract(allIds)
                        } else {
                            model.selectedThreadIds.formUnion(allIds)
                        }
                    }
                    .font(.caption)
                }
            }
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
            .frame(maxHeight: 240)
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
            .help("双击在 Codex 中打开该对话")
        }
        .toggleStyle(.checkbox)
    }

    /// 去掉恢复提示末尾的句点，如 "7:27 PM." -> "7:27 PM"
    private func cleanHint(_ hint: String) -> String {
        hint.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    // MARK: - 控制（轻拟物主卡片）

    /// 轻拟物卡片：顶部高光渐变 + 细描边 + 柔和投影
    private func softCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.11), Color.white.opacity(0.035)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
    }

    private var controlsSection: some View {
        softCard {
            // 主开关：用量恢复后自动继续
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(autoContinueOn ? highlightOrange : Color.gray)
                    .shadow(color: highlightOrange.opacity(0.5), radius: autoContinueOn ? 6 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("用量恢复后自动继续")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("用量窗口重置后，自动把指令发送到已勾选的对话")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.autoContinue)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            // 指令 + 立即继续
            HStack(spacing: 8) {
                Text("指令")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("继续", text: $model.continueCommand)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                Spacer()
                Button {
                    Task { await model.manualContinue() }
                } label: {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                            .frame(width: 88)
                    } else {
                        Label("立即继续", systemImage: "paperplane.fill")
                            .font(.caption)
                            .frame(width: 88)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(highlightOrange)
                .disabled(model.isWorking)
            }

            // 辅助功能状态（仅 GUI 兜底通道需要）
            HStack(spacing: 6) {
                if model.accessibilityAuthorized {
                    Label("辅助功能已授权", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("辅助功能未授权（GUI 兜底用）", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("授权") {
                        model.openAccessibilitySettings()
                    }
                    .font(.caption)
                }
                Spacer()
                Text("发送快捷键 Cmd+Enter")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)

            // remote_control 开关（副标题说明）
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Binding(
                    get: { model.remoteControlEnabled },
                    set: { model.setRemoteControl($0) }
                )) {
                    Text("remote_control")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text("通过 Codex 本地协议继续对话：重启 Codex 后生效，无需辅助功能授权")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 自动继续开关状态（用于图标高亮）
    private var autoContinueOn: Bool { model.autoContinue }

    // MARK: - 日志（默认收起，点击标题展开）

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                logExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: logExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let last = model.logLines.last {
                        Text(last)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if logExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
            }
        }
    }
}
