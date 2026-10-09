import SwiftUI

/// 独立设置窗口内容（右上角齿轮打开，避免在面板内做遮罩）
struct SettingsPanelView: View {
    @EnvironmentObject var model: AppModel
    /// 是否在概览中显示「全部对话」模块
    @AppStorage("showAllThreads") private var showAllThreads = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.72, green: 0.33, blue: 0.10))
                Text(L("设置", "Settings"))
                    .font(.headline)
            }
            settingsCard
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(red: 0.95, green: 0.945, blue: 0.93))
    }

    /// 语言选择绑定到 AppModel.language（切换后经 objectWillChange 刷新全界面）
    private var languageBinding: Binding<String> {
        Binding(
            get: { self.model.language },
            set: { self.model.language = $0 }
        )
    }

    /// 白色圆角卡片，装设置项
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 显示全部对话
            HStack(spacing: 10) {
                Text(L("显示全部对话", "Show all chats"))
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: $showAllThreads)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .help(L("在概览中显示全部对话，可勾选任意对话参与自动继续",
                    "Show all chats in Overview so any chat can be selected for auto-continue."))

            Divider()
                .overlay(Color.black.opacity(0.05))

            // 语言
            HStack(spacing: 10) {
                Text(L("语言", "Language"))
                    .font(.subheadline)
                Spacer()
                Picker("", selection: languageBinding) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                .frame(width: 205)
            }

            Divider()
                .overlay(Color.black.opacity(0.05))

            // Scoped idle-sleep prevention for selected waiting/running chats
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $model.keepAwakeForSelectedTasks) {
                    Text(L("等待恢复时防止睡眠", "Prevent sleep while waiting"))
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(L("只在已勾选的任务等待额度恢复或正在执行时，防止 Mac 因空闲进入系统睡眠；结束后自动恢复正常睡眠。显示器仍可熄灭。",
                       "Keep your Mac awake only while a selected task is waiting for quota or running. Normal idle sleep returns automatically afterward; the display may still turn off."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.keepAwakeForSelectedTasks {
                    Label(
                        model.idleSleepPreventionActive
                            ? L("正在保持唤醒", "Keeping Mac awake")
                            : L("待命：没有需要保持唤醒的任务", "Standby: no task requires wakefulness"),
                        systemImage: model.idleSleepPreventionActive ? "moon.zzz.slash" : "moon.zzz"
                    )
                    .font(.caption2)
                    .foregroundStyle(model.idleSleepPreventionActive ? Color.green : Color.secondary)
                }

                Text(L("可能增加耗电；不会阻止合盖、手动睡眠或电池耗尽。",
                       "May use more battery. Does not prevent lid-close sleep, manual sleep or battery depletion."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .overlay(Color.black.opacity(0.05))

            // remote_control
            VStack(alignment: .leading, spacing: 3) {
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
                Text(L("通过 Codex 本地协议继续对话：重启 Codex 后生效，无需辅助功能授权",
                       "Continues chats via Codex's local protocol: takes effect after Codex restarts, no accessibility permission needed."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
    }
}
