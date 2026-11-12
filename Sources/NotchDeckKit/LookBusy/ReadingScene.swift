import SwiftUI

/// 读文献：PDF 慢慢往下翻，读到的句子偶尔被高亮，右边的笔记一句句写出来；读完一篇换下一篇。
final class ReadingSim: BusySim {
    struct Paper { let title: String; let authors: String; let venue: String; let file: String }
    struct Section { let title: String; let paragraphs: [[Int]] }

    static let papers = [
        Paper(title: "Sparse Mixture-of-Depths: Spending Compute Where Tokens Need It",
              authors: "L. Moreau, K. Tanaka, R. Iyer, S. Feld", venue: "Preprint · 2026", file: "mixture_of_depths_2026.pdf"),
        Paper(title: "Learned Token Routing for Long-Context Inference",
              authors: "A. Okafor, J. Lindqvist, M. Chen", venue: "Proceedings · 2025", file: "token_routing_2025.pdf"),
        Paper(title: "Adaptive Computation in Transformers: A Controlled Study",
              authors: "P. Novak, H. Sato, E. Ruiz, D. Abara", venue: "Journal article · 2026", file: "adaptive_computation_2026.pdf"),
    ]

    static let sentences = [
        "Recent work has shown that the cost of inference grows quickly with input length, which limits deployment in practice.",
        "We revisit this trade-off and ask whether every token needs the same amount of computation.",
        "Our analysis suggests that a small fraction of positions accounts for most of the useful signal.",
        "To exploit this, we introduce a lightweight router that decides, per layer, which tokens are processed in full.",
        "The router is trained jointly with the backbone and adds less than one percent to the parameter count.",
        "Prior approaches rely on fixed sparsity patterns that ignore the content of the sequence.",
        "In contrast, our method adapts the budget to each input without changing the training objective.",
        "We evaluate on six benchmarks covering question answering, summarization and code completion.",
        "Across all settings the method matches the dense baseline while reducing compute by 38 percent on average.",
        "The gains are largest for inputs longer than 32k tokens, where attention dominates the run time.",
        "Ablations show that removing the auxiliary balance loss leads to unstable routing early in training.",
        "We also find that routing decisions are consistent across layers, which enables further caching.",
        "Table 2 reports wall-clock latency measured on a single accelerator with batch size one.",
        "A limitation of our study is that all models were trained on English text only.",
        "Figure 3 visualizes the fraction of tokens selected at each depth for a representative example.",
        "Interestingly, punctuation and frequent function words are skipped far more often than named entities.",
        "This pattern agrees with earlier findings on attention head redundancy.",
        "We formalize the router as a top-k selection with a straight-through estimator for the gradient.",
        "Let x denote the hidden state of a token and r(x) the scalar score produced by the router.",
        "Tokens with scores below the threshold bypass the block through a residual connection.",
        "The threshold is chosen so that the expected capacity equals a user-defined budget.",
        "During training we anneal the budget from one to its target value over the first ten thousand steps.",
        "This schedule avoids the collapse we observed when sparsity is imposed from the start.",
        "We compare against three strong baselines that were tuned with the same compute.",
        "All numbers are averaged over three seeds and we report the standard deviation in the appendix.",
        "The improvement holds at every model scale we tested, from 350M to 7B parameters.",
        "Error analysis reveals that most remaining failures involve multi-hop questions with distant evidence.",
        "We release code and checkpoints to support further research on adaptive computation.",
        "Taken together, these results indicate that uniform computation is wasteful for long inputs.",
        "Future work could combine routing with retrieval to further reduce memory traffic.",
    ]

    static let notes = [
        "- Key idea: per-layer router picks which tokens get full compute",
        "- ~38% less compute, same accuracy as dense baseline",
        "- Budget annealed 1.0 -> target over first 10k steps (avoids collapse)",
        "- Q: does routing transfer to our encoder? check Fig. 3 pattern",
        "- Compare with our fixed-window baseline in Sec. 4.2",
        "- Limitation: English only, single accelerator latency",
        "- TODO: cite in related work, para 2",
        "- Try straight-through top-k in our ablation table",
    ]

