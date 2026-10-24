import Foundation

// 5 小时用量窗口。分窗规则来自 ccusage（MIT）的 session blocks：
// https://github.com/ryoppippi/ccusage  identifySessionBlocks / floorToHour
//
// 按请求时间升序。窗口从该窗第一条请求所在的本地整点起，长度刚好 5 小时（end = start + 5h）。
// 下一条的时间 >= end，或与上一条间隔 > 5 小时，就另起新窗口，新窗口同样从那条请求的整点起。
//
// tokensPerMinute：从 start 到 min(now, lastActivity) 的平均每分钟 token。
// costPerHour：同一段时间上的每小时金额。
// 活跃（now < end）时，projected = 已发生的量 + 这个速率从 now 外推到 end；
// 已经结束的窗口 projected 就是实际值。
//
// 调用方传入已经聚合好的逐条（或逐小时）事件，这里不再读盘。
// Codex sqlite 补上的历史没有逐条时间，不要放进来。

enum UsageBlocks {
    static let duration: TimeInterval = 5 * 3600

    struct Event: Sendable {
        var time: Date
        var tokens: TokenCounts
        var cost: Double
        var requests: Int
    }

    static func summarize(_ events: [Event], now: Date = Date()) -> (current: UsageBlock?, recent: [UsageBlock], peak: Int64) {
        let sorted = events.sorted { $0.time < $1.time }
        var built: [UsageBlock] = []
        built.reserveCapacity(sorted.count / 4 + 1)

        for event in sorted {
            if event.requests == 0 && event.tokens.total == 0 { continue }
            let openNew: Bool
            if let last = built.last {
                let gap = event.time.timeIntervalSince(last.lastActivity)
                openNew = event.time >= last.end || gap > duration
            } else {
                openNew = true
            }
            if openNew {
                let start = floorToLocalHour(event.time)
                built.append(UsageBlock(
                    start: start,
                    end: start.addingTimeInterval(duration),
                    lastActivity: event.time,
                    tokens: event.tokens,
                    cost: event.cost,
                    requests: event.requests,
                    isActive: false,
                    tokensPerMinute: 0,
                    costPerHour: 0,
                    projectedTokens: 0,
                    projectedCost: 0))
            } else {
                var last = built[built.count - 1]
                last.tokens = last.tokens + event.tokens
                last.cost += event.cost
                last.requests += event.requests
                if event.time > last.lastActivity { last.lastActivity = event.time }
                built[built.count - 1] = last
            }
        }

        let finalized = built.map { decorate($0, now: now) }
        let recentCutoff = now.addingTimeInterval(-7 * 86400)
        let peakCutoff = now.addingTimeInterval(-30 * 86400)
        let recent = finalized.filter { $0.start >= recentCutoff }.sorted { $0.start > $1.start }
        let peak = finalized.filter { $0.start >= peakCutoff }.map(\.tokens.total).max() ?? 0
        let current = finalized.last(where: \.isActive)
        return (current, recent, peak)
    }

    /// 逐小时桶当成「这一小时的起点发生过这些量」。整点对齐的 5 小时窗口用这个就够，不用再扫盘。
    static func summarize(hours: [String: HourBucket], now: Date = Date()) -> (current: UsageBlock?, recent: [UsageBlock], peak: Int64) {
        let events: [Event] = hours.compactMap { key, bucket in
            guard bucket.requests > 0 || bucket.tokens.total > 0, let time = date(forHourKey: key) else { return nil }
            return Event(time: time, tokens: bucket.tokens.asTokenCounts, cost: bucket.cost, requests: bucket.requests)
        }
        return summarize(events, now: now)
    }

    private static func decorate(_ raw: UsageBlock, now: Date) -> UsageBlock {
        var block = raw
        let active = now < block.end
        block.isActive = active
        let measureEnd = min(now, block.lastActivity)
        let elapsed = measureEnd.timeIntervalSince(block.start)
        if elapsed >= 1 {
            block.tokensPerMinute = Double(block.tokens.total) / (elapsed / 60)
            block.costPerHour = block.cost / (elapsed / 3600)
        } else {
            block.tokensPerMinute = 0
            block.costPerHour = 0
        }
        if active {
            let remainingMin = block.end.timeIntervalSince(now) / 60
            let extraTokens = block.tokensPerMinute * remainingMin
            let extraCost = block.costPerHour * (remainingMin / 60)
            block.projectedTokens = saturatingAdd(block.tokens.total, extraTokens)
            block.projectedCost = extraCost.isFinite ? block.cost + extraCost : block.cost
        } else {
            block.projectedTokens = block.tokens.total
            block.projectedCost = block.cost
        }
        return block
    }

    private static func saturatingAdd(_ base: Int64, _ extra: Double) -> Int64 {
        guard extra.isFinite else { return base }
        if extra >= Double(Int64.max) { return Int64.max }
        if extra <= Double(Int64.min) { return base }
        let (sum, overflow) = base.addingReportingOverflow(Int64(extra))
        if overflow { return extra < 0 ? base : Int64.max }
        return sum
    }

    private static func floorToLocalHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: parts) ?? date
    }
}
