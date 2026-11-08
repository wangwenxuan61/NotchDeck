import Foundation

/// Simulates a data-analysis notebook: type a cell, run it, get a table / chart / report back.
final class NotebookSim {
    enum Output {
        case none
        case table(columns: [String], index: [String], rows: [[String]])
        case lines(title: String, labels: [String], series: [(name: String, values: [Double])])
        case histogram(title: String, values: [Double])
        case hbars(title: String, labels: [String], values: [Double])
        case text([String])
    }

    struct Cell: Identifiable {
        let id: Int
        var code: String
        var stdout: [String] = []
        var output: Output = .none
        var exec: Int?
        var running = false
    }

    let notebook = "churn_analysis.ipynb"
    let files: [(name: String, modified: String, dir: Bool)] = [
        ("data", "2 days ago", true), ("figures", "1 hour ago", true), ("churn_analysis.ipynb", "seconds ago", false),
        ("cohort_retention.ipynb", "yesterday", false), ("pricing_test_q3.ipynb", "3 days ago", false),
        ("features.py", "1 hour ago", false), ("requirements.txt", "last week", false), ("README.md", "last week", false),
    ]

    private var rng: SplitMix64
    private(set) var cells: [Cell] = []
    private(set) var typist = Typist()
    private(set) var busy = false
    private var exec = 7
    private var nextID = 0
    private var template = 0
    private enum State { case idle, typing, running }
    private var state = State.idle
    private var left = 0.6

    init(seed: UInt64) {
        rng = SplitMix64(state: seed ^ 0x0B0E_B00C)
        for _ in 0..<3 {
            var c = makeCell()
            c.exec = exec
            exec += 1
            cells.append(c)
        }
    }

    var activeID: Int? { cells.last?.id }

    func advance(_ dt: Double) {
        switch state {
        case .idle:
            left -= dt
            if left <= 0 {
                var c = makeCell()
                let code = c.code
                c.code = ""
                pending = c
                cells.append(Cell(id: c.id, code: ""))
                if cells.count > 14 { cells.removeFirst() }
                typist.start(code, speed: 16...28, rng: &rng)
                state = .typing
            }
        case .typing:
            typist.advance(dt, rng: &rng)
            if let i = cells.indices.last { cells[i].code = typist.text }
            if typist.isDone {
                if let i = cells.indices.last { cells[i].running = true }
                busy = true
                state = .running
                left = rng.range(0.6, 3.2)
            }
        case .running:
            left -= dt
            if left <= 0, let i = cells.indices.last, let p = pending {
                cells[i].running = false
                cells[i].exec = exec
                cells[i].stdout = p.stdout
                cells[i].output = p.output
                exec += 1
                busy = false
                typist.clear()
                pending = nil
                state = .idle
                left = rng.range(0.9, 2.2)
            }
        }
    }

    private var pending: Cell?

    func boost() { typist.boost() }

    // MARK: - cell templates with freshly generated data

