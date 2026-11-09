import Foundation
import AppKit
import ServiceManagement
import Sparkle

@MainActor
final class AppState: ObservableObject {
    // Settings (host and ports in UserDefaults, token in Keychain)
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var controlPort: Int { didSet { UserDefaults.standard.set(controlPort, forKey: "controlPort") } }
    @Published var llamaPort: Int { didSet { UserDefaults.standard.set(llamaPort, forKey: "llamaPort") } }
    @Published var token: String { didSet { Keychain.save(token) } }
    @Published var connected: Bool { didSet { UserDefaults.standard.set(connected, forKey: "connected") } }

    // Live state
    @Published var status: ModelStatus = .unknown
    @Published var latencyMs: Int = 0
    @Published var llamaHealthy = false
    @Published var model: ModelInfo?
    @Published var slots: SlotsInfo?
    @Published var lastUpdate: Date?
    @Published var busyAction = false
    @Published var message: String?
    @Published var runningSince: Date?

    // Discovery
    @Published var scanning = false
    @Published var scanProgress = 0.0
    @Published var found: [FoundHost] = []
    @Published var scanDone = false

    // Speed test
    @Published var speed: SpeedResult?
    @Published var testingSpeed = false

    // Context size (service config)
    static let ctxChoices = [16384, 32768, 65536]
    @Published var serviceCtx: Int?
    @Published var ctxChoice = 32768
    @Published var applyingCtx = false
    @Published var ctxMessage: String?

    // Models on the PC (service /models)
    @Published var models: [ModelEntry] = []
    @Published var modelChoice: String?
    @Published var serviceModelId: String?
    @Published var applyingModel = false
    @Published var modelMessage: String?

    // Crashes and auto-restart (service v0.4+; nil = older service)
    @Published var autoRestart: Bool?
    @Published var lastCrash: CrashInfo?
    @Published var notifyEnabled: Bool { didSet { UserDefaults.standard.set(notifyEnabled, forKey: "notify") } }

    // PC load (service /metrics) and the live generation rate (from llama-server /slots)
    @Published var metrics: PcMetrics?
    @Published var liveTPS: Double?

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Donations (links from the public DeMoZ/donations repo, cached)
    @Published var donations: DonationInfo? = Donations.cached()
    @Published var loadingDonations = false

