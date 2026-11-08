import Foundation
import QuartzCore
import SwiftUI

enum SceneKind: String, CaseIterable {
    case agent, training, paper, notebook
}

/// Owns both simulations and ticks them; views re-render on every tick.
final class Engine: ObservableObject {
    let agent: AgentSim
    let training: TrainingSim
    let paper: PaperSim
    let notebook: NotebookSim
    private(set) var time: Double = 0
    private var last = CACurrentMediaTime()

    init(project: Project, seed: UInt64, warmup: Double = 30) {
        agent = AgentSim(project: project, seed: seed)
        training = TrainingSim(projectName: project.name, seed: seed)
        paper = PaperSim(seed: seed)
        notebook = NotebookSim(seed: seed)
        // Start mid-task so the first frame already looks busy.
        var t = 0.0
        while t < warmup * 4 { agent.advance(1.0 / 20); t += 1.0 / 20 }
        t = 0
        while t < warmup {
            training.advance(1.0 / 20); paper.advance(1.0 / 20); notebook.advance(1.0 / 20)
            time += 1.0 / 20; t += 1.0 / 20
        }
        last = CACurrentMediaTime()
    }

    func tick() {
        let now = CACurrentMediaTime()
        advance(min(0.1, now - last))
        last = now
    }

    func advance(_ dt: Double, publish: Bool = true) {
        time += dt
        agent.advance(dt)
        training.advance(dt)
        paper.advance(dt)
        notebook.advance(dt)
        if publish { objectWillChange.send() }
    }

    func keyPressed() {
        agent.boost()
        paper.boost()
        notebook.boost()
    }
}

struct SceneView: View {
    @ObservedObject var engine: Engine
    let kind: SceneKind

    var body: some View {
        switch kind {
        case .agent: AgentView(sim: engine.agent, t: engine.time)
        case .training: TrainingView(sim: engine.training, t: engine.time)
        case .paper: PaperView(sim: engine.paper, t: engine.time)
        case .notebook: NotebookView(sim: engine.notebook, t: engine.time)
        }
    }
}
