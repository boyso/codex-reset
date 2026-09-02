import Foundation

/// 用量窗口（primary=5小时，secondary=1周）
struct RateLimitWindow: Decodable {
    /// 已用百分比 0-100
    let usedPercent: Int
    /// 恢复时间（Unix 秒）
    let resetsAt: Int?
    /// 窗口时长（分钟）：300=5小时, 10080=1周
    let windowDurationMins: Int?
}

/// 点数余额
struct CreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

/// 单个限额快照
struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
    /// rate_limit_reached / workspace_owner_usage_limit_reached 等
    let rateLimitReachedType: String?
    let spendControlReached: Bool?
}

/// account/rateLimits/read 响应
struct AccountRateLimits: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

// MARK: - 线程相关

/// thread/read 返回的线程信息
struct ThreadInfo: Decodable {
    let id: String
    let name: String?
    let preview: String?
    let cwd: String?
    let path: String?
    let source: String?
    let status: ThreadStatus?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, preview, cwd, path, source, status, updatedAt
    }

    struct ThreadStatus: Decodable {
        let type: String
    }
}

struct ThreadReadResult: Decodable {
    let thread: ThreadInfo
}

/// turn/start 启动结果
struct TurnStartResult: Decodable {
    struct Turn: Decodable {
        let id: String
        let status: String
        let error: TurnError?
    }
    struct TurnError: Decodable {
        let codexErrorInfo: String?
        let message: String?
    }
    let turn: Turn
}

// MARK: - 用量历史

/// 一次 5 小时用量窗口（时间线上的一个点）
struct UsageResetEvent: Codable, Identifiable {
    let id: UUID
    /// 窗口开始时间（= 上次重置点）
    let windowStart: Date
    /// 下次重置时间
    let nextResetAt: Date
    /// 记录时的用量百分比
    let usedPercent: Double
    /// 检测到的时间
    let detectedAt: Date

    init(windowStart: Date, nextResetAt: Date, usedPercent: Double, detectedAt: Date = Date()) {
        self.id = UUID()
        self.windowStart = windowStart
        self.nextResetAt = nextResetAt
        self.usedPercent = usedPercent
        self.detectedAt = detectedAt
    }
}

