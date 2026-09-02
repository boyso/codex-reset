import AppKit
import SwiftUI
import Combine

/// 菜单栏控制器：状态图标 + 弹出面板
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var titleTimer: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        setup()
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "Codex…"
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "Codex 用量监控"
        }

        let rootView = ContentView().environmentObject(model)
        let hosting = NSHostingController(rootView: rootView)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 760)
        popover.behavior = .transient
        popover.contentViewController = hosting

        // 数据变化时刷新标题
        model.$rateLimits
            .combineLatest(model.$connectionMode)
            .sink { [weak self] _, _ in
                Task { @MainActor in self?.updateTitle() }
            }
            .store(in: &cancellables)

        // 每秒刷新倒计时
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        switch model.connectionMode {
        case "connecting":
            button.title = "Codex…"
            return
        case "none":
            button.title = "Codex ⚠️"
            return
        default:
            break
        }
        guard let primary = model.rateLimits?.rateLimits.primary else {
            button.title = "Codex…"
            return
        }
        let limited = primary.usedPercent >= 100
        if limited {
            if let countdown = model.countdownText() {
                button.title = "⏳ \(countdown)"
            } else {
                button.title = "⏳ 已到上限"
            }
        } else {
            button.title = "Codex \(primary.usedPercent)%"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
