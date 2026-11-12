import Foundation
import QuartzCore
import SwiftUI

enum SceneKind: String, CaseIterable {
    case agent, training, paper, notebook, dashboard, build, ops, spreadsheet, matlab, reading

    /// 这些场景在竖屏上也排得开，竖屏随机时优先选它们。
    var suitsPortrait: Bool { [.dashboard, .build, .ops, .reading].contains(self) }
}

/// 每个场景的模拟：按时间推进，有人按键时加快一点。
protocol BusySim: AnyObject {
    func advance(_ dt: Double)
    func boost()
}

extension BusySim {
    func boost() {}
}

extension AgentSim: BusySim {}
extension TrainingSim: BusySim {}
extension PaperSim: BusySim {}
extension NotebookSim: BusySim {}

/// 只创建并推进正在显示的场景，没显示的场景不耗电。
final class Engine: ObservableObject {
    let project: Project
    private let seed: UInt64
    private let warmup: Double
    private(set) var sims: [SceneKind: BusySim] = [:]
    private(set) var time: Double = 0
    private var last = CACurrentMediaTime()

    init(project: Project, seed: UInt64, kinds: Set<SceneKind>, warmup: Double = 30) {
        self.project = project
        self.seed = seed
        self.warmup = warmup
        add(kinds)
        last = CACurrentMediaTime()
    }

    /// 装忙时接上新的显示器，新屏幕的场景要补上。
    func add(_ kinds: Set<SceneKind>) {
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) where sims[kind] == nil {
            let sim = Self.make(kind, project: project, seed: seed)
            // 从任务中途开始，第一帧就已经在忙了。AI 写代码的节奏慢，多推进一些。
            let total = kind == .agent ? warmup * 4 : warmup
            var t = 0.0
            while t < total { sim.advance(1.0 / 20); t += 1.0 / 20 }
            sims[kind] = sim
        }
    }

    static func make(_ kind: SceneKind, project: Project, seed: UInt64) -> BusySim {
        switch kind {
        case .agent: return AgentSim(project: project, seed: seed)
        case .training: return TrainingSim(projectName: project.name, seed: seed)
        case .paper: return PaperSim(seed: seed)
        case .notebook: return NotebookSim(seed: seed)
        case .dashboard: return DashboardSim(projectName: project.name, seed: seed)
        case .build: return BuildSim(project: project, seed: seed)
        case .ops: return OpsSim(projectName: project.name, seed: seed)
        case .spreadsheet: return SpreadsheetSim(seed: seed)
        case .matlab: return MatlabSim(seed: seed)
        case .reading: return ReadingSim(seed: seed)
        }
    }

    func tick() {
        let now = CACurrentMediaTime()
        advance(min(0.1, now - last))
        last = now
    }

    func advance(_ dt: Double, publish: Bool = true) {
        time += dt
        sims.values.forEach { $0.advance(dt) }
        if publish { objectWillChange.send() }
    }

    func keyPressed() { sims.values.forEach { $0.boost() } }
}

struct SceneView: View {
    @ObservedObject var engine: Engine
    let kind: SceneKind

    var body: some View {
        let t = engine.time
        switch engine.sims[kind] {
        case let sim as AgentSim: AgentView(sim: sim, t: t)
        case let sim as TrainingSim: TrainingView(sim: sim, t: t)
        case let sim as PaperSim: PaperView(sim: sim, t: t)
        case let sim as NotebookSim: NotebookView(sim: sim, t: t)
        case let sim as DashboardSim: DashboardView(sim: sim, t: t)
        case let sim as BuildSim: BuildView(sim: sim, t: t)
        case let sim as OpsSim: OpsView(sim: sim, t: t)
        case let sim as SpreadsheetSim: SpreadsheetView(sim: sim, t: t)
        case let sim as MatlabSim: MatlabView(sim: sim, t: t)
        case let sim as ReadingSim: ReadingView(sim: sim, t: t)
        default: Color.black
        }
    }
}
