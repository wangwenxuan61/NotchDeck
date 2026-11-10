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
    /// 单次请求的输入（含缓存）超过 threshold 时整次请求按 rates 计价。
    var longContext: (threshold: Int, rates: TokenRates)?
    /// 快速模式的价格倍数，没有快速模式的模型为 nil。
    var fastMultiplier: Double?
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
/// 价格来自 platform.claude.com/docs/en/about-claude/pricing 和 developers.openai.com/api/docs/pricing（2026 年 11 月）。
/// 改了价格要同时把 TokenUsageStore.file 的版本号加一，已保存的统计才会按新价格重新计算。
enum TokenPricing {
    private static func claude(_ input: Double, read: Double, output: Double, fast: Double? = nil) -> ModelPrice {
        ModelPrice(rates: .claude(input, read: read, output: output), fastMultiplier: fast)
    }

    /// OpenAI 的 GPT-5.6 和 GPT-6：单次输入超过 27.2 万 token 按长上下文价格，快速模式全部翻倍。
    /// long 依次是输入、缓存读取、输出、30 分钟写入、12 小时写入。
    private static func openAI(_ input: Double, read: Double, output: Double, write: Double, writeLong: Double,
                               long: (Double, Double, Double, Double, Double)) -> ModelPrice {
        ModelPrice(rates: .openAI(input, read: read, output: output, write: write, writeLong: writeLong),
                   longContext: (272_000, .openAI(long.0, read: long.1, output: long.2, write: long.3, writeLong: long.4)),
                   fastMultiplier: 2)
    }

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
                                  longContext: (272_000, .openAI(10, read: 1, output: 45))),
            "gpt-5.5-pro": ModelPrice(rates: .openAI(30, read: 30, output: 180),
                                      longContext: (272_000, .openAI(60, read: 60, output: 270))),
            "gpt-5.3-codex": ModelPrice(rates: .openAI(1.75, read: 0.175, output: 14)),
        ]
    }()

    /// 按最长的前缀匹配，带日期后缀的名字（比如 claude-haiku-4-5-20251001）也能找到价格。
    static func price(for model: String) -> ModelPrice? {
        if let exact = models[model] { return exact }
        var best: (key: String, price: ModelPrice)?
        for (key, price) in models where model.hasPrefix(key + "-") {
            if key.count > (best?.key.count ?? 0) { best = (key, price) }
        }
        return best?.price
    }

    /// 没有这个模型的价格时返回 nil。
    static func cost(of usage: TokenUsage, model: String) -> Double? {
        guard let price = price(for: model) else { return nil }
        var rates = price.rates
        if let long = price.longContext, usage.prompt > long.threshold { rates = long.rates }
        if usage.fast, let multiplier = price.fastMultiplier { rates = rates.scaled(by: multiplier) }
        let dollars = Double(usage.input) * rates.input
            + Double(usage.cacheWrite) * rates.cacheWrite
            + Double(usage.cacheWriteLong) * rates.cacheWriteLong
            + Double(usage.cacheRead) * rates.cacheRead
            + Double(usage.output) * rates.output
        return dollars / 1_000_000 * usage.regionMultiplier
    }
}