    private var rng: SplitMix64
    private(set) var paper = 0
    private(set) var sections: [Section] = []
    private(set) var highlighted: Set<Int> = []
    private(set) var readSentences = 0
    private(set) var notesDone: [String] = []
    private(set) var typist = Typist()
    private var note = 0
    private var pause = 0.0
    private var noteWait = 3.0
    private var sentenceClock = 0.0

    init(seed: UInt64) {
        rng = SplitMix64(state: seed ^ 0x2EAD_B00C)
        paper = rng.int(0..<Self.papers.count)
        note = rng.int(0..<Self.notes.count)
        layout()
        readSentences = rng.int(2..<8)
        notesDone = (0..<3).map { Self.notes[(note + $0) % Self.notes.count] }
        note += 3
    }

    /// 每篇论文按种子打乱句子顺序，分成几节。
    private func layout() {
        let titles = ["Abstract", "1  Introduction", "2  Related Work", "3  Method", "4  Experiments", "5  Conclusion"]
        var order = Array(0..<Self.sentences.count)
        for i in order.indices.reversed() { order.swapAt(i, rng.int(0..<(i + 1))) }
        var cursor = 0
        sections = titles.map { title in
            // 6 节一共 30 句，正好把句子库用一遍，不会重复。
            let count = title == "Abstract" || title.hasPrefix("5") ? 1 : 2
            let paragraphs: [[Int]] = (0..<count).map { _ in
                let n = 3
                defer { cursor += n }
                return (0..<n).map { order[(cursor + $0) % order.count] }
            }
            return Section(title: title, paragraphs: paragraphs)
        }
        highlighted = []
        notesDone = []
    }

    /// 读到哪里了，0 到 1。页面按这个往下滚，读完正好滚到底。
    var progress: Double {
        min(1, (Double(readSentences) + min(sentenceClock / 4.5, 1)) / Double(max(totalSentences, 1)))
    }

    var totalSentences: Int { sections.flatMap(\.paragraphs).map(\.count).reduce(0, +) }

    func advance(_ dt: Double) {
        if pause > 0 {
            pause -= dt
            if pause <= 0 && readSentences >= totalSentences {
                paper = (paper + 1) % Self.papers.count
                layout()
                readSentences = 0
            }
        } else {
            // 读一句大约 3 到 6 秒，读的时候页面慢慢往下滚。
            sentenceClock += dt
            if sentenceClock > rng.range(3, 6) {
                sentenceClock = 0
                if rng.chance(0.3) { highlighted.insert(readSentences) }
                readSentences += 1
                if readSentences >= totalSentences { pause = rng.range(6, 10) }
            }
        }
        noteWait -= dt
        if noteWait <= 0 && !typist.isActive {
            if !typist.text.isEmpty {
                notesDone.append(typist.text)
                if notesDone.count > 9 { notesDone.removeFirst() }
                typist.clear()
                noteWait = rng.range(5, 12)
            } else {
                typist.start(Self.notes[note % Self.notes.count], speed: 10...16, rng: &rng)
                note += 1
            }
        }
        typist.advance(dt, rng: &rng)
    }

    func boost() {
        typist.boost()
        sentenceClock += 1
    }
}

private enum PDF {
    static let chrome = Color(hex: 0x2B2D31)
    static let toolbar = Color(hex: 0x37393E)
    static let canvas = Color(hex: 0x505358)
    static let page = Color(hex: 0xFDFDFB)
    static let ink = Color(hex: 0x1C1C1C)
    static let light = Color(hex: 0xD8D9DC)
    static let dim = Color(hex: 0x9EA1A8)
    static let highlight = Color(hex: 0xFFE873)
    static let notes = Color(hex: 0xF7F5EE)
    static let accent = Color(hex: 0xC2502E)
}

