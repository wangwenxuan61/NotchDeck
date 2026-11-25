import Foundation

/// 每百万 token 的美元价格。
struct TokenRates: Equatable {
    var input: Double
    /// 短期缓存写入：Claude 是 5 分钟，OpenAI 是 30 分钟。
    var cacheWrite: Double
    /// 长期缓存写入：Claude 是 1 小时，OpenAI 是 12 小时。
    var cacheWriteLong: Double
    var cacheRead: Double
    var output: Double

    /// Claude 的缓存写入按输入价格的倍数计：5 分钟 1.25 倍，1 小时 2 倍。
    static func claude(_ input: Double, read: Double, output: Double) -> TokenRates {
        TokenRates(input: input, cacheWrite: input * 1.25, cacheWriteLong: input * 2, cacheRead: read, output: output)
    }

    /// OpenAI 没有列出缓存写入价格的模型，按普通输入计。
    static func openAI(_ input: Double, read: Double, output: Double, write: Double? = nil, writeLong: Double? = nil) -> TokenRates {
        TokenRates(input: input, cacheWrite: write ?? input, cacheWriteLong: writeLong ?? write ?? input, cacheRead: read, output: output)
    }

    func scaled(by factor: Double) -> TokenRates {
        TokenRates(input: input * factor, cacheWrite: cacheWrite * factor, cacheWriteLong: cacheWriteLong * factor,
                   cacheRead: cacheRead * factor, output: output * factor)
    }
}

struct ModelPrice {
    var rates: TokenRates
    /// 单次请求的输入（含缓存）超过某一档的门槛时，整次请求按那一档计价。门槛从小到大。
    var tiers: [(above: Int, rates: TokenRates)]
    /// 快速模式的价格倍数，没有快速模式的模型为 nil。
    var fastMultiplier: Double?

    init(rates: TokenRates, longContext: (Int, TokenRates)? = nil, tiers: [(above: Int, rates: TokenRates)] = [], fastMultiplier: Double? = nil) {
        self.rates = rates
        self.tiers = longContext.map { [$0] } ?? tiers
        self.fastMultiplier = fastMultiplier
    }
}

/// 一次请求用到的 token，缓存写入按时长分开，用来算费用。
struct TokenUsage {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cacheWriteLong = 0
    var output = 0
    var fast = false
    /// 指定美国境内处理时价格乘 1.1。
    var regionMultiplier = 1.0

    var prompt: Int { input + cacheRead + cacheWrite + cacheWriteLong }

    var counts: TokenCounts {
        TokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite + cacheWriteLong, output: output)
    }
}

/// 按官方公开的 API 价格估算费用。订阅用户实际不按 token 付费，这里只是换算成等价的 API 价格。
/// 价格来自各家官方价格页（2026 年 11 月）：platform.claude.com/docs/en/about-claude/pricing、developers.openai.com/api/docs/pricing、
/// aistudio.google.com/docs/pricing、docs.z.ai/guides/overview/pricing、platform.kimi.ai/docs/pricing/chat、
/// api-docs.deepseek.com/quick_start/pricing、platform.minimax.io/docs/guides/pricing、alibabacloud.com/help/en/model-studio/model-pricing、docs.x.ai/docs/pricing。
/// 已下架、官方页面上查不到价格的模型不列，费用显示为 —。
/// 改了价格要同时把 TokenUsageStore.file 的版本号加一，已保存的统计才会按新价格重新计算。
enum TokenPricing {
    private static func claude(_ input: Double, read: Double, output: Double, fast: Double? = nil) -> ModelPrice {
        ModelPrice(rates: .claude(input, read: read, output: output), fastMultiplier: fast)
    }

    /// OpenAI 的 GPT-5.6 和 GPT-6：单次输入超过 27.2 万 token 按长上下文价格，快速模式（Codex 里的 priority）全部翻倍。
    /// long 依次是输入、缓存读取、输出、30 分钟写入、12 小时写入。
    private static func openAI(_ input: Double, read: Double, output: Double, write: Double, writeLong: Double,
                               long: (Double, Double, Double, Double, Double)) -> ModelPrice {
        ModelPrice(rates: .openAI(input, read: read, output: output, write: write, writeLong: writeLong),
                   longContext: (272_000, .openAI(long.0, read: long.1, output: long.2, write: long.3, writeLong: long.4)),
                   fastMultiplier: 2)
    }

