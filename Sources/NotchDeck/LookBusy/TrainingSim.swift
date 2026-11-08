import Foundation

struct GPUStat {
    var util: Double
    var memMiB: Double
    var temp: Double
    var watts: Double
}

/// Simulates a long training run that is clearly converging.
final class TrainingSim {
    let runName: String
    let total: Double = 200_000
    let batch = 256
    let peakLR = 3e-4
    let memTotal = 81_559.0
    let startDate: Date

    private var rng: SplitMix64
    private(set) var step: Double
    private(set) var simTime = 0.0
    let baseElapsed: Double
    private(set) var train: [(step: Double, loss: Double)] = []
    private(set) var val: [(step: Double, loss: Double)] = []
    private(set) var gpus: [GPUStat] = []
    private(set) var utilHistory: [Double] = []
    private(set) var log: [String] = []
    private(set) var throughput = 1843.0
    private(set) var gradNorm = 0.41
    private var nextSample = 0.0
    private var nextVal = 0.0
    private var nextCkpt = 0.0
    private var logWait = 0.0
    private var gpuWait = 0.0
    private let clock: DateFormatter

    init(projectName: String, seed: UInt64, now: Date = Date()) {
        rng = SplitMix64(state: seed ^ 0xA5A5_5A5A)
        let slug = projectName.lowercased().replacingOccurrences(of: " ", with: "-")
        let stamp = DateFormatter()
        stamp.dateFormat = "MMdd-HHmm"
        startDate = now
        clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        step = 41_000 + Double(rng.int(0..<14_000))
        baseElapsed = step / 7.2
        runName = "\(slug)-v3/run-\(stamp.string(from: now.addingTimeInterval(-step / 7.2)))"
        var s = 250.0
        while s <= step {
            train.append((s, loss(at: s) + rng.range(-0.05, 0.05) * noiseScale(s)))
            if Int(s) % 2000 == 0 { val.append((s, valLoss(at: s))) }
            s += 250
        }
        nextSample = s
        nextVal = (floor(step / 2000) + 1) * 2000
        nextCkpt = (floor(step / 5000) + 1) * 5000
        gpus = (0..<4).map { _ in
            GPUStat(util: rng.range(95, 100), memMiB: rng.range(70_100, 72_900), temp: rng.range(63, 72), watts: rng.range(560, 640))
        }
        utilHistory = (0..<180).map { _ in rng.range(94, 99.5) }
        for i in (0..<24).reversed() {
            let st = step - Double(i) * 4
            log.append(stepLine(at: st, time: now.addingTimeInterval(-Double(i) * 0.6)))
        }
    }

    // MARK: - curves

    private func noiseScale(_ s: Double) -> Double { 0.5 + 2.5 * exp(-s / 20_000) }

    func loss(at s: Double) -> Double {
        0.38 + 2.15 * exp(-s / 13_000) + 0.32 * exp(-s / 70_000)
    }

    private func valLoss(at s: Double) -> Double {
        loss(at: s) + 0.035 + rng.range(-0.012, 0.012)
    }

    func lr(at s: Double) -> Double {
        let warm = min(1, s / 2000)
        return peakLR * warm * 0.5 * (1 + cos(Double.pi * min(s, total) / total))
    }

    var smoothedLoss: Double {
        let tail = train.suffix(8).map(\.loss)
        return tail.isEmpty ? loss(at: step) : tail.reduce(0, +) / Double(tail.count)
    }

    var elapsed: Double { baseElapsed + simTime }
    var eta: Double { (total - step) / max(throughput / Double(batch), 0.1) }

    // MARK: - simulation

