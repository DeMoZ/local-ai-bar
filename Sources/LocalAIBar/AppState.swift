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

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        controlPort = d.object(forKey: "controlPort") as? Int ?? 8081
        llamaPort = d.object(forKey: "llamaPort") as? Int ?? 8080
        token = Keychain.load()
        connected = d.object(forKey: "connected") as? Bool ?? false
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
    }

    private func startPolling() {
        timer?.invalidate()
        lastInfoFetch = .distantPast
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard connected, !host.isEmpty else { return }
        let c = client
        let (s, latency) = await c.status()
        guard connected else { return }
        if s == .running && status != .running { runningSince = Date(); lastInfoFetch = .distantPast }
        if s != .running { runningSince = nil }
        status = s
        latencyMs = Int(latency * 1000)
        lastUpdate = Date()
        if s == .running || s == .loading {
            llamaHealthy = await c.health()
            slots = await c.slots()
            if llamaHealthy && (model == nil || Date().timeIntervalSince(lastInfoFetch) > 60) {
                model = await c.modelInfo()
                lastInfoFetch = Date()
            }
        } else {
            llamaHealthy = false; slots = nil
        }
    }

    // MARK: model on/off

    func toggleModel() {
        let wasStopped = status == .stopped
        busyAction = true
        message = nil
        Task {
            do {
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