    /// 没有缓存写入费的模型（Gemini、GLM、DeepSeek、MiniMax、Grok 等）：写缓存按普通输入计。
    private static func api(_ input: Double, read: Double, output: Double, write: Double? = nil, writeLong: Double? = nil,
                            long: (above: Int, input: Double, read: Double, output: Double)? = nil) -> ModelPrice {
        ModelPrice(rates: .openAI(input, read: read, output: output, write: write, writeLong: writeLong),
                   longContext: long.map { ($0.above, .openAI($0.input, read: $0.read, output: $0.output)) })
    }

    /// 通义千问：隐式缓存命中按输入的 20%，创建显式缓存按 125%。按单次输入长度分档。
    private static func qwen(_ tiers: [(above: Int, input: Double, output: Double)]) -> ModelPrice {
        let rates = tiers.map { TokenRates.openAI($0.input, read: $0.input * 0.2, output: $0.output, write: $0.input * 1.25) }
        return ModelPrice(rates: rates[0], tiers: zip(tiers.dropFirst(), rates.dropFirst()).map { ($0.above, $1) })
    }

    /// 从某一天起改价的模型：模型 -> 改价日期和新价格。
    static let changes: [String: (from: String, price: ModelPrice)] = [
        "gemini-4-carbon": ("2026-12-01", api(4, read: 0.2, output: 20)),
        "gemini-4-argon": ("2026-12-01", api(4, read: 0.2, output: 20)),
        "gemini-3.8-flash": ("2027-01-01", api(1.5, read: 0.15, output: 7.5)),
        "gemini-3.6-flash": ("2027-01-01", api(1.5, read: 0.15, output: 7.5)),
    ]

