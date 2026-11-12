import SwiftUI

/// 服务器运维：tmux 分屏，左边 htop，右边滚动的访问日志和正在滚动更新的 Kubernetes Pod。
final class OpsSim: BusySim {
    struct Process { let pid: Int; let user: String; var cpu: Walk; let mem: Double; let command: String }
    struct Pod { var name: String; var status: String; var restarts: Int; var age: Double }

    let service: String
    private var rng: SplitMix64
    private(set) var simTime = 0.0
    private(set) var cores: [Walk]
    private(set) var memUsed = Walk(41.2, spread: 0.25, lo: 30, hi: 60)
    private(set) var load = [Walk(6.4, spread: 0.3, lo: 1), Walk(5.9, spread: 0.15, lo: 1), Walk(5.2, spread: 0.08, lo: 1)]
    private(set) var processes: [Process] = []
    private(set) var log: [String] = []
    private(set) var pods: [Pod] = []
    private(set) var events: [String] = []
    private(set) var updated = 0
    private var revision: String
    private var logAcc = 0.0
    private var topWait = 0.0
    private var podWait = 4.0
    private let logClock: DateFormatter
    private let start = Date()

    private static let paths = ["/api/v1/users/%d", "/api/v1/orders?page=%d", "/api/v1/invoices/%d/pdf", "/healthz",
                                "/api/v1/search?q=report&limit=%d", "/api/v1/sessions/refresh", "/metrics", "/api/v1/events/%d/ack"]
    private static let agents = ["okhttp/4.12.0", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", "kube-probe/1.31",
                                 "Prometheus/2.53.0", "python-requests/2.32.3", "Go-http-client/2.0"]

    init(projectName: String, seed: UInt64) {
        var random = SplitMix64(state: seed ^ 0x0F5C_A11E)
        service = projectName.lowercased().replacingOccurrences(of: " ", with: "-")
        cores = (0..<16).map { _ in Walk(random.range(25, 70), spread: 9, lo: 1, hi: 100) }
        revision = Self.hash(&random, 10)
        rng = random
        logClock = DateFormatter()
        logClock.locale = Locale(identifier: "en_US_POSIX")
        logClock.dateFormat = "dd/MMM/yyyy:HH:mm:ss Z"
        let commands: [(String, String, Double, Double)] = [
            ("app", "node dist/server.js --port 8080", 38, 3.1), ("postgres", "postgres: writer process", 12, 6.4),
            ("redis", "redis-server *:6379", 6, 1.8), ("www-data", "nginx: worker process", 9, 0.4),
            ("kafka", "java -Xmx8g -jar kafka-server.jar", 17, 12.6), ("app", "python3 worker.py --queue emails", 21, 1.2),
            ("root", "/usr/bin/containerd", 4, 0.9), ("root", "/usr/bin/kubelet --config=/var/lib/kubelet/config.yaml", 7, 1.1),
            ("nobody", "prometheus --config.file=/etc/prometheus/prometheus.yml", 5, 2.7), ("envoy", "envoy -c /etc/envoy/envoy.yaml", 8, 0.8),
            ("deploy", "sshd: deploy@pts/2", 0.3, 0.1), ("deploy", "htop", 1.2, 0.1),
            ("app", "node dist/workers/usage-rollup.js", 6.5, 1.4), ("app", "node dist/workers/email-digest.js", 3.2, 0.9),
            ("postgres", "postgres: autovacuum worker", 2.4, 0.6), ("postgres", "postgres: checkpointer", 0.8, 1.9),
            ("root", "/usr/sbin/rsyslogd -n -iNONE", 0.6, 0.1), ("root", "/usr/bin/dockerd -H fd://", 1.8, 0.7),
            ("nobody", "node_exporter --collector.systemd", 1.1, 0.2), ("root", "/lib/systemd/systemd-journald", 0.9, 0.3),
            ("www-data", "nginx: cache manager process", 0.2, 0.1), ("app", "python3 scheduler.py --interval 60", 0.7, 0.4),
        ]
        processes = commands.map { Process(pid: rng.int(900..<48_000), user: $0.0, cpu: Walk($0.2, spread: $0.2 * 0.25 + 0.3, lo: 0.1, hi: 99), mem: $0.3, command: $0.1) }
        let old = Self.hash(&rng, 10)
        pods = (0..<6).map { _ in Pod(name: podName(old), status: "Running", restarts: rng.chance(0.2) ? 1 : 0, age: rng.range(3_600, 90_000)) }
        for _ in 0..<60 { log.append(logLine(at: -Double(60 - log.count) * 0.12)) }
        events = ["$ kubectl set image deployment/\(service) app=registry.internal/\(service):\(revision.prefix(7))"]
    }

