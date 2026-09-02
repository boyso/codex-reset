import AppKit

// 全局持有 AppModel，供信号处理器做退出清理
var globalModel: AppModel?

// 优雅退出：先停掉自起的 app-server 子进程
signal(SIGTERM) { _ in
    Task { @MainActor in
        globalModel?.stopAndExit()
    }
}
signal(SIGINT) { _ in
    Task { @MainActor in
        globalModel?.stopAndExit()
    }
}
signal(SIGHUP) { _ in
    Task { @MainActor in
        globalModel?.stopAndExit()
    }
}

// 无头模式：--continue <threadId> 立即继续指定线程后退出
if let idx = CommandLine.arguments.firstIndex(of: "--continue"), idx + 1 < CommandLine.arguments.count {
    let threadId = CommandLine.arguments[idx + 1]
    Task { @MainActor in
        let model = AppModel()
        await model.runHeadlessContinue(threadId: threadId)
        exit(0)
    }
    dispatchMain()
}

// 无头模式：--query 打印用量与暂停线程后退出（便于脚本/调试）
if CommandLine.arguments.contains("--query") {
    Task { @MainActor in
        let model = AppModel()
        await model.runHeadlessQuery()
        exit(0)
    }
    dispatchMain()
}

// 菜单栏应用入口（无 Dock 图标）。
// 顶层代码运行在主线程，用 assumeIsolated 满足 Swift 6 的 MainActor 隔离检查。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let model = AppModel()
    globalModel = model
    let menuBarController = MenuBarController(model: model)
    model.start()
    _ = menuBarController
    app.run()
}