    static let models: [String: ModelPrice] = {
        let opus4 = claude(5, read: 0.5, output: 25)
        let opus41 = claude(15, read: 1.5, output: 75)
        let sonnet4 = claude(3, read: 0.3, output: 15)
        return [
            "claude-fable-5-2": claude(8, read: 0.2, output: 40, fast: 2),
            "claude-mythos-5-2": claude(8, read: 0.2, output: 40, fast: 2),
            "claude-fable-5-1": claude(10, read: 0.25, output: 50),
            "claude-mythos-5-1": claude(10, read: 0.25, output: 50),
            "claude-fable-5": claude(10, read: 1, output: 50),
            "claude-mythos-5": claude(10, read: 1, output: 50),
            "claude-opus-5-5": claude(4, read: 0.2, output: 20, fast: 2),
            "claude-opus-5": claude(5, read: 0.5, output: 25, fast: 2),
            "claude-opus-4-8": claude(5, read: 0.5, output: 25, fast: 2),
            "claude-opus-4-7": opus4,
            "claude-opus-4-6": opus4,
            "claude-opus-4-5": opus4,
            "claude-opus-4-1": opus41,
            "claude-opus-4": opus41,
            "claude-sonnet-5-5": claude(2, read: 0.1, output: 10),
            "claude-sonnet-5": claude(2, read: 0.2, output: 10),
            "claude-sonnet-4-6": sonnet4,
            "claude-sonnet-4-5": sonnet4,
            "claude-sonnet-4": sonnet4,
            "claude-haiku-5-5": ModelPrice(rates: .claude(0.1, read: 0.01, output: 0.5),
                                           longContext: (100_000, .claude(0.5, read: 0.05, output: 2.5))),
            "claude-haiku-4-5": claude(1, read: 0.1, output: 5),
            "gpt-5.6-sol": openAI(4, read: 0.4, output: 20, write: 5, writeLong: 10, long: (8, 0.8, 30, 10, 20)),
            "gpt-5.6-terra": openAI(2, read: 0.2, output: 12, write: 2.5, writeLong: 5, long: (4, 0.4, 18, 5, 10)),
            "gpt-5.6-luna": openAI(0.2, read: 0.02, output: 1.2, write: 0.25, writeLong: 0.5, long: (0.4, 0.04, 1.8, 0.5, 1)),
            "gpt-6-astra": openAI(10, read: 1, output: 50, write: 12.5, writeLong: 25, long: (20, 2, 75, 25, 50)),
            "gpt-6.1-sol": openAI(2, read: 0.1, output: 10, write: 2.5, writeLong: 5, long: (4, 0.2, 15, 5, 10)),
            "gpt-6.1-terra": openAI(1, read: 0.05, output: 5, write: 1.25, writeLong: 2.5, long: (2, 0.1, 7.5, 2.5, 5)),
            "gpt-6-sol": openAI(2, read: 0.2, output: 10, write: 2.5, writeLong: 5, long: (4, 0.4, 15, 5, 10)),
            "gpt-6-luna": openAI(0.1, read: 0.01, output: 0.5, write: 0.125, writeLong: 0.25, long: (0.2, 0.02, 0.75, 0.25, 0.5)),
            "gpt-5.5": ModelPrice(rates: .openAI(5, read: 0.5, output: 30),
                                  longContext: (272_000, .openAI(10, read: 1, output: 45)), fastMultiplier: 2.5),
            "gpt-5.5-pro": ModelPrice(rates: .openAI(30, read: 30, output: 180),
                                      longContext: (272_000, .openAI(60, read: 60, output: 270))),
            "gpt-5.4": ModelPrice(rates: .openAI(2.5, read: 0.25, output: 15),
                                  longContext: (272_000, .openAI(5, read: 0.5, output: 22.5)), fastMultiplier: 2),
            // 单独列出，否则会按前缀匹配到 gpt-5.4 的价格。
            "gpt-5.4-mini": ModelPrice(rates: .openAI(0.75, read: 0.075, output: 4.5), fastMultiplier: 2),
            "gpt-5.3-codex": ModelPrice(rates: .openAI(1.75, read: 0.175, output: 14), fastMultiplier: 2),
            // Google Gemini，思考 token 按输出计。
            "gemini-4-neon": api(3, read: 0.15, output: 15),
            "gemini-4-hydrogen": api(1.5, read: 0.075, output: 7.5),
            "gemini-4-carbon": api(2, read: 0.1, output: 10),
            "gemini-4-argon": api(2, read: 0.1, output: 10),
            "gemini-3.8-flash": api(0.75, read: 0.075, output: 3.75),
            "gemini-3.6-flash": api(0.75, read: 0.075, output: 3.75),
            "gemini-3.5-flash-lite": api(0.3, read: 0.03, output: 2.5),
            "gemini-3.1-pro-preview": api(2, read: 0.2, output: 12, long: (200_000, 4, 0.4, 18)),
            "gemini-3.1-flash-lite": api(0.25, read: 0.025, output: 1.5),
            "gemini-3-flash-preview": api(0.5, read: 0.05, output: 3),
            "gemini-2.5-pro": api(1.25, read: 0.125, output: 10, long: (200_000, 2.5, 0.25, 15)),
            "gemini-2.5-flash": api(0.3, read: 0.03, output: 2.5),
            "gemini-2.5-flash-lite": api(0.1, read: 0.01, output: 0.4),
            // 智谱 GLM（Z.ai 国际版）。
            "glm-5.3": api(1.4, read: 0.26, output: 4.4),
            "glm-5.2": api(1.4, read: 0.26, output: 4.4),
            "glm-5.1": api(1.4, read: 0.26, output: 4.4),
            "glm-5.3-flashx": api(0.37, read: 0.075, output: 1.25),
            "glm-5.3-flash": api(0.15, read: 0.03, output: 0.5),
            "glm-5": api(1, read: 0.2, output: 3.2),
            "glm-4.7": api(0.6, read: 0.11, output: 2.2),
            "glm-4.6": api(0.6, read: 0.11, output: 2.2),
            "glm-4.5": api(0.6, read: 0.11, output: 2.2),
            "glm-4.7-flashx": api(0.07, read: 0.01, output: 0.4),
            "glm-4.7-flash": api(0, read: 0, output: 0),
            "glm-4.5-flash": api(0, read: 0, output: 0),
            "glm-4.5-x": api(2.2, read: 0.45, output: 8.9),
            "glm-4.5-air": api(0.2, read: 0.03, output: 1.1),
            "glm-4.5-airx": api(1.1, read: 0.22, output: 4.5),
            // Kimi，K3 的缓存写入分 5 分钟和 1 小时。
            "kimi-k3.1-pro": api(2, read: 0.2, output: 10, write: 2, writeLong: 4),
            "kimi-k3.1-pro-highspeed": api(4, read: 0.2, output: 20, write: 4, writeLong: 8),
            "kimi-k3": api(3, read: 0.3, output: 15, write: 3, writeLong: 6),
            "kimi-k2.7-code": api(0.95, read: 0.19, output: 4),
            "kimi-k2.7-code-highspeed": api(1.9, read: 0.38, output: 8),
            "kimi-k2.6": api(0.95, read: 0.16, output: 4),
            // DeepSeek 按非高峰价格算，工作日高峰时段（UTC 1–4 点、6–10 点）实际是两倍。
            "deepseek-flash": api(0.15, read: 0.003, output: 0.6),
            "deepseek-v4-flash": api(0.15, read: 0.003, output: 0.6),
            "deepseek-v4-pro": api(0.66, read: 0.022, output: 1.98),
            "minimax-m3.1-flash": api(0.15, read: 0.015, output: 0.6),
            "minimax-m3": api(0.3, read: 0.06, output: 1.2, long: (512_000, 0.6, 0.12, 2.4)),
            // 通义千问的 max 系列不按缓存折扣比例，官方没给缓存价格，按普通输入算。
            "qwen3-coder-flash": qwen([(0, 0.3, 1.5), (32_000, 0.5, 2.5), (128_000, 0.8, 4), (256_000, 1.6, 9.6)]),
            "qwen3.7-plus": qwen([(0, 0.4, 1.6), (256_000, 1.2, 4.8)]),
            "qwen3.6-plus": qwen([(0, 0.5, 3), (256_000, 2, 6)]),
            "qwen3.5-plus": qwen([(0, 0.4, 2.4), (256_000, 0.5, 3)]),
            "qwen4-max": api(1.5, read: 1.5, output: 4.5),
            "qwen3.8-max": api(2, read: 2, output: 6),
            "qwen3.7-max": api(2.5, read: 2.5, output: 7.5),
            // xAI，单次输入达到 20 万整次按高价。
            "grok-4.7": api(2, read: 0.5, output: 6, long: (199_999, 4, 1, 12)),
            "grok-4.6": api(2, read: 0.5, output: 6, long: (199_999, 4, 1, 12)),
            "grok-4.5": api(2, read: 0.3, output: 6, long: (199_999, 4, 0.6, 12)),
            "grok-4.3": api(1.25, read: 0.2, output: 2.5, long: (199_999, 2.5, 0.4, 5)),
            "grok-4.20": api(1.25, read: 0.2, output: 2.5, long: (199_999, 2.5, 0.4, 5)),
        ]
    }()