    func advance(_ dt: Double) {
        simTime += dt
        let sps = 7.2 * rng.range(0.97, 1.03)
        throughput = sps * Double(batch)
        step += dt * sps
        while step >= nextSample {
            train.append((nextSample, loss(at: nextSample) + rng.range(-0.05, 0.05) * noiseScale(nextSample)))
            nextSample += 250
        }
        while step >= nextVal {
            let v = valLoss(at: nextVal)
            val.append((nextVal, v))
            add("[\(now)] eval @ step \(grouped(Int(nextVal))) | val_loss \(String(format: "%.4f", v)) | val_acc \(String(format: "%.2f", 100 * (1 - v / 3.2)))%")
            nextVal += 2000
        }
        while step >= nextCkpt {
            add("[\(now)] saving checkpoint to checkpoints/step_\(String(format: "%06d", Int(nextCkpt))).pt (1.42 GB)")
            nextCkpt += 5000
        }
        logWait -= dt
        if logWait <= 0 {
            logWait = rng.range(0.45, 0.85)
            gradNorm = max(0.18, min(0.9, gradNorm + rng.range(-0.04, 0.04)))
            add(stepLine(at: step, time: Date(timeInterval: simTime, since: startDate)))
        }
        gpuWait -= dt
        if gpuWait <= 0 {
            gpuWait = 0.5
            for i in gpus.indices {
                gpus[i].util = min(100, max(88, gpus[i].util + rng.range(-2.5, 2.5)))
                gpus[i].memMiB = min(memTotal - 900, max(69_000, gpus[i].memMiB + rng.range(-180, 180)))
                gpus[i].temp = min(79, max(60, gpus[i].temp + rng.range(-0.6, 0.6)))
                gpus[i].watts = min(690, max(520, gpus[i].watts + rng.range(-18, 18)))
            }
            utilHistory.append(gpus.map(\.util).reduce(0, +) / Double(gpus.count))
            if utilHistory.count > 180 { utilHistory.removeFirst() }
        }
    }

    private var now: String { clock.string(from: Date(timeInterval: simTime, since: startDate)) }

    private func stepLine(at s: Double, time: Date) -> String {
        let l = loss(at: s) + rng.range(-0.03, 0.03)
        return "[\(clock.string(from: time))] step \(grouped(Int(s)))/\(grouped(Int(total))) | loss \(String(format: "%.4f", l)) | lr \(String(format: "%.2e", lr(at: s))) | grad_norm \(String(format: "%.3f", gradNorm)) | \(grouped(Int(throughput))) samples/s"
    }

    private func add(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// The classic nvidia-smi table, kept at its real width.
    func nvidiaSMI() -> String {
        var out = """
        +-----------------------------------------------------------------------------------------+
        | NVIDIA-SMI 570.86.15              Driver Version: 570.86.15      CUDA Version: 12.8     |
        |-----------------------------------------+------------------------+----------------------+
        | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
        | Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
        |=========================================+========================+======================|

        """
        let bus = ["00000000:18:00.0", "00000000:2A:00.0", "00000000:3A:00.0", "00000000:5D:00.0"]
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        let rule = "+" + String(repeating: "-", count: 41) + "+" + String(repeating: "-", count: 24) + "+" + String(repeating: "-", count: 22) + "+"
        for (i, g) in gpus.enumerated() {
            let a1 = pad(" \(String(format: "%3d", i))  NVIDIA H100 80GB HBM3", 37) + "On  "
            let a2 = "   \(bus[i]) Off "
            let a3 = "0 ".leftPad(22)
            let b1 = pad(" N/A   \(Int(g.temp))C    P0", 25) + "\(Int(g.watts))W /  700W ".leftPad(16)
            let b2 = "\(Int(g.memMiB))MiB /  \(Int(memTotal))MiB ".leftPad(24)
            let b3 = "\(Int(g.util))%      Default ".leftPad(22)
            let c3 = "Disabled ".leftPad(22)
            out += "|\(a1)|\(a2)|\(a3)|\n"
            out += "|\(b1)|\(b2)|\(b3)|\n"
            out += "|\(pad("", 41))|\(pad("", 24))|\(c3)|\n"
            out += rule + (i == gpus.count - 1 ? "" : "\n")
        }
        return out
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