    private static func hash(_ rng: inout SplitMix64, _ n: Int) -> String {
        String((0..<n).map { _ in Array("bcdfghjklmnpqrstvwxz2456789")[rng.int(0..<27)] })
    }

    private func podName(_ rev: String) -> String { "\(service)-\(rev)-\(Self.hash(&rng, 5))" }

    func advance(_ dt: Double) {
        simTime += dt
        logAcc += dt * rng.range(3, 14)
        while logAcc >= 1 {
            logAcc -= 1
            log.append(logLine(at: simTime))
        }
        if log.count > 200 { log.removeFirst(log.count - 200) }
        topWait -= dt
        if topWait <= 0 {
            topWait = 1.5
            for i in cores.indices { cores[i].step(&rng, pull: 0.25) }
            memUsed.step(&rng)
            for i in load.indices { load[i].step(&rng) }
            for i in processes.indices { processes[i].cpu.step(&rng, pull: 0.3) }
        }
        for i in pods.indices { pods[i].age += dt }
        podWait -= dt
        if podWait <= 0 { rollStep() }
    }

    /// 滚动更新：一个旧 Pod 下线，一个新 Pod 拉起来，6 个都换完后过一会儿再发一个新版本。
    private func rollStep() {
        podWait = rng.range(2.5, 4.5)
        if let i = pods.firstIndex(where: { $0.status == "ContainerCreating" }) {
            pods[i].status = "Running"
            updated += 1
            events.append("Waiting for deployment \"\(service)\" rollout to finish: \(updated) of 6 updated replicas are available...")
        } else if let i = pods.firstIndex(where: { $0.status == "Terminating" }) {
            pods.remove(at: i)
        } else if updated < 6, let i = pods.firstIndex(where: { !$0.name.contains(revision) }) {
            pods[i].status = "Terminating"
            pods.append(Pod(name: podName(revision), status: "ContainerCreating", restarts: 0, age: 0))
        } else if updated >= 6 {
            events.append("deployment \"\(service)\" successfully rolled out")
            podWait = rng.range(10, 18)
            revision = Self.hash(&rng, 10)
            updated = 0
            events.append("$ kubectl set image deployment/\(service) app=registry.internal/\(service):\(revision.prefix(7))")
        }
        if events.count > 8 { events.removeFirst(events.count - 8) }
    }

    private func logLine(at time: Double) -> String {
        let ip = "10.42.\(rng.int(0..<8)).\(rng.int(2..<250))"
        let path = String(format: rng.pick(Self.paths), rng.int(1..<9_000))
        let method = path.contains("refresh") || path.contains("ack") ? "POST" : "GET"
        let status = rng.chance(0.012) ? 502 : rng.chance(0.03) ? 404 : rng.chance(0.08) ? 304 : 200
        let stamp = logClock.string(from: start.addingTimeInterval(time))
        return "\(ip) - - [\(stamp)] \"\(method) \(path) HTTP/1.1\" \(status) \(rng.int(80..<24_000)) \"-\" \"\(rng.pick(Self.agents))\" \(String(format: "%.3f", rng.range(0.002, status == 502 ? 5 : 0.09)))"
    }