    private func makeCell() -> Cell {
        defer { template = (template + 1) % 8; nextID += 1 }
        switch template {
        case 0:
            return Cell(id: nextID, code: """
            import numpy as np
            import pandas as pd
            import matplotlib.pyplot as plt
            from sklearn.ensemble import GradientBoostingClassifier
            from sklearn.metrics import classification_report
            """)
        case 1:
            let rows = (0..<5).map { _ -> [String] in
                ["u_" + String(rng.next() % 0xFFFFFF, radix: 16).leftPad(6).replacingOccurrences(of: " ", with: "0"),
                 "2026-0\(rng.int(1..<10))-\(String(rng.int(10..<29)))",
                 rng.pick(["US", "DE", "JP", "BR", "IN", "FR", "KR"]),
                 rng.pick(["free", "pro", "team"]),
                 "\(rng.int(1..<80))",
                 String(format: "%.2f", rng.range(0, 240))]
            }
            return Cell(id: nextID, code: """
            df = pd.read_parquet("data/events_2026q3.parquet")
            print(df.shape)
            df.head()
            """, stdout: ["(1284331, 14)"],
                        output: .table(columns: ["user_id", "signup", "country", "plan", "sessions", "revenue"],
                                       index: (0..<5).map(String.init), rows: rows))
        case 2:
            let names = ["sessions", "revenue", "tenure_days", "support_tickets", "seats"]
            let rows = names.map { _ -> [String] in
                let m = rng.range(2, 180)
                return [String(format: "%.2f", m), String(format: "%.2f", m * rng.range(0.4, 1.3)), "0.00",
                        String(format: "%.2f", m * rng.range(4, 12))]
            }
            return Cell(id: nextID, code: """
            df.describe().T[["mean", "std", "min", "max"]].round(2)
            """, output: .table(columns: ["mean", "std", "min", "max"], index: names, rows: rows))
        case 3:
            let weeks = ["2026-09-27", "2026-10-04", "2026-10-11", "2026-10-18", "2026-10-25"]
            var base = [rng.range(8e3, 12e3), rng.range(40e3, 60e3), rng.range(70e3, 95e3)]
            let rows = weeks.map { _ -> [String] in
                base = base.map { $0 * rng.range(0.97, 1.06) }
                return base.map { String(format: "%.1f", $0) }
            }
            return Cell(id: nextID, code: """
            weekly = (df.set_index("signup")
                        .groupby("plan")["revenue"]
                        .resample("W").sum()
                        .unstack(0))
            weekly.tail()
            """, output: .table(columns: ["free", "pro", "team"], index: weeks, rows: rows))
        case 4:
            let n = 26
            func series(_ start: Double, _ growth: Double) -> [Double] {
                var v = start
                return (0..<n).map { _ in v *= 1 + growth + rng.range(-0.035, 0.035); return v }
            }
            return Cell(id: nextID, code: """
            ax = weekly.plot(figsize=(10, 4), lw=2)
            ax.set_title("Weekly revenue by plan")
            ax.set_ylabel("USD")
            plt.tight_layout()
            """, output: .lines(title: "Weekly revenue by plan", labels: ["Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"],
                                series: [("free", series(9e3, 0.004)), ("pro", series(42e3, 0.012)), ("team", series(70e3, 0.018))]))
        case 5:
            let mu = rng.range(2.3, 2.8)
            let values = (0..<40).map { i -> Double in
                let x = log(Double(i) * 1.5 + 1.2)
                return exp(-pow(x - mu, 2) / 0.35) * rng.range(0.9, 1.1)
            }
            return Cell(id: nextID, code: """
            df["sessions"].clip(upper=60).hist(bins=40, figsize=(10, 3.5))
            plt.title("Sessions per user, last 30 days")
            """, output: .histogram(title: "Sessions per user, last 30 days", values: values))
        case 6:
            let p0 = rng.range(0.90, 0.93), r0 = rng.range(0.93, 0.96)
            let p1 = rng.range(0.74, 0.80), r1 = rng.range(0.64, 0.71)
            let f = { (p: Double, r: Double) in 2 * p * r / (p + r) }
            let acc = rng.range(0.875, 0.895)
            func row(_ name: String, _ a: Double, _ b: Double, _ c: Double, _ n: Int) -> String {
                name.leftPad(12) + String(format: "%10.3f%10.3f%10.3f%10d", a, b, c, n)
            }
            return Cell(id: nextID, code: """
            X_tr, X_te, y_tr, y_te = train_test_split(df[FEATURES], df["churned"], test_size=0.2, random_state=0)
            clf = GradientBoostingClassifier(n_estimators=300, max_depth=3).fit(X_tr, y_tr)
            print(classification_report(y_te, clf.predict(X_te), digits=3))
            """, stdout: [
                "              precision    recall  f1-score   support", "",
                row("0", p0, r0, f(p0, r0), 18234),
                row("1", p1, r1, f(p1, r1), 5112), "",
                "    accuracy" + String(format: "%30.3f%10d", acc, 23346),
                row("macro avg", (p0 + p1) / 2, (r0 + r1) / 2, (f(p0, r0) + f(p1, r1)) / 2, 23346),
                row("weighted avg", p0 * 0.78 + p1 * 0.22, r0 * 0.78 + r1 * 0.22, f(p0, r0) * 0.78 + f(p1, r1) * 0.22, 23346),
            ])
        default:
            let labels = ["tenure_days", "sessions_7d", "support_tickets", "days_since_login", "seats", "plan_pro", "country_US"]
            var v = labels.map { _ in rng.range(0.02, 0.3) }
            v.sort(by: >)
            return Cell(id: nextID, code: """
            imp = pd.Series(clf.feature_importances_, index=FEATURES).nlargest(7)
            imp[::-1].plot.barh(figsize=(8, 3.5), title="Feature importance")
            """, output: .hbars(title: "Feature importance", labels: labels, values: v))
        }
    }
}
