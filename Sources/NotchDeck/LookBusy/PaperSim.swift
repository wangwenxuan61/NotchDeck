import Foundation

/// Simulates writing a paper in an online LaTeX editor: type a block, recompile, see it in the PDF.
final class PaperSim {
    struct Block {
        enum Kind { case heading, paragraph, equation, figure }
        let kind: Kind
        let source: String
        let rendered: String
        let label: String   // section number, equation number or figure number
    }

    let project = "long-context-routing"
    let title = "Adaptive Token Routing for Efficient Long-Context Inference"
    let file = "sections/method.tex"
    let files = ["main.tex", "refs.bib", "sections/abstract.tex", "sections/intro.tex", "sections/related.tex",
                 "sections/method.tex", "sections/experiments.tex", "sections/conclusion.tex",
                 "figures/overview.pdf", "figures/latency.pdf", "figures/ablation.pdf", "tables/main.tex"]

    private var rng: SplitMix64
    private(set) var written: [Block] = []
    private(set) var compiled: [Block] = []
    private(set) var current: Block?
    private(set) var typist = Typist()
    private(set) var compiling = false
    private(set) var sinceCompile = 12.0
    private(set) var words: Int
    private(set) var pages = 11
    private(set) var warnings = 3

    private enum State { case idle, typing, waitCompile, compiling }
    private var state = State.idle
    private var left = 0.5
    private var next = 0

    init(seed: UInt64) {
        rng = SplitMix64(state: seed ^ 0x5EED_9A9E)
        words = 5_800 + rng.int(0..<900)
        for _ in 0..<6 {
            let b = PaperSim.pool[next % PaperSim.pool.count]
            next += 1
            written.append(b)
        }
        compiled = written
    }

    func advance(_ dt: Double) {
        sinceCompile += dt
        switch state {
        case .idle:
            left -= dt
            if left <= 0 {
                let b = PaperSim.pool[next % PaperSim.pool.count]
                next += 1
                current = b
                typist.start(b.source, speed: b.kind == .paragraph ? 11...19 : 16...26, rng: &rng)
                state = .typing
            }
        case .typing:
            typist.advance(dt, rng: &rng)
            if typist.isDone, let b = current {
                written.append(b)
                if written.count > 30 { written.removeFirst() }
                words += b.source.split(separator: " ").count
                current = nil
                typist.clear()
                state = .waitCompile
                left = rng.range(0.7, 1.5)
            }
        case .waitCompile:
            left -= dt
            if left <= 0 { compiling = true; state = .compiling; left = rng.range(1.2, 2.6) }
        case .compiling:
            left -= dt
            if left <= 0 {
                compiling = false
                compiled = written
                sinceCompile = 0
                if rng.chance(0.25) { pages += 1 }
                warnings = max(0, warnings + rng.int(-1..<2))
                state = .idle
                left = rng.range(0.8, 2.0)
            }
        }
    }

    func boost() { typist.boost() }

    /// Editor contents: finished blocks plus the one being typed.
    func sourceLines() -> (lines: [String], typingFrom: Int?) {
        var lines: [String] = []
        for b in written {
            lines += b.source.components(separatedBy: "\n")
            lines.append("")
        }
        var from: Int?
        if current != nil {
            from = lines.count
            lines += typist.text.components(separatedBy: "\n")
        }
        return (lines, from)
    }