    var topProcesses: [Process] { processes.sorted { $0.cpu.value > $1.cpu.value } }
}

private enum Tmux {
    static let bg = Color(hex: 0x101317)
    static let border = Color(hex: 0x3A3F4B)
    static let text = Color(hex: 0xD0D4DA)
    static let dim = Color(hex: 0x7A818C)
    static let green = Color(hex: 0x5FD068)
    static let red = Color(hex: 0xE5534B)
    static let blue = Color(hex: 0x6CB6FF)
    static let yellow = Color(hex: 0xE0C25B)
    static let cyan = Color(hex: 0x56C1D6)
    static let bar = Color(hex: 0x3FB950)
    static let mono = Font.system(size: 12, design: .monospaced)
}

struct OpsView: View {
    let sim: OpsSim
    let t: Double
    private let clock = SceneClock("HH:mm dd-MMM-yy")

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            VStack(spacing: 0) {
                if portrait {
                    VStack(spacing: 0) {
                        htop.frame(height: geo.size.height * 0.34)
                        divider(horizontal: true)
                        logs
                        divider(horizontal: true)
                        kube.frame(height: geo.size.height * 0.26)
                    }
                } else {
                    HStack(spacing: 0) {
                        htop.frame(width: geo.size.width * 0.5)
                        divider(horizontal: false)
                        VStack(spacing: 0) {
                            logs
                            divider(horizontal: true)
                            kube.frame(height: geo.size.height * 0.38)
                        }
                    }
                }
                statusBar
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Tmux.bg)
        }
    }

    private func divider(horizontal: Bool) -> some View {
        Rectangle().fill(Tmux.green.opacity(0.7)).frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
    }

    private var statusBar: some View {
        HStack(spacing: 0) {
            Text("[prod] ").foregroundColor(.black)
            Text("0:htop  1:logs  2:k8s*").foregroundColor(.black)
            Spacer()
            Text("\"deploy@prod-bastion-01\" \(clock.string(after: sim.simTime))").foregroundColor(.black)
        }
        .font(Tmux.mono)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Tmux.green)
    }

    // MARK: - htop

    private func meter(_ label: String, _ percent: Double, width: Int, text: String? = nil) -> Text {
        let filled = Int(Double(width) * min(percent, 100) / 100)
        let green = filled * 7 / 10, red = filled - green
        let tail = text ?? String(format: "%.1f%%", percent)
        let spaces = max(0, width - filled - tail.count)
        let text = Text(label.leftPad(3)).foregroundColor(Tmux.cyan)
            + Text("[").foregroundColor(Tmux.text)
            + Text(String(repeating: "|", count: green)).foregroundColor(Tmux.green)
            + Text(String(repeating: "|", count: red)).foregroundColor(Tmux.red)
            + Text(String(repeating: " ", count: spaces))
            + Text(tail).foregroundColor(Tmux.dim)
            + Text("]").foregroundColor(Tmux.text)
        return text
    }

    private var htop: some View {
        GeometryReader { geo in
            let chars = max(10, Int((geo.size.width / 2 - 70) / 7.3))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(0..<8, id: \.self) { meter("\($0)", sim.cores[$0].value, width: chars).fixedSize() }
                        meter("Mem", sim.memUsed.value / 64 * 100, width: chars, text: String(format: "%.1fG/64.0G", sim.memUsed.value)).fixedSize()
                        meter("Swp", 4, width: chars, text: "312M/8.00G").fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(8..<16, id: \.self) { meter("\($0)", sim.cores[$0].value, width: chars).fixedSize() }
                        (Text("Tasks: ").foregroundColor(Tmux.cyan) + Text("412, 1873 thr; ").foregroundColor(Tmux.text)
                            + Text("9 running").foregroundColor(Tmux.green))
                        (Text("Load average: ").foregroundColor(Tmux.cyan)
                            + Text(sim.load.map { String(format: "%.2f", $0.value) }.joined(separator: " ")).foregroundColor(Tmux.text))
                        (Text("Uptime: ").foregroundColor(Tmux.cyan) + Text("41 days, \(duration(52_000 + sim.simTime))").foregroundColor(Tmux.text))
                    }
                }
                .font(Tmux.mono)
                .padding(.bottom, 6)
                Text("    PID USER       PRI  NI  VIRT   RES S  CPU% MEM%   TIME+  Command".padding(toLength: 220, withPad: " ", startingAt: 0))
                    .font(Tmux.mono).foregroundColor(.black).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tmux.green)
                ForEach(Array(sim.topProcesses.enumerated()), id: \.offset) { index, p in
                    let cpu = String(format: "%5.1f", p.cpu.value)
                    let mem = String(format: "%4.1f", p.mem)
                    let line = "\(String(p.pid).leftPad(7)) \(p.user.padding(toLength: 9, withPad: " ", startingAt: 0))  20   0 \(String(format: "%4.1fG", p.mem * 0.9 + 0.3)) \(String(format: "%4.0fM", p.mem * 640)) \(p.cpu.value > 2 ? "R" : "S") \(cpu) \(mem) \(duration(p.cpu.value * 900 + sim.simTime))  \(p.command)"
                    Text(line).font(Tmux.mono).foregroundColor(index == 0 ? .black : Tmux.text).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == 0 ? Tmux.cyan : Color.clear)
                }
                Spacer(minLength: 0)
                Text("F1Help  F2Setup  F3Search F4Filter F5Tree  F6SortBy F7Nice - F8Nice + F9Kill  F10Quit")
                    .font(Tmux.mono).foregroundColor(Tmux.text).lineLimit(1)
            }
            .padding(8)
        }
        .clipped()
    }

    // MARK: - 日志和 Pod

    private var logs: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("deploy@prod-bastion-01:~$ tail -f /var/log/nginx/access.log").font(Tmux.mono).foregroundColor(Tmux.green)
            GeometryReader { geo in
                let n = max(1, Int(geo.size.height / 16))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sim.log.suffix(n).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(line.contains("\" 502 ") ? Tmux.red : line.contains("\" 404 ") ? Tmux.yellow : Tmux.text)
                            .lineLimit(1).frame(height: 16, alignment: .leading)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            }
            .clipped()
        }
        .padding(8)
    }

    private var kube: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("deploy@prod-bastion-01:~$ kubectl get pods -n prod -l app=\(sim.service) -w").foregroundColor(Tmux.green)
            Text("NAME".padding(toLength: 42, withPad: " ", startingAt: 0) + "READY   STATUS              RESTARTS   AGE").foregroundColor(Tmux.dim)
            ForEach(Array(sim.pods.enumerated()), id: \.offset) { _, pod in
                let ready = pod.status == "Running" ? "1/1" : "0/1"
                let color = pod.status == "Running" ? Tmux.text : pod.status == "Terminating" ? Tmux.red : Tmux.yellow
                Text(pod.name.padding(toLength: 42, withPad: " ", startingAt: 0) + ready.padding(toLength: 8, withPad: " ", startingAt: 0)
                     + pod.status.padding(toLength: 20, withPad: " ", startingAt: 0) + "\(pod.restarts)".padding(toLength: 11, withPad: " ", startingAt: 0)
                     + age(pod.age))
                    .foregroundColor(color)
            }
            ForEach(Array(sim.events.suffix(3).enumerated()), id: \.offset) { _, event in
                Text(event).foregroundColor(event.contains("successfully") ? Tmux.green : event.hasPrefix("$") ? Tmux.blue : Tmux.dim)
            }
            Spacer(minLength: 0)
        }
        .font(Tmux.mono)
        .lineLimit(1)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func age(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(s % 60)s" }
        if s < 86_400 { return "\(s / 3600)h\((s % 3600) / 60)m" }
        return "\(s / 86_400)d\((s % 86_400) / 3600)h"
    }
}
