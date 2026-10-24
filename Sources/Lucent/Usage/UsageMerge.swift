import Foundation

// 把同一工具的多个账号用量加成一份合计。只有一个账号时原样返回，数字不经过第二遍加工。
// 5 小时窗口按账号各自算好后再选：合计的 currentBlock 取还开着的窗口里 projectedTokens 最大的那个。

enum UsageMerge {
    static func combine(_ parts: [ToolUsage]) -> ToolUsage? {
        guard let first = parts.first else { return nil }
        if parts.count == 1 { return first }

        var result = first
        result.today = first.today
        result.daily = sumDaily(parts.map(\.daily))
        if let today = result.daily.last { result.today = today }
        result.models = sumModels(parts.map(\.models))
        result.history = sumDaily(parts.map(\.history))
        result.hourly = sumHourly(parts.map(\.hourly))
        result.recentRequests = sumRequests(parts.map(\.recentRequests))
        result.projects = sumProjects(parts.map(\.projects))
        result.hourlyDetail = sumBuckets(parts.map(\.hourlyDetail))
        result.dailyDetail = sumBuckets(parts.map(\.dailyDetail))
        result.pricing = sumPricing(parts.map(\.pricing))
        result.tokensPerMinute = parts.reduce(0) { $0 + $1.tokensPerMinute }
        result.lastActivity = parts.compactMap(\.lastActivity).max()
        result.status = mergeStatus(parts.map(\.status))
        result.plan = parts.compactMap(\.plan).first

        let stressed = parts.filter { $0.currentBlock != nil }.max { lhs, rhs in
            let lp = lhs.currentBlock?.projectedTokens ?? 0
            let rp = rhs.currentBlock?.projectedTokens ?? 0
            if lp != rp { return lp < rp }
            return (lhs.currentBlock?.tokens.total ?? 0) < (rhs.currentBlock?.tokens.total ?? 0)
        }
        let peakSource = parts.max { $0.peakBlockTokens < $1.peakBlockTokens }
        result.currentBlock = stressed?.currentBlock
        result.recentBlocks = (stressed ?? peakSource)?.recentBlocks ?? []
        result.peakBlockTokens = peakSource?.peakBlockTokens ?? 0
        if let quotaSource = stressed ?? parts.first(where: { !$0.quotas.isEmpty }) ?? parts.first {
            result.quotas = quotaSource.quotas
            result.quotaUpdatedAt = quotaSource.quotaUpdatedAt
        }
        return result
    }

    private static func sumDaily(_ lists: [[DailyUsage]]) -> [DailyUsage] {
        var map: [Date: DailyUsage] = [:]
        for list in lists {
            for day in list {
                if var existing = map[day.day] {
                    existing.tokens = existing.tokens + day.tokens
                    existing.cost += day.cost
                    existing.requests += day.requests
                    existing.cacheSavings += day.cacheSavings
                    existing.cacheWrite1h += day.cacheWrite1h
                    map[day.day] = existing
                } else {
                    map[day.day] = day
                }
            }
        }
        return map.values.sorted { $0.day < $1.day }
    }

    private static func sumHourly(_ lists: [[HourlyUsage]]) -> [HourlyUsage] {
        var map: [Date: HourlyUsage] = [:]
        for list in lists {
            for hour in list {
                if var existing = map[hour.hour] {
                    existing.tokens = existing.tokens + hour.tokens
                    existing.cost += hour.cost
                    existing.requests += hour.requests
                    map[hour.hour] = existing
                } else {
                    map[hour.hour] = hour
                }
            }
        }
        return map.values.sorted { $0.hour < $1.hour }
    }

    private static func sumModels(_ lists: [[ModelShare]]) -> [ModelShare] {
        var map: [String: ModelShare] = [:]
        for list in lists {
            for model in list {
                if var existing = map[model.model] {
                    existing.tokens += model.tokens
                    existing.cost += model.cost
                    existing.detail = existing.detail + model.detail
                    existing.requests += model.requests
                    map[model.model] = existing
                } else {
                    map[model.model] = model
                }
            }
        }
        return map.values.sorted { $0.tokens > $1.tokens }
    }

    private static func sumProjects(_ lists: [[ProjectShare]]) -> [ProjectShare] {
        var map: [String: ProjectShare] = [:]
        for list in lists {
            for project in list {
                let key = project.tool.rawValue + "/" + project.project
                if var existing = map[key] {
                    existing.tokens = existing.tokens + project.tokens
                    existing.cost += project.cost
                    existing.requests += project.requests
                    if let last = project.lastActive, existing.lastActive == nil || last > existing.lastActive! {
                        existing.lastActive = last
                    }
                    map[key] = existing
                } else {
                    map[key] = project
                }
            }
        }
        return map.values.sorted { $0.tokens.total > $1.tokens.total }.prefix(50).map { $0 }
    }

    private static func sumBuckets(_ lists: [[UsageBucket]]) -> [UsageBucket] {
        var map: [String: UsageBucket] = [:]
        for list in lists {
            for bucket in list {
                if var existing = map[bucket.id] {
                    existing.tokens = existing.tokens + bucket.tokens
                    existing.cost += bucket.cost
                    existing.requests += bucket.requests
                    existing.cacheSavings += bucket.cacheSavings
                    existing.cacheWrite1h += bucket.cacheWrite1h
                    existing.timedOutputTokens += bucket.timedOutputTokens
                    existing.timedDurationMs += bucket.timedDurationMs
                    map[bucket.id] = existing
                } else {
                    map[bucket.id] = bucket
                }
            }
        }
        return map.values.sorted { $0.start < $1.start }
    }

    private static func sumRequests(_ lists: [[UsageRequest]]) -> [UsageRequest] {
        var map: [String: UsageRequest] = [:]
        for list in lists {
            for request in list {
                if let old = map[request.id] {
                    if request.tokens.total >= old.tokens.total { map[request.id] = request }
                } else {
                    map[request.id] = request
                }
            }
        }
        return map.values.sorted { $0.time > $1.time }.prefix(300).map { $0 }
    }

    private static func sumPricing(_ lists: [[PricingEntry]]) -> [PricingEntry] {
        var seen = Set<String>()
        var result: [PricingEntry] = []
        for list in lists {
            for entry in list where seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    private static func mergeStatus(_ all: [UsageStatus]) -> UsageStatus {
        if all.allSatisfy({ if case .notInstalled = $0 { return true }; return false }) { return .notInstalled }
        let hasOK = all.contains { if case .ok = $0 { return true }; return false }
        if hasOK {
            if let partial = all.first(where: { if case .partial = $0 { return true }; return false }) { return partial }
            return .ok
        }
        if let failed = all.first(where: { if case .failed = $0 { return true }; return false }) { return failed }
        if let partial = all.first(where: { if case .partial = $0 { return true }; return false }) { return partial }
        return .loading
    }
}