    /// 按最长的前缀匹配，带日期后缀的名字（比如 claude-haiku-4-5-20251001）也能找到价格。
    /// 不分大小写，去掉 openrouter/z-ai/ 这类服务商前缀；有的工具把 claude-sonnet-4-5 写成 claude-sonnet-4.5。
    /// day 是用量发生的日期，用来认出到某天改价的模型。
    static func price(for model: String, day: String = "") -> ModelPrice? {
        if let exact = models[model], changes[model] == nil { return exact }
        var name = model.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasPrefix("claude-") { name = name.replacingOccurrences(of: ".", with: "-") }
        let key = models[name] != nil ? name : models.keys.filter { name.hasPrefix($0 + "-") }.max { $0.count < $1.count }
        guard let key else { return nil }
        if let change = changes[key], day >= change.from { return change.price }
        return models[key]
    }

    /// 没有这个模型的价格时返回 nil。
    static func cost(of usage: TokenUsage, model: String, day: String = "") -> Double? {
        guard let price = price(for: model, day: day) else { return nil }
        var rates = price.rates
        if let tier = price.tiers.last(where: { usage.prompt > $0.above }) { rates = tier.rates }
        if usage.fast, let multiplier = price.fastMultiplier { rates = rates.scaled(by: multiplier) }
        let dollars = Double(usage.input) * rates.input
            + Double(usage.cacheWrite) * rates.cacheWrite
            + Double(usage.cacheWriteLong) * rates.cacheWriteLong
            + Double(usage.cacheRead) * rates.cacheRead
            + Double(usage.output) * rates.output
        return dollars / 1_000_000 * usage.regionMultiplier
    }
}