private struct PageHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ReadingView: View {
    let sim: ReadingSim
    let t: Double
    /// 整页的高度，量出来以后才知道要滚多远。
    @State private var pageHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            VStack(spacing: 0) {
                toolbar
                if portrait {
                    VStack(spacing: 0) {
                        pageArea(width: geo.size.width - 60)
                        notesPane.frame(height: geo.size.height * 0.2)
                    }
                } else {
                    HStack(spacing: 0) {
                        outline.frame(width: 230)
                        pageArea(width: min(820, geo.size.width - 230 - 400 - 80))
                        notesPane.frame(width: 400)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(PDF.canvas)
        }
    }

    private var current: ReadingSim.Paper { ReadingSim.papers[sim.paper] }

    private var toolbar: some View {
        let page = 1 + Int(sim.progress * 13)
        return HStack(spacing: 18) {
            Image(systemName: "sidebar.left")
            Text(current.file).font(.system(size: 13, weight: .medium))
            Text("Page \(page) of 14").foregroundColor(PDF.dim)
            Spacer()
            Image(systemName: "minus.magnifyingglass")
            Text("125%")
            Image(systemName: "plus.magnifyingglass")
            Rectangle().fill(PDF.dim.opacity(0.4)).frame(width: 1, height: 18)
            HStack(spacing: 6) {
                ForEach([0xFFE873, 0x9FE29A, 0x8FC7FF, 0xF7A6C9], id: \.self) {
                    Circle().fill(Color(hex: UInt32($0))).frame(width: 14, height: 14)
                }
            }
            Image(systemName: "highlighter")
            Image(systemName: "note.text")
            Image(systemName: "magnifyingglass")
        }
        .font(.system(size: 13))
        .foregroundColor(PDF.light)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(PDF.toolbar)
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OUTLINE").font(.system(size: 11, weight: .semibold)).foregroundColor(PDF.dim)
            ForEach(Array(sim.sections.enumerated()), id: \.offset) { index, section in
                let reached = sentenceIndex(section: index, paragraph: 0, sentence: 0) <= sim.readSentences
                Text(section.title.replacingOccurrences(of: "  ", with: " "))
                    .font(.system(size: 13))
                    .foregroundColor(reached ? .white : PDF.dim)
            }
            Divider().overlay(PDF.dim.opacity(0.3)).padding(.vertical, 6)
            Text("ANNOTATIONS · \(sim.highlighted.count)").font(.system(size: 11, weight: .semibold)).foregroundColor(PDF.dim)
            ForEach(Array(sim.highlighted.sorted().suffix(6)), id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(PDF.highlight).frame(width: 3, height: 30)
                    Text(sentence(at: index)).font(.system(size: 11)).foregroundColor(PDF.light).lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PDF.chrome)
    }

    private func sentenceIndex(section: Int, paragraph: Int, sentence: Int) -> Int {
        var index = 0
        for (s, sec) in sim.sections.enumerated() {
            for (p, para) in sec.paragraphs.enumerated() {
                if s == section && p == paragraph { return index + sentence }
                index += para.count
            }
        }
        return index
    }

    private func sentence(at index: Int) -> String {
        let flat = sim.sections.flatMap { $0.paragraphs.flatMap { $0 } }
        return index < flat.count ? ReadingSim.sentences[flat[index]] : ""
    }

    private func paragraphText(section: Int, paragraph: Int) -> AttributedString {
        var out = AttributedString()
        for (k, id) in sim.sections[section].paragraphs[paragraph].enumerated() {
            var part = AttributedString(ReadingSim.sentences[id] + " ")
            if sim.highlighted.contains(sentenceIndex(section: section, paragraph: paragraph, sentence: k)) {
                part.backgroundColor = PDF.highlight
            }
            out += part
        }
        return out
    }

    private func pageArea(width: CGFloat) -> some View {
        GeometryReader { geo in
            let pageWidth = max(320, min(width, geo.size.width - 40))
            VStack(alignment: .leading, spacing: 14) {
                Text(current.venue).font(.system(size: 11, design: .serif)).foregroundColor(.gray)
                Text(current.title).font(.system(size: 22, weight: .bold, design: .serif)).foregroundColor(PDF.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(current.authors).font(.system(size: 13, design: .serif)).foregroundColor(PDF.ink)
                ForEach(Array(sim.sections.enumerated()), id: \.offset) { s, section in
                    Text(section.title).font(.system(size: 15, weight: .bold, design: .serif)).foregroundColor(PDF.ink)
                        .padding(.top, 6)
                    ForEach(section.paragraphs.indices, id: \.self) { p in
                        Text(paragraphText(section: s, paragraph: p))
                            .font(.system(size: 14, design: .serif))
                            .foregroundColor(PDF.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        if s == 3 && p == 1 { figure }
                    }
                }
                Text("References").font(.system(size: 15, weight: .bold, design: .serif)).foregroundColor(PDF.ink).padding(.top, 6)
                ForEach(1..<9, id: \.self) { i in
                    Text("[\(i)] \(["R. Alvarez et al.", "M. Brandt et al.", "C. Osei.", "Y. Park et al.", "D. Kowalski et al.", "F. Haddad et al.", "S. Ito et al.", "L. Nkemelu et al."][i - 1]) Title of the referenced work. In Proceedings, 20\(17 + i).")
                        .font(.system(size: 12, design: .serif)).foregroundColor(PDF.ink)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 60)
            .frame(width: pageWidth, alignment: .leading)
            .background(PDF.page.shadow(color: .black.opacity(0.35), radius: 8, y: 2))
            .background(GeometryReader { Color.clear.preference(key: PageHeight.self, value: $0.size.height) })
            .offset(y: 20 - CGFloat(sim.progress) * max(0, pageHeight - geo.size.height + 60))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .onPreferenceChange(PageHeight.self) { pageHeight = $0 }
        }
        .clipped()
    }

    private var figure: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let plot = CGRect(x: 30, y: 8, width: size.width - 40, height: size.height - 24)
                ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: plot.minY)); $0.addLine(to: CGPoint(x: plot.minX, y: plot.maxY)); $0.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)) },
                           with: .color(PDF.ink), lineWidth: 1)
                let a: [Double] = [0.92, 0.81, 0.66, 0.52, 0.47, 0.41, 0.38, 0.36]
                let b: [Double] = [0.95, 0.9, 0.84, 0.79, 0.75, 0.72, 0.7, 0.69]
                for (values, color) in [(a, PDF.accent), (b, Color(hex: 0x3A6FB0))] {
                    var path = Path()
                    for (i, v) in values.enumerated() {
                        let p = CGPoint(x: plot.minX + plot.width * Double(i) / 7, y: plot.maxY - plot.height * v)
                        i == 0 ? path.move(to: p) : path.addLine(to: p)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
                    }
                    ctx.stroke(path, with: .color(color), lineWidth: 1.5)
                }
                ctx.draw(Text("layer depth →").font(.system(size: 10, design: .serif)).foregroundColor(PDF.ink),
                         at: CGPoint(x: plot.midX, y: plot.maxY + 12))
            }
            .frame(height: 170)
            Text("Figure 3: Fraction of tokens processed in full at each depth (ours, red) versus a fixed-sparsity baseline (blue).")
                .font(.system(size: 12, design: .serif)).foregroundColor(PDF.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "note.text").foregroundColor(PDF.accent)
                Text("Notes — \(current.file.replacingOccurrences(of: ".pdf", with: ""))").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Saved").font(.system(size: 11)).foregroundColor(.gray)
            }
            .foregroundColor(PDF.ink)
            Divider()
            ForEach(Array(sim.notesDone.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13)).foregroundColor(PDF.ink).fixedSize(horizontal: false, vertical: true)
            }
            if sim.typist.isActive || !sim.typist.text.isEmpty {
                HStack(spacing: 0) {
                    Text(sim.typist.text).font(.system(size: 13)).foregroundColor(PDF.ink)
                    Rectangle().fill(Int(t * 2) % 2 == 0 ? PDF.ink : .clear).frame(width: 1.5, height: 16)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PDF.notes)
        .clipped()
    }
}