    /// Sparkle updater; only inside a real .app bundle (not when run from `swift run`).
    let updater: SPUStandardUpdaterController? = Bundle.main.bundleURL.pathExtension == "app"
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    private var timer: Timer?
    private var lastInfoFetch = Date.distantPast
    private var lastMetricsFetch = Date.distantPast
    private var prevDecoded: (n: Int, at: Date)?
    /// Until then a stop is ours (button, new context or model), not one to notify about.
    private var expectStopUntil = Date.distantPast

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        controlPort = d.object(forKey: "controlPort") as? Int ?? 8081
        llamaPort = d.object(forKey: "llamaPort") as? Int ?? 8080
        token = Keychain.load()
        connected = d.object(forKey: "connected") as? Bool ?? false
        notifyEnabled = d.object(forKey: "notify") as? Bool ?? true
        if notifyEnabled { Notifier.requestAuthorization() }
        if connected && !host.isEmpty { startPolling() }
    }

    var client: AIClient { AIClient(host: host, controlPort: controlPort, llamaPort: llamaPort, token: token) }
    var configured: Bool { !host.isEmpty && !token.isEmpty }

    // MARK: connection

    func connect() {
        guard configured else { message = "Укажите адрес и токен"; return }
        connected = true
        message = nil
        startPolling()
    }

    func disconnect() {
        connected = false
        timer?.invalidate(); timer = nil
        status = .unknown; model = nil; slots = nil; llamaHealthy = false; latencyMs = 0
        runningSince = nil; speed = nil
        serviceCtx = nil; ctxMessage = nil
        models = []; serviceModelId = nil; modelMessage = nil
        autoRestart = nil; lastCrash = nil; metrics = nil; liveTPS = nil; prevDecoded = nil
    }

    private func startPolling() {
        timer?.invalidate()
        lastInfoFetch = .distantPast
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard connected, !host.isEmpty else { return }
        let c = client
        let reply = await c.status()
        guard connected else { return }
        let s = reply.status
        notifyIfNeeded(reply, previous: status)
        if s == .running && status != .running { runningSince = Date(); lastInfoFetch = .distantPast }
        if s != .running { runningSince = nil }
        status = s
        autoRestart = reply.autoRestart
        lastCrash = reply.crash
        latencyMs = Int(reply.latency * 1000)
        lastUpdate = Date()
        if s == .running || s == .loading {
            llamaHealthy = await c.health()
            slots = await c.slots()
            updateLiveRate()
            if llamaHealthy && (model == nil || Date().timeIntervalSince(lastInfoFetch) > 60) {
                model = await c.modelInfo()
                lastInfoFetch = Date()
            }
        } else {
            llamaHealthy = false; slots = nil
            updateLiveRate()
        }
        if s != .unreachable && s != .unauthorized && Date().timeIntervalSince(lastMetricsFetch) > 10 {
            lastMetricsFetch = Date()
            metrics = await c.metrics()
        }
    }

    /// Tokens per second of the requests in progress: generated-token growth between two polls.
    /// 0 while a prompt is being read (nothing generated yet), nil when idle.
    private func updateLiveRate() {
        guard let sl = slots, sl.busy > 0 else { liveTPS = nil; prevDecoded = nil; return }
        let now = Date()
        if let p = prevDecoded, sl.decoded >= p.n, now.timeIntervalSince(p.at) > 0.5 {
            let rate = Double(sl.decoded - p.n) / now.timeIntervalSince(p.at)
            liveTPS = liveTPS.map { $0 > 0 && rate > 0 ? 0.5 * $0 + 0.5 * rate : rate } ?? rate
        } else if liveTPS == nil {
            liveTPS = 0
        }
        prevDecoded = (sl.decoded, now)
    }

    // MARK: notifications

    private func notifyIfNeeded(_ r: StatusReply, previous: ModelStatus) {
        let d = UserDefaults.standard
        if let crash = r.crash {
            // A crash the service recorded; remembered so each one is reported once, across app restarts too.
            guard crash.at != d.string(forKey: "lastCrashAt") else { return }
            d.set(crash.at, forKey: "lastCrashAt")
            guard notifyEnabled else { return }
            let code = crash.exitCode.map { "Код выхода \($0)." } ?? ""
            Notifier.send(crash.restarted ? "Модель упала и перезапускается" : "Модель упала",
                          crash.restarted ? "\(code) Сервис на ПК запустил её снова." :
                          "\(code) Включите её в LocalAIBar или включите автоперезапуск в настройках.")
        } else if r.autoRestart == nil, previous == .running, r.status == .stopped, Date() > expectStopUntil,
                  notifyEnabled {
            // Older service: no crash record, so any stop we did not ask for is reported.
            Notifier.send("Модель выключилась", "Её выключили не из LocalAIBar или она упала.")
        }
    }

    func setNotifications(_ on: Bool) {
        notifyEnabled = on
        if on { Notifier.requestAuthorization() }
    }

    // MARK: model on/off

    func toggleModel() {
        let wasStopped = status == .stopped
        busyAction = true
        message = nil
        Task {
            do {
                if !wasStopped { expectStopUntil = Date().addingTimeInterval(60) }
                let s = wasStopped ? try await client.start() : try await client.stop()
                status = s
                if !wasStopped { model = nil; speed = nil }
            } catch {
                message = error.localizedDescription
            }
            busyAction = false
            await refresh()
        }
    }

    func runSpeedTest() {
        testingSpeed = true
        speed = nil
        message = nil
        Task {
            do { speed = try await client.speedTest() } catch { message = "Тест: \(error.localizedDescription)" }
            testingSpeed = false
        }
    }

    // MARK: context size

    func loadServiceConfig() {
        guard connected, configured else { return }
        Task {
            do {
                let cfg = try await client.config()
                serviceCtx = cfg.ctx
                ctxChoice = cfg.ctx
                serviceModelId = cfg.modelId
                if let a = cfg.autoRestart { autoRestart = a }
                ctxMessage = nil
            } catch {
                serviceCtx = nil
                ctxMessage = error.localizedDescription
            }
        }
    }

    func applyContext() {
        let ctx = ctxChoice
        applyingCtx = true
        ctxMessage = nil
        expectStopUntil = Date().addingTimeInterval(120)
        Task {
            do {
                let st = try await client.setConfig(["ctx": ctx])
                status = st
                serviceCtx = ctx
                model = nil; speed = nil
                lastInfoFetch = .distantPast
                ctxMessage = st == .stopped
                    ? "Контекст \(ctx.formatted(.number)) сохранён, применится при включении модели"
                    : "Контекст \(ctx.formatted(.number)) сохранён, модель перезапускается"
            } catch {
                ctxMessage = error.localizedDescription
            }
            applyingCtx = false
            await refresh()
        }
    }

    // MARK: models

    func loadModels() {
        guard connected, configured else { return }
        Task {
            do {
                models = try await client.models()
                let cur = models.first(where: \.current)?.id
                serviceModelId = cur ?? serviceModelId
                modelChoice = cur ?? modelChoice ?? models.first?.id
                modelMessage = models.isEmpty ? "В папке моделей на ПК нет .gguf файлов" : nil
            } catch {
                models = []
                modelMessage = error.localizedDescription
            }
        }
    }

    func applyModel() {
        guard let id = modelChoice else { return }
        applyingModel = true
        modelMessage = nil
        expectStopUntil = Date().addingTimeInterval(180)
        Task {
            do {
                let st = try await client.setConfig(["model": id])
                status = st
                serviceModelId = id
                model = nil; speed = nil
                lastInfoFetch = .distantPast
                let name = models.first(where: { $0.id == id })?.name ?? id
                modelMessage = st == .stopped ? "Выбрана \(name), запустится при включении"
                                              : "Выбрана \(name), модель перезапускается"
                loadModels()
                loadServiceConfig()  // the model's localai.json may have changed the context
            } catch {
                modelMessage = error.localizedDescription
            }
            applyingModel = false
            await refresh()
        }
    }

    func setAutoRestart(_ on: Bool) {
        let old = autoRestart
        autoRestart = on
        Task {
            do { _ = try await client.setConfig(["autoRestart": on]) } catch {
                autoRestart = old
                message = "Автоперезапуск: \(error.localizedDescription)"
            }
        }
    }

    // MARK: discovery

    func scan() {
        scanning = true
        scanDone = false
        scanProgress = 0
        found = []
        let port = controlPort
        Task {
            let r = await Discovery.scan(port: port) { p in
                Task { @MainActor in self.scanProgress = p }
            }
            found = r
            scanning = false
            scanDone = true
        }
    }

    func use(_ h: FoundHost) {
        host = h.address
        if !token.isEmpty { connect() }
    }

    // MARK: misc

    /// Reads token and ports from the control service's config.json (never shown in UI).
    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Выберите config.json сервиса управления"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, var data = try? Data(contentsOf: url) else { return }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            message = "Не удалось прочитать JSON"; return
        }
        var got: [String] = []
        if let t = obj["token"] as? String, !t.isEmpty { token = t; got.append("токен") }
        if let p = obj["controlPort"] as? Int { controlPort = p; got.append("порт управления") }
        if let p = obj["llamaPort"] as? Int { llamaPort = p; got.append("порт модели") }
        message = got.isEmpty ? "В файле нет token/controlPort/llamaPort" : "Импортировано: " + got.joined(separator: ", ")
    }

    var apiEndpoint: String { "http://\(host):\(llamaPort)/v1" }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiEndpoint, forType: .string)
        message = "Скопировано: \(apiEndpoint)"
    }

    func openWebUI() {
        if let u = URL(string: "http://\(host):\(llamaPort)/") { NSWorkspace.shared.open(u) }
    }

    func checkForUpdates() {
        guard let updater else { message = "Обновления работают только в собранном приложении"; return }
        NSApp.activate(ignoringOtherApps: true)  // menu-bar app: bring Sparkle's window to the front
        updater.checkForUpdates(nil)
    }

    func loadDonations() {
        loadingDonations = true
        Task {
            if let fresh = await Donations.download() { donations = fresh }
            loadingDonations = false
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Автозапуск: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
