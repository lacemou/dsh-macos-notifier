// DSH Notch Notifier — 菜单栏通知 App
// 直连 DeepSeek Harness 本地 WebSocket 事件流（/api/events.mux + /api/events.host），
// 在"执行动作 / 完成任务 / 需要批准 / 需要回答 / 出错"时弹出系统通知。
//
// 编译：bash build.sh （需要 macOS 13+，Xcode Command Line Tools）
// 单文件、无第三方依赖（URLSessionWebSocketTask + UNUserNotificationCenter + AppKit）。

import AppKit
import UserNotifications
import Darwin

// MARK: - 工具函数

func dlog(_ message: String) {
    NSLog("[DSHNotch] %@", message)
    // 同时写文件日志，便于排障
    let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs", isDirectory: true)
    let logURL = logDir.appendingPathComponent("DSHNotch.log")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data("\(timeNow()) \(message)\n".utf8))
        try? handle.close()
    } else {
        try? Data("\(timeNow()) \(message)\n".utf8).write(to: logURL)
    }
}

func truncate(_ s: String, _ limit: Int = 120) -> String {
    if s.count <= limit { return s }
    return String(s.prefix(limit)) + "…"
}

func timeNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - 设置（UserDefaults 持久化）

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private init() {}

    var serverHost: String {
        get { d.string(forKey: "serverHost") ?? "127.0.0.1" }
        set { d.set(newValue, forKey: "serverHost") }
    }
    var serverPort: Int {
        get { d.integer(forKey: "serverPort") == 0 ? 3080 : d.integer(forKey: "serverPort") }
        set { d.set(newValue, forKey: "serverPort") }
    }
    var muxURL: String { "ws://\(serverHost):\(serverPort)/api/events.mux" }
    var hostURL: String { "ws://\(serverHost):\(serverPort)/api/events.host" }
    var apiBase: String { "http://\(serverHost):\(serverPort)" }
    var webURL: URL? { URL(string: apiBase) }

    var notifyToolCall: Bool {
        // 默认关闭：工具调用是高频事件（agent 运行时几秒一条），全部通知会造成通知中心堆积、
        // 甚至触发 Electron 类应用的挂起；关键事件（完成/出错/批准/提问）默认开启即可。
        get { d.object(forKey: "notifyToolCall") as? Bool ?? false }
        set { d.set(newValue, forKey: "notifyToolCall") }
    }
    var toolCallMinInterval: Double {
        get { let v = d.double(forKey: "toolCallMinInterval"); return v <= 0 ? 5 : v }
        set { d.set(newValue, forKey: "toolCallMinInterval") }
    }
    var notifyCompletion: Bool {
        get { d.object(forKey: "notifyCompletion") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyCompletion") }
    }
    var notifyError: Bool {
        get { d.object(forKey: "notifyError") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyError") }
    }
    var notifyApproval: Bool {
        get { d.object(forKey: "notifyApproval") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyApproval") }
    }
    var notifyQuestion: Bool {
        get { d.object(forKey: "notifyQuestion") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyQuestion") }
    }
    var notifyJobs: Bool {
        get { d.object(forKey: "notifyJobs") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyJobs") }
    }
    var notifyAgentError: Bool {
        get { d.object(forKey: "notifyAgentError") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyAgentError") }
    }
    var playSound: Bool {
        get { d.object(forKey: "playSound") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSound") }
    }
}

// MARK: - 通知发送

final class Notifier {
    static let shared = Notifier()
    private var authorized = false
    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
            dlog("通知权限 granted=\(granted)")
        }
    }

    func notify(id: String, title: String, body: String, sound: Bool) {
        if authorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { dlog("UN 通知失败: \(error)") }
            }
        } else {
            // 未授权时走 osascript（无需权限，始终可用）
            legacyNotify(title: title, body: body, sound: sound)
        }
        // App 直接发声：绕过系统通知声音通道（macOS 通知音效可能被系统设置/系统 bug 静音），
        // 用与 afplay 相同的音频通道直接播放提示音，保证可闻。受 App 内「播放提示音」开关控制。
        if sound {
            let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
            if let ns = NSSound(contentsOf: soundURL, byReference: true) {
                ns.play()
            } else {
                dlog("直接发声失败：无法加载 Glass.aiff")
            }
        }
    }

    private func legacyNotify(title: String, body: String, sound: Bool) {
        let esc = { (s: String) -> String in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: " ")
        }
        var script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        if sound { script += " sound name \"Glass\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// 当前实际使用的发送通道（用于通知诊断显示）
    var channelDescription: String {
        var base = authorized
            ? "UNUserNotificationCenter（系统通知通道）"
            : "osascript（降级通道，未获系统通知权限时使用）"
        if Settings.shared.playSound { base += " + App 直接发声" }
        return base
    }
}

// MARK: - 事件监听（WebSocket 客户端）

final class EventMonitor: NSObject, URLSessionWebSocketDelegate {
    enum Status {
        case disconnected   // 未连接 / 重连中
        case idle           // 已连接，无会话运行
        case running        // 有会话正在运行
        case attention      // 有待批准的请求 / 待回答的问题
    }

    static let shared = EventMonitor()

    var onStatusChange: ((Status) -> Void)?
    var onEventLog: ((String) -> Void)?
    private(set) var sessionCount = 0

    private var urlSession: URLSession!
    private var muxTask: URLSessionWebSocketTask?
    private var hostTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private var refreshTimer: Timer?
    private var backoff: TimeInterval = 2
    private var connected = false

    private var runningSessions = Set<String>()
    private var pendingApprovals = 0
    private var pendingQuestions = 0
    private var jobStates: [String: (session: String, status: String, label: String)] = [:]
    private var lastToolNotify: [String: Date] = [:]
    private var lastAssistantText: [String: String] = [:]

    private override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: 连接管理

    func start() {
        connect()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshSessions()
            // 自动重连兜底：即使 socket 事件偶发丢失（比如进程被杀时没有触发 close 回调），
            // 也保证每 20 秒至少尝试一次重连，"自动重连中"是真实行为而非文案。
            if !self.connected && self.reconnectTimer == nil && !self.autoReconnectPaused {
                self.connect()
            }
        }
    }

    func stop() {
        reconnectTimer?.invalidate(); reconnectTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        muxTask?.cancel(with: .goingAway, reason: nil)
        hostTask?.cancel(with: .goingAway, reason: nil)
        muxTask = nil; hostTask = nil
        connected = false
        onStatusChange?(.disconnected)
    }

    func reconnect() {
        autoReconnectPaused = false
        stop()
        start()
    }

    /// 手动「停止 DSH」后暂停自动重连：尊重用户的停止意图，不再空转重试。
    /// 默认 true：App 启动时只尝试连接一次（探测 DSH 是否在跑），不自动重连；
    /// 点「▶ 启动 DSH」或「重新连接」后才开启自动重连。
    private(set) var autoReconnectPaused = true

    func pauseAutoReconnect() {
        autoReconnectPaused = true
        reconnectTimer?.invalidate(); reconnectTimer = nil
        muxTask?.cancel(with: .goingAway, reason: nil)
        hostTask?.cancel(with: .goingAway, reason: nil)
        muxTask = nil; hostTask = nil
        connected = false
        onStatusChange?(.disconnected)
    }

    func resumeAutoReconnect() {
        autoReconnectPaused = false
        backoff = 2
        connect()
    }

    /// DSH 已确认就绪时立即重连（重置退避、马上连）：
    /// 避免"启动 DSH 成功但 EventMonitor 还要等最长 30 秒的自动重试"造成要连两次的错觉
    func kickReconnect() {
        guard !autoReconnectPaused else { return }
        if connected { return }
        backoff = 2
        connect()
    }

    private func connect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        guard let muxURL = URL(string: Settings.shared.muxURL),
              let hostURL = URL(string: Settings.shared.hostURL) else {
            dlog("服务器地址无效，无法连接：\(Settings.shared.muxURL)")
            scheduleReconnect()
            return
        }
        dlog("连接 \(Settings.shared.muxURL) 与 \(Settings.shared.hostURL)")
        let mux = urlSession.webSocketTask(with: muxURL)
        muxTask = mux
        mux.resume()
        let host = urlSession.webSocketTask(with: hostURL)
        hostTask = host
        host.resume()
    }

    private func scheduleReconnect() {
        connected = false
        onStatusChange?(.disconnected)
        guard !autoReconnectPaused else { return }
        guard reconnectTimer == nil else { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: backoff, repeats: false) { [weak self] _ in
            self?.backoff = min((self?.backoff ?? 2) * 2, 30)
            self?.connect()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol `protocol`: String?) {
        let path = webSocketTask.originalRequest?.url?.path ?? "?"
        dlog("已连接 \(path)")
        if !connected {
            connected = true
            backoff = 2
            onStatusChange?(currentStatus())
            refreshSessions()
        }
        receiveLoop(for: webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        dlog("连接关闭 code=\(closeCode.rawValue)")
        // 只对"当前生效的任务"调度重连：旧任务（已被 stop()/connect() 替换）的回调
        // 不应再触发重连，否则会建立重复连接、事件收两遍、通知重复
        if webSocketTask === muxTask || webSocketTask === hostTask {
            scheduleReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { dlog("连接错误: \(error.localizedDescription)") }
        if task === muxTask || task === hostTask {
            scheduleReconnect()
        }
    }

    // MARK: 接收循环

    private func receiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handleFrame(text) }
                @unknown default:
                    break
                }
                if task === self.muxTask || task === self.hostTask {
                    self.receiveLoop(for: task)
                }
            case .failure(let error):
                dlog("接收失败: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    // MARK: 帧解析

    private func handleFrame(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["type"] as? String == "server-request",
              let payload = obj["payload"] as? [String: Any],
              let frameType = payload["type"] as? String else { return }

        switch frameType {
        case "session/event":
            guard let sessionId = payload["sessionId"] as? String,
                  let event = payload["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return }
            handleSessionEvent(eventType, sessionId: sessionId, event: event)

        case "approval/requested":
            pendingApprovals += 1
            let tool = payload["toolName"] as? String ?? "?"
            let reason = payload["reason"] as? String
            let body = reason.map { "工具 \(tool)：\(truncate($0, 80))" } ?? "工具 \(tool) 正在请求执行权限"
            notifyIf(Settings.shared.notifyApproval, id: "approval-\(UUID().uuidString)",
                     title: "🔔 DSH 需要你批准", body: body, sound: true)
            refreshStatus()

        case "approval/resolved":
            pendingApprovals = max(0, pendingApprovals - 1)
            refreshStatus()

        case "question/requested":
            pendingQuestions += 1
            let qs = payload["questions"] as? [[String: Any]] ?? []
            let first = qs.first?["question"] as? String
            let body = first.map { truncate($0, 100) } ?? "有新问题需要你回答"
            notifyIf(Settings.shared.notifyQuestion, id: "question-\(UUID().uuidString)",
                     title: "❓ DSH 在等你回答", body: body, sound: true)
            refreshStatus()

        case "question/resolved":
            pendingQuestions = max(0, pendingQuestions - 1)
            refreshStatus()

        case "session/jobs":
            handleJobs(sessionId: payload["sessionId"] as? String ?? "",
                       jobs: payload["jobs"] as? [[String: Any]] ?? [])

        case "host/session-status":
            if let sessionId = payload["sessionId"] as? String, let running = payload["running"] as? Bool {
                if running { runningSessions.insert(sessionId) } else { runningSessions.remove(sessionId) }
                refreshStatus()
            }

        case "host/agent-error":
            let msg = payload["message"] as? String ?? "未知错误"
            notifyIf(Settings.shared.notifyAgentError, id: "agenterr-\(UUID().uuidString)",
                     title: "❌ DSH Agent 错误", body: truncate(msg, 100), sound: true)
            refreshStatus()

        case "session/subscribed":
            logEvent("会话已订阅 \(payload["sessionId"] as? String ?? "?")")

        default:
            break
        }
    }

    // MARK: 会话事件

    private func handleSessionEvent(_ type: String, sessionId: String, event: [String: Any]) {
        let data = event["data"] as? [String: Any] ?? [:]

        switch type {
        case "tool/call":
            let name = data["name"] as? String ?? "?"
            let args = data["arguments"] as? String ?? ""
            let turn = data["turn"] as? Int ?? 0
            let step = data["step"] as? Int ?? 0
            let now = Date()
            let last = lastToolNotify[sessionId]
            let shouldNotify = last == nil || now.timeIntervalSince(last!) >= Settings.shared.toolCallMinInterval
            if shouldNotify {
                lastToolNotify[sessionId] = now
                // 固定 identifier：新通知替换旧通知，通知中心最多保留一条工具动态，避免堆积
                notifyIf(Settings.shared.notifyToolCall, id: "tool-activity",
                         title: "🛠️ DSH 正在执行动作",
                         body: "\(name) · 第\(turn)轮/step\(step)：\(truncate(toolSummary(name: name, args: args), 90))",
                         sound: false)
            }
            runningSessions.insert(sessionId)
            refreshStatus()

        case "tool/result":
            runningSessions.insert(sessionId)

        case "turn/start":
            runningSessions.insert(sessionId)
            logEvent("会话 \(shortId(sessionId)) 开始第\(data["turn"] as? Int ?? 0)轮")
            refreshStatus()

        case "turn/end":
            runningSessions.remove(sessionId)
            refreshStatus()
            let turn = data["turn"] as? Int ?? 0
            let reason = data["reason"] as? [String: Any] ?? [:]
            let kind = reason["kind"] as? String ?? "completed"
            let reply = lastAssistantText[sessionId] ?? ""
            switch kind {
            case "completed":
                let body = reply.isEmpty ? "第 \(turn) 轮已完成" : truncate(reply, 100)
                notifyIf(Settings.shared.notifyCompletion, id: "done-\(sessionId)-\(turn)",
                         title: "✅ DSH 任务完成", body: body, sound: true)
                logEvent("✅ 任务完成：\(body)")
            case "error":
                let msg = (reason["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                notifyIf(Settings.shared.notifyError, id: "err-\(sessionId)-\(turn)",
                         title: "❌ DSH 执行出错", body: truncate(msg, 100), sound: true)
                logEvent("❌ 出错：\(truncate(msg, 80))")
            case "max-tokens":
                notifyIf(Settings.shared.notifyError, id: "mt-\(sessionId)-\(turn)",
                         title: "⚠️ DSH 超出 Token 上限", body: "第 \(turn) 轮被截断", sound: true)
                logEvent("⚠️ 超出 Token 上限")
            case "aborted", "interrupted":
                notifyIf(Settings.shared.notifyError, id: "ab-\(sessionId)-\(turn)",
                         title: "⏹️ DSH 回合中止", body: "第 \(turn) 轮已中止", sound: true)
                logEvent("⏹️ 回合中止")
            case "blocked":
                notifyIf(Settings.shared.notifyError, id: "bl-\(sessionId)-\(turn)",
                         title: "🚧 DSH 回合受阻", body: "第 \(turn) 轮被阻塞", sound: true)
                logEvent("🚧 回合受阻")
            default:
                break
            }

        case "assistant/message":
            if let message = data["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let text = content.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
                if !text.isEmpty { lastAssistantText[sessionId] = text }
            }

        default:
            break
        }
    }

    // MARK: 后台任务（session/jobs）

    private func handleJobs(sessionId: String, jobs: [[String: Any]]) {
        var seen = Set<String>()
        for job in jobs {
            guard let id = job["id"] as? String, let status = job["status"] as? String else { continue }
            seen.insert(id)
            let label = job["label"] as? String ?? id
            if let prev = jobStates[id], prev.status != status,
               ["completed", "failed", "killed"].contains(status) {
                let icon = status == "completed" ? "✅" : (status == "failed" ? "❌" : "⏹️")
                let verb = status == "completed" ? "完成" : (status == "failed" ? "失败" : "被终止")
                notifyIf(Settings.shared.notifyJobs, id: "job-\(id)",
                         title: "\(icon) DSH 后台任务\(verb)", body: label, sound: true)
                logEvent("\(icon) 后台任务\(verb)：\(label)")
            }
            jobStates[id] = (sessionId, status, label)
        }
        if jobStates.count > 300 {
            jobStates = jobStates.filter { seen.contains($0.key) }
        }
    }

    // MARK: 辅助

    private func toolSummary(name: String, args: String) -> String {
        if let data = args.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let cmd = obj["command"] as? String { return cmd }
            if let desc = obj["description"] as? String { return desc }
        }
        return args
    }

    private func shortId(_ id: String) -> String {
        id.count > 12 ? String(id.prefix(12)) + "…" : id
    }

    private func notifyIf(_ enabled: Bool, id: String, title: String, body: String, sound: Bool) {
        guard enabled else { return }
        // 调用点传入的 sound 只代表"这类事件默认该不该有声"，最终是否发声由菜单开关决定
        let playSound = sound && Settings.shared.playSound
        dlog("通知 -> \(title) | \(body)\(playSound ? " [有声]" : " [静音]")")
        Notifier.shared.notify(id: id, title: title, body: body, sound: playSound)
        logEvent("\(title) — \(body)")
    }

    private func logEvent(_ text: String) {
        onEventLog?("\(timeNow()) \(text)")
    }

    private func currentStatus() -> Status {
        if !connected { return .disconnected }
        if pendingApprovals > 0 || pendingQuestions > 0 { return .attention }
        if !runningSessions.isEmpty { return .running }
        return .idle
    }

    private func refreshStatus() {
        onStatusChange?(currentStatus())
    }

    // MARK: 会话状态初始化（session.list RPC）

    func refreshSessions() {
        rpc("session.list") { [weak self] value in
            guard let self else { return }
            let items = value?["items"] as? [[String: Any]] ?? []
            let running = Set(items.compactMap { item -> String? in
                guard let id = item["sessionId"] as? String,
                      (item["running"] as? Bool) == true else { return nil }
                return id
            })
            DispatchQueue.main.async {
                self.sessionCount = items.count
                self.runningSessions = running
                self.refreshStatus()
            }
        }
    }

    private func rpc(_ method: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: "\(Settings.shared.apiBase)/api/\(method)") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": UUID().uuidString,
            "method": method,
            "payload": [:]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = obj["result"] as? [String: Any],
                  (result["ok"] as? Bool) == true,
                  let value = result["value"] as? [String: Any] else {
                completion(nil)
                return
            }
            completion(value)
        }.resume()
    }
}

// MARK: - DSH 启动器

/// 便捷启动 DSH web 服务（面向普通用户）：
/// 用用户 shell 环境后台拉起 `npx @deepseek-ai/dsh web`，轮询等待服务就绪。
/// 前提：用户曾在终端成功运行过该命令（npx 缓存与配置已就绪）。
final class DSHLauncher {
    enum State { case idle, starting, running, failed }

    static let shared = DSHLauncher()
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle
    private var process: Process?

    var launchCommand: String {
        get { UserDefaults.standard.string(forKey: "launchCommand") ?? "npx @deepseek-ai/dsh web" }
        set { UserDefaults.standard.set(newValue, forKey: "launchCommand") }
    }

    /// 是否由本 App 拉起的 DSH（决定停止时是否需要确认）
    var isOwned: Bool { process != nil }

    /// 停止由本 App 拉起的 DSH（SIGTERM 到整个进程组：npx + 其子进程 dsh；2 秒后未退出则 SIGKILL）。
    /// 注意：退出 App 不会自动停止 DSH——DSH 是独立 harness，App 只是"扳机"。
    func stopOwned() {
        guard let p = process, p.isRunning else {
            process = nil
            state = .idle
            onStateChange?(.idle)
            return
        }
        dlog("停止 App 拉起的 DSH（pid \(p.processIdentifier)）")
        kill(-p.processIdentifier, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let p = self.process, p.isRunning else { return }
            dlog("DSH 未在 2 秒内退出，SIGKILL")
            kill(-p.processIdentifier, SIGKILL)
        }
        process = nil
        state = .idle
        onStateChange?(.idle)
    }

    /// 按端口查找监听进程（lsof），用于停止"非 App 拉起"的 DSH 实例。
    /// 这样即使 App 重启过、丢失了进程引用，或 DSH 是终端启动的，也能停止。
    func pidOnPort() -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // 注意语法：host:port 用 @ 分隔（-iTCP@host:port），-iTCP:host:port 是非法写法
        p.arguments = ["-nP", "-iTCP@\(Settings.shared.serverHost):\(Settings.shared.serverPort)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(line) else { return nil }
        return pid
    }

    /// 停止指定 PID 的进程（SIGTERM；2 秒后仍存活则 SIGKILL）
    func killPid(_ pid: Int32) {
        dlog("停止 DSH 进程 pid=\(pid)")
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard self != nil else { return }
            if kill(pid, 0) == 0 {   // 进程仍存在
                dlog("pid \(pid) 未在 2 秒内退出，SIGKILL")
                kill(pid, SIGKILL)
            }
        }
    }

    /// 探测 DSH 是否可达（GET / 返回 200）
    func probe(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(Settings.shared.apiBase)/") else { completion(false); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// 确保 DSH 运行：已运行 → 直接成功；未运行 → 后台启动并等待就绪。
    /// 同步先进入「启动中」状态，让菜单立刻从「▶ 启动」切换为「⏳ 正在启动」，
    /// 而不是等异步探测完成才变化（避免用户觉得点了没反应）。
    func start(completion: @escaping (Bool) -> Void) {
        guard state != .starting else { completion(false); return }
        state = .starting
        pendingCompletion = completion
        onStateChange?(.starting)
        probe { [weak self] running in
            guard let self else { return }
            if running {
                // 已运行（可能是外部实例），直接收敛为"运行中"
                self.settle(true)
                return
            }
            self.spawn()
            self.pollUntilReady(deadline: Date().addingTimeInterval(120)) { [weak self] ok in
                self?.settle(ok)
            }
        }
    }

    private var pendingCompletion: ((Bool) -> Void)?

    /// 结果收敛：只生效一次（避免轮询超时与进程提前退出重复回调）
    private func settle(_ ok: Bool) {
        guard pendingCompletion != nil else { return }
        let completion = pendingCompletion
        pendingCompletion = nil
        state = ok ? .running : .failed
        onStateChange?(state)
        completion?(ok)
    }

    private func spawn() {
        let p = Process()
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("DSHNotch-dsh.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let out = FileHandle(forWritingAtPath: logURL.path) {
            p.standardOutput = out
            p.standardError = out
        }
        // 用交互式登录 shell（与终端一致）启动，确保加载 ~/.zshrc 等用户环境（nvm/bun 等 PATH）
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "exec \(launchCommand)"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                dlog("DSH 进程退出 code=\(proc.terminationStatus)")
                // 尚未就绪就退出 = 启动失败，快速失败，不再干等轮询超时
                if self.state == .starting {
                    self.settle(false)
                }
            }
        }
        do {
            try p.run()
            process = p
            dlog("已后台启动 DSH（交互 shell）: \(launchCommand)")
        } catch {
            dlog("启动 DSH 失败: \(error)")
            settle(false)
        }
    }

    private func pollUntilReady(deadline: Date, completion: @escaping (Bool) -> Void) {
        // 进程已提前退出（settle 已触发）则停止轮询
        guard state == .starting else { return }
        probe { ok in
            if ok { completion(true); return }
            if Date() >= deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.pollUntilReady(deadline: deadline, completion: completion)
            }
        }
    }

    /// 读取启动日志尾部（失败时提示用）
    func logTail(_ lines: Int = 8) -> String {
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/DSHNotch-dsh.log")
        guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else {
            return "（暂无日志）"
        }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

// MARK: - 菜单栏控制器

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var eventLog: [String] = []
    private var status: EventMonitor.Status = .disconnected

    func setup() {
        if let button = statusItem.button {
            button.image = Self.icon(for: .disconnected)
            button.toolTip = "DSH Notch Notifier"
        }
        EventMonitor.shared.onStatusChange = { [weak self] s in
            self?.status = s
            self?.applyStatus()
        }
        DSHLauncher.shared.onStateChange = { [weak self] _ in
            self?.rebuildMenu()
        }
        EventMonitor.shared.onEventLog = { [weak self] text in
            self?.eventLog.append(text)
            if self!.eventLog.count > 200 { self!.eventLog.removeFirst(self!.eventLog.count - 200) }
        }
        rebuildMenu()
    }

    static func icon(for status: EventMonitor.Status) -> NSImage? {
        switch status {
        case .disconnected:
            // 未连接：空心圆 + 模板色（深色菜单栏显示白色、浅色菜单栏显示黑色），与 README 的 ⚪ 一致
            let image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        case .idle:
            return coloredIcon(name: "circle.fill", color: .systemGreen)
        case .running:
            return coloredIcon(name: "hammer.fill", color: .systemBlue)
        case .attention:
            return coloredIcon(name: "exclamationmark.triangle.fill", color: .systemOrange)
        }
    }

    private static func coloredIcon(name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func applyStatus() {
        statusItem.button?.image = Self.icon(for: status)
        rebuildMenu()
    }

    // MARK: 菜单构建

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusText: String
        switch status {
        case .disconnected:
            statusText = EventMonitor.shared.autoReconnectPaused
                ? "⚪ 未连接 DSH（点「▶ 启动 DSH」或「重新连接」连接）"
                : "⚪ 未连接 DSH（自动重连中…）"
        case .idle:
            statusText = "🟢 已连接 · 空闲 · \(EventMonitor.shared.sessionCount) 个会话"
        case .running:
            statusText = "🔵 DSH 运行中 · \(EventMonitor.shared.sessionCount) 个会话"
        case .attention:
            statusText = "🟠 DSH 需要你处理（批准/回答）"
        }
        let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        switch DSHLauncher.shared.state {
        case .starting:
            let starting = NSMenuItem(title: "⏳ 正在启动 DSH…", action: nil, keyEquivalent: "")
            starting.isEnabled = false
            menu.addItem(starting)
        default:
            let title = status == .disconnected ? "▶ 启动 DSH" : "打开 DSH 网页"
            addActionItem(menu, title, #selector(launchAndOpen), "o")
            if status == .disconnected {
                let hint = NSMenuItem(title: "  首次请先在终端运行：npx @deepseek-ai/dsh web", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                hint.attributedTitle = NSAttributedString(
                    string: "  首次请先在终端运行：npx @deepseek-ai/dsh web",
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ])
                menu.addItem(hint)
            }
        }
        // 「停止 DSH」：App 拉起的直接显示；外部实例（已连接但非 App 管理）也显示，点击后先确认再按端口停止
        let launcher = DSHLauncher.shared
        if launcher.state != .starting && (launcher.isOwned || status != .disconnected) {
            addActionItem(menu, "⏹ 停止 DSH", #selector(stopDSH), "")
        }
        // 已连接但不是 App 拉起的 → 存在外部实例（如终端手动启动）提示
        if status != .disconnected && !DSHLauncher.shared.isOwned {
            let ext = NSMenuItem(title: "  ℹ️ 当前 DSH 由外部启动（如终端），停止前会先确认", action: nil, keyEquivalent: "")
            ext.isEnabled = false
            ext.attributedTitle = NSAttributedString(
                string: "  ℹ️ 当前 DSH 由外部启动（如终端），停止前会先确认",
                attributes: [
                    .font: NSFont.menuFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
            menu.addItem(ext)
        }
        addActionItem(menu, "测试通知", #selector(testNotify), "t")
        addActionItem(menu, "🔍 通知诊断", #selector(diagnoseNotifications), "d")
        addActionItem(menu, "重新连接", #selector(reconnect), "r")
        menu.addItem(.separator())

        // 通知设置子菜单（复选框嵌在子菜单里，点击复选框不会关闭菜单，可连续勾选）
        let settingsMenu = NSMenu()
        addCheckboxItem(settingsMenu, key: "notifyToolCall", title: "🛠️ 执行动作时通知（工具调用）")
        addCheckboxItem(settingsMenu, key: "notifyCompletion", title: "✅ 任务完成时通知")
        addCheckboxItem(settingsMenu, key: "notifyError", title: "❌ 出错 / 中止 / 超限时通知")
        addCheckboxItem(settingsMenu, key: "notifyApproval", title: "🔔 需要批准时通知")
        addCheckboxItem(settingsMenu, key: "notifyQuestion", title: "❓ 提问等待回答时通知")
        addCheckboxItem(settingsMenu, key: "notifyJobs", title: "📦 后台任务完成/失败时通知")
        addCheckboxItem(settingsMenu, key: "notifyAgentError", title: "💥 Agent 错误时通知")
        settingsMenu.addItem(.separator())
        addCheckboxItem(settingsMenu, key: "playSound", title: "🔊 播放提示音（App 直接发声）")
        let settingsItem = NSMenuItem(title: "通知设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        // 服务器地址
        let serverItem = NSMenuItem(title: "服务器：\(Settings.shared.serverHost):\(Settings.shared.serverPort)",
                                    action: #selector(editServer), keyEquivalent: "")
        serverItem.target = self
        menu.addItem(serverItem)

        // 最近事件
        let logMenu = NSMenu()
        if eventLog.isEmpty {
            let empty = NSMenuItem(title: "暂无事件", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            logMenu.addItem(empty)
        } else {
            for entry in eventLog.reversed().prefix(30) {
                let item = NSMenuItem(title: entry, action: nil, keyEquivalent: "")
                item.isEnabled = false
                logMenu.addItem(item)
            }
        }
        let logItem = NSMenuItem(title: "最近事件（\(eventLog.count)）", action: nil, keyEquivalent: "")
        logItem.submenu = logMenu
        menu.addItem(logItem)

        menu.addItem(.separator())
        addActionItem(menu, "退出 DSH Notch", #selector(quit), "q")

        statusItem.menu = menu
    }

    /// 创建带显式 target 的动作菜单项（否则无窗口 App 的响应链解析不到 action，菜单项会变灰）
    @discardableResult
    private func addActionItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    /// 创建内嵌复选框的菜单项（带留白容器，避免贴边显得粗糙）：
    /// 勾选（蓝勾）/ 未勾选（空方格）由系统复选框绘制；
    /// 点击复选框由按钮自身处理、不关闭菜单，可连续勾选。
    private func addCheckboxItem(_ menu: NSMenu, key: String, title: String) {
        let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleSetting(_:)))
        cb.identifier = NSUserInterfaceItemIdentifier(key)
        cb.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        cb.font = .menuFont(ofSize: 13)
        cb.sizeToFit()
        let pad: CGFloat = 14          // 左右留白
        let rowH: CGFloat = 28         // 行高（垂直呼吸感）
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: cb.frame.width + pad * 2,
                                             height: rowH))
        cb.frame = NSRect(x: pad, y: (rowH - cb.frame.height) / 2,
                          width: cb.frame.width, height: cb.frame.height)
        container.addSubview(cb)
        let item = NSMenuItem()
        item.view = container
        menu.addItem(item)
    }

    @objc private func toggleSetting(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        dlog("设置变更 \(key) = \(sender.state == .on)")
    }

    // MARK: 动作

    /// 启动并打开 DSH：未运行则后台拉起（npx），就绪后打开网页
    @objc private func launchAndOpen() {
        // 手动启动 = 恢复自动重连（解除「停止 DSH」后的暂停）
        EventMonitor.shared.resumeAutoReconnect()
        DSHLauncher.shared.start { [weak self] ok in
            guard let self else { return }
            if ok {
                // DSH 就绪的瞬间立刻让监听器重连（否则要等最长 30 秒的自动重试）
                EventMonitor.shared.kickReconnect()
                if let url = Settings.shared.webURL {
                    NSWorkspace.shared.open(url)
                } else {
                    dlog("webURL 无效，无法打开网页")
                }
                dlog("DSH 就绪，已打开网页")
            } else {
                dlog("启动 DSH 失败，日志尾部：\(DSHLauncher.shared.logTail())")
                self.showLaunchFailedAlert()
            }
        }
    }

    private func showLaunchFailedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "启动 DSH 失败"
        alert.informativeText = "120 秒内服务未就绪。请确认已在终端成功运行过：\nnpx @deepseek-ai/dsh web\n\n启动日志尾部：\n\(DSHLauncher.shared.logTail())"
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    /// 停止 DSH：App 拉起的直接停；外部实例先确认再按端口停。停止后暂停自动重连。
    @objc private func stopDSH() {
        let launcher = DSHLauncher.shared
        if launcher.isOwned {
            launcher.stopOwned()
            EventMonitor.shared.pauseAutoReconnect()
            rebuildMenu()
            return
        }
        // 非 App 管理：按端口找进程，先确认（防止误杀）
        guard let pid = launcher.pidOnPort() else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "未发现 DSH 进程"
            alert.informativeText = "端口 \(Settings.shared.serverPort) 上没有监听进程，可能 DSH 已停止。"
            alert.addButton(withTitle: "好的")
            alert.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "停止 DSH？"
        alert.informativeText = "当前 DSH（\(Settings.shared.serverHost):\(Settings.shared.serverPort)，pid \(pid)）不是由本 App 启动的（可能是终端）。确定停止它吗？"
        alert.addButton(withTitle: "停止")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            launcher.killPid(pid)
            EventMonitor.shared.pauseAutoReconnect()
            dlog("已请求停止外部 DSH pid=\(pid)，自动重连已暂停")
            rebuildMenu()
        }
    }

    @objc private func testNotify() {
        Notifier.shared.notify(id: "test-\(UUID().uuidString)",
                               title: "✅ DSH 通知已开启",
                               body: "这是一条测试通知。能看到说明链路正常。",
                               sound: true)
    }

    /// 通知诊断：直接读取系统里本 App 的真实通知设置
    @objc private func diagnoseNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                var lines: [String] = []

                let auth: String
                switch settings.authorizationStatus {
                case .notDetermined: auth = "未决定（还没弹过权限框）"
                case .denied:        auth = "已拒绝 ❌（需在系统设置里打开）"
                case .authorized:    auth = "已授权 ✅"
                case .provisional:   auth = "临时授权"
                case .ephemeral:     auth = "临时(ephemeral)"
                @unknown default:    auth = "未知"
                }
                lines.append("授权状态：\(auth)")

                func settingName(_ s: UNNotificationSetting) -> String {
                    switch s {
                    case .notSupported: return "不支持"
                    case .disabled:     return "已关闭 ❌"
                    case .enabled:      return "已开启 ✅"
                    @unknown default:   return "未知"
                    }
                }
                lines.append("提醒（横幅/弹窗）：\(settingName(settings.alertSetting))")
                lines.append("提示音：\(settingName(settings.soundSetting)) ← 关键")
                let style: String
                switch settings.alertStyle {
                case .none:   style = "无"
                case .banner: style = "横幅"
                case .alert:  style = "弹窗"
                @unknown default: style = "未知"
                }
                lines.append("通知样式：\(style)")
                lines.append("当前通道：\(Notifier.shared.channelDescription)")
                lines.append("")
                lines.append("提示音=已关闭 ❌ 时：系统设置 → 通知 → DSH 状态栏轻提醒 → 打开「播放提示音」")

                let text = lines.joined(separator: "\n")
                dlog("通知诊断:\n\(text)")
                self.showDiagnoseAlert(text)
            }
        }
    }

    private func showDiagnoseAlert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "通知诊断"
        alert.informativeText = text
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func reconnect() {
        EventMonitor.shared.reconnect()
    }

    @objc private func editServer() {
        let alert = NSAlert()
        alert.messageText = "服务器与启动命令"
        alert.informativeText = "服务器默认 127.0.0.1:3080；启动命令留空则用默认。"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let addrLabel = NSTextField(labelWithString: "服务器地址（主机:端口）")
        let addrField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        addrField.stringValue = "\(Settings.shared.serverHost):\(Settings.shared.serverPort)"

        let cmdLabel = NSTextField(labelWithString: "启动 DSH 的命令（留空=默认）")
        let cmdField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        cmdField.stringValue = DSHLauncher.shared.launchCommand

        stack.addArrangedSubview(addrLabel)
        stack.addArrangedSubview(addrField)
        stack.addArrangedSubview(cmdLabel)
        stack.addArrangedSubview(cmdField)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let parts = addrField.stringValue.split(separator: ":").map(String.init)
            Settings.shared.serverHost = parts.first ?? "127.0.0.1"
            Settings.shared.serverPort = parts.count > 1 ? (Int(parts[1]) ?? 3080) : 3080
            let cmd = cmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty { DSHLauncher.shared.launchCommand = cmd }
            EventMonitor.shared.reconnect()
            rebuildMenu()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 启动

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let menuBar = MenuBarController()
menuBar.setup()
EventMonitor.shared.start()
EventMonitor.shared.refreshSessions()

if CommandLine.arguments.contains("--test-notify") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        Notifier.shared.notify(id: "boot-test",
                               title: "✅ DSH 状态栏轻提醒已启动",
                               body: "正在监听 DSH 事件流，出现动作/完成/待办会实时提醒。",
                               sound: true)
    }
}

app.run()