    // Original text written for this app.
    static let pool: [Block] = [
        Block(kind: .heading, source: #"\section{Method}"#, rendered: "Method", label: "3"),
        Block(kind: .paragraph,
              source: #"\textbf{Overview.} Given an input sequence $x_{1:T}$, we first split it into fixed-size chunks and score the relevance of each chunk with a lightweight scorer $g_\phi$. Only the top-$k$ chunks are routed to full attention; the others are summarized by a single pooled memory token. For a fixed budget $k$, the cost of a forward pass therefore grows linearly in $T$."#,
              rendered: "Overview. Given an input sequence of T tokens, we first split it into fixed-size chunks and score the relevance of each chunk with a lightweight scorer gφ. Only the top-k chunks are routed to full attention; the others are summarized by a single pooled memory token. For a fixed budget k, the cost of a forward pass therefore grows linearly in T.",
              label: ""),
        Block(kind: .equation,
              source: "\\begin{equation}\n  \\mathcal{L} = \\mathcal{L}_{\\text{task}} + \\lambda \\sum_{t=1}^{T} \\lVert r_t - \\hat{r}_t \\rVert_2^2\n  \\label{eq:loss}\n\\end{equation}",
              rendered: "ℒ  =  ℒtask  +  λ Σₜ ‖ rₜ − r̂ₜ ‖²", label: "(2)"),
        Block(kind: .paragraph,
              source: #"\textbf{Training.} The scorer is trained jointly with the backbone, but gradients from the routing decision are stopped for the first 2k steps. Without this warm-up the scorer collapses onto the first chunk in roughly one run out of three (Appendix~\ref{app:collapse}). The weight $\lambda$ in Eq.~\eqref{eq:loss} is set to $0.1$ throughout."#,
              rendered: "Training. The scorer is trained jointly with the backbone, but gradients from the routing decision are stopped for the first 2k steps. Without this warm-up the scorer collapses onto the first chunk in roughly one run out of three (Appendix C). The weight λ in Eq. (2) is set to 0.1 throughout.",
              label: ""),
        Block(kind: .heading, source: #"\subsection{Complexity}"#, rendered: "Complexity", label: "3.2"),
        Block(kind: .paragraph,
              source: #"For a sequence of length $T$ split into chunks of size $c$, dense attention costs $O(T^2)$, while routing costs $O(Tc + k^2c^2)$. With $c = 256$ and $k = 8$ this is a $14\times$ reduction at $T = 32$k tokens, and the gap widens as $T$ grows (Table~\ref{tab:cost})."#,
              rendered: "For a sequence of length T split into chunks of size c, dense attention costs O(T²), while routing costs O(Tc + k²c²). With c = 256 and k = 8 this is a 14× reduction at T = 32k tokens, and the gap widens as T grows (Table 2).",
              label: ""),
        Block(kind: .figure,
              source: "\\begin{figure}[t]\n  \\centering\n  \\includegraphics[width=\\linewidth]{figures/latency.pdf}\n  \\caption{Latency versus context length. Routing stays close to linear while dense attention grows quadratically.}\n  \\label{fig:latency}\n\\end{figure}",
              rendered: "Latency versus context length. Routing stays close to linear while dense attention grows quadratically.",
              label: "Figure 3"),
        Block(kind: .heading, source: #"\section{Experiments}"#, rendered: "Experiments", label: "4"),
        Block(kind: .paragraph,
              source: #"\textbf{Setup.} We evaluate on three long-context benchmarks and report accuracy, peak memory and wall-clock latency on a single 80\,GB GPU. All baselines share the tokenizer, data order and learning-rate schedule, and every number is averaged over three seeds."#,
              rendered: "Setup. We evaluate on three long-context benchmarks and report accuracy, peak memory and wall-clock latency on a single 80 GB GPU. All baselines share the tokenizer, data order and learning-rate schedule, and every number is averaged over three seeds.",
              label: ""),
        Block(kind: .paragraph,
              source: #"\textbf{Results.} Table~\ref{tab:main} shows that routing stays within 0.4 points of dense attention on average while using 37\% of its memory. The largest gap is on retrieval-heavy tasks, where one missed chunk can hide the answer; raising $k$ from 8 to 12 closes most of it."#,
              rendered: "Results. Table 1 shows that routing stays within 0.4 points of dense attention on average while using 37% of its memory. The largest gap is on retrieval-heavy tasks, where one missed chunk can hide the answer; raising k from 8 to 12 closes most of it.",
              label: ""),
        Block(kind: .heading, source: #"\subsection{Ablations}"#, rendered: "Ablations", label: "4.3"),
        Block(kind: .paragraph,
              source: #"Removing the pooled memory token costs 2.1 points, which confirms that the discarded chunks still carry useful context. Replacing the learned scorer with BM25 is cheaper but loses 3.4 points, mostly on multi-hop questions where relevance depends on earlier chunks."#,
              rendered: "Removing the pooled memory token costs 2.1 points, which confirms that the discarded chunks still carry useful context. Replacing the learned scorer with BM25 is cheaper but loses 3.4 points, mostly on multi-hop questions where relevance depends on earlier chunks.",
              label: ""),
    ]
}
