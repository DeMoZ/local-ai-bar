import SwiftUI

struct ContentView: View {
    @EnvironmentObject var s: AppState
    @State private var showSettings = false
    @State private var showDonate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if showDonate {
                DonateView(close: { showDonate = false })
            } else if showSettings || !s.configured {
                SettingsView()
            } else {
                StatusView()
            }
            if let m = s.message {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        // Solid background: the default translucent menu-bar window lets windows behind show through.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        // The menu-bar window grows with its content but does not shrink back (e.g. after closing settings),
        // leaving a stale transparent strip. Make it opaque and fit it to the content, keeping the top edge.
        .background(PopoverWindowFitter())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(s.connected ? s.status.color : .secondary).frame(width: 10, height: 10)
                .opacity(s.status == .loading ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local AI").font(.headline)
                Text(s.connected ? s.status.title : "Не подключено").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Настройки")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = s.lastUpdate, s.connected {
                Text("Обновлено \(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Button { showDonate.toggle(); if showDonate { s.loadDonations() } } label: {
                    Label("Поддержать", systemImage: "heart.fill")
                }
                .foregroundStyle(.pink)
                Button("Обновления") { s.checkForUpdates() }.help("Проверить обновления")
                Spacer()
                Text("v\(s.appVersion)").foregroundStyle(.tertiary)
                Button("Выход") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(s.host, systemImage: "desktopcomputer").font(.callout).lineLimit(1)
                Spacer()
                if s.connected {
                    Button("Отключиться") { s.disconnect() }
                } else {
                    Button("Подключиться") { s.connect() }.keyboardShortcut(.defaultAction)
                }
            }

            if s.connected {
                modelButton
                if let c = s.lastCrash { crashNote(c) }
                if s.status == .running || s.status == .loading { details }
                if let m = s.metrics, m.hasAny { pcLoad(m) }
            }
        }
    }

    private var modelButton: some View {
        let canToggle = s.status == .running || s.status == .stopped || s.status == .loading
        let stopped = s.status == .stopped
        return Button {
            s.toggleModel()
        } label: {
            HStack {
                if s.busyAction { ProgressView().controlSize(.small) }
                Text(stopped ? "Включить модель" : "Выключить модель").frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(stopped ? .green : .red)
        .disabled(!canToggle || s.busyAction)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = s.model {
                Text(m.name).font(.callout.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Квантизация", m.quant)
                    if m.params > 0 { row("Параметры", String(format: "%.1f B", Double(m.params) / 1e9)) }
                    if m.sizeBytes > 0 { row("Размер", ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)) }
                    row("Контекст", m.ctxTrain > 0 ? "\(fmt(m.ctx)) / \(fmt(m.ctxTrain)) макс." : fmt(m.ctx))
                    row("Ввод", [m.vision ? "изображения" : nil, m.audio ? "аудио" : nil, "текст"].compactMap { $0 }.joined(separator: ", "))
                    stateRows
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) { stateRows }
            }

            HStack {
                Button { s.runSpeedTest() } label: {
                    if s.testingSpeed { ProgressView().controlSize(.small) } else { Text("Тест скорости") }
                }
                .disabled(s.testingSpeed || s.status != .running)
                if let sp = s.speed {
                    Text(String(format: "%.1f ток/с · промпт %.0f ток/с", sp.genTPS, sp.promptTPS))
                        .font(.caption).monospacedDigit()
                }
            }
            HStack {
                Button("Копировать API") { s.copyEndpoint() }.help(s.apiEndpoint)
                if s.model?.webUI ?? true { Button("Открыть чат") { s.openWebUI() } }
            }
        }
        .controlSize(.small)
    }

    private func crashNote(_ c: CrashInfo) -> some View {
        let when = ISO8601DateFormatter.withFraction.date(from: c.at) ?? ISO8601DateFormatter().date(from: c.at)
        let text = [
            "Последний сбой модели" + (when.map { " " + $0.formatted(.relative(presentation: .named)) } ?? ""),
            c.exitCode.map { "код \($0)" },
            c.restarted ? "перезапущена" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        return Label(text, systemImage: "exclamationmark.octagon")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pcLoad(_ m: PcMetrics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Нагрузка ПК").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let used = m.ramUsed, let total = m.ramTotal, total > 0 {
                    meterRow("Память", Double(used) / Double(total), "\(gb(used)) из \(gb(total))")
                }
                if let c = m.cpu { meterRow("Процессор", c / 100, String(format: "%.0f%%", c)) }
                if let g = m.gpu { meterRow("Видеокарта", g / 100, String(format: "%.0f%%", g)) }
                if m.gpuDedicated != nil || m.gpuShared != nil {
                    row("Видеопамять", [m.gpuDedicated.map { "своя \(gb($0))" }, m.gpuShared.map { "общая \(gb($0))" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                if let r = m.llamaRam { row("llama-server", gb(r)) }
            }
        }
    }

    private func meterRow(_ k: String, _ frac: Double, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ProgressView(value: min(max(frac, 0), 1)).frame(width: 70)
                    .tint(frac > 0.9 ? .red : frac > 0.75 ? .orange : .accentColor)
                Text(v).monospacedDigit()
            }
        }
        .font(.caption)
    }

    private func gb(_ bytes: Int64) -> String { String(format: "%.1f ГБ", Double(bytes) / 1_073_741_824) }

    @ViewBuilder private var stateRows: some View {
        row("Сервер модели", s.llamaHealthy ? "готов" : "не отвечает")
        if let t = s.liveTPS { row("Сейчас", t >= 0.5 ? String(format: "генерирует %.1f ток/с", t) : "читает запрос") }
        if let sl = s.slots { row("Запросы", sl.busy > 0 ? "в работе \(sl.busy) из \(sl.total)" : "свободно (\(sl.total) слота)") }
        if let since = s.runningSince { row("Работает", since.formatted(.relative(presentation: .numeric))) }
        row("Пинг", "\(s.latencyMs) мс")
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
        .font(.caption)
    }

    private func fmt(_ n: Int) -> String { n.formatted(.number) }
}

struct SettingsView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ПК с нейронкой").font(.subheadline.weight(.semibold))
            HStack {
                TextField("адрес, напр. pc-name.local", text: $s.host).textFieldStyle(.roundedBorder)
                Button { s.scan() } label: {
                    if s.scanning { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
                }
                .disabled(s.scanning)
                .help("Найти в локальной сети")
            }
            if s.scanning {
                ProgressView(value: s.scanProgress).controlSize(.small)
            }
            if s.scanDone && s.found.isEmpty {
                Text("В сети ничего не нашлось на порту \(s.controlPort)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(s.found) { h in
                HStack {
                    Image(systemName: "desktopcomputer")
                    VStack(alignment: .leading) {
                        Text(h.display).font(.callout)
                        if h.name != nil { Text(h.ip).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(s.host == h.address ? "Выбран" : "Выбрать") { s.use(h) }
                        .disabled(s.host == h.address)
                }
            }

            HStack {
                LabeledContent("Порт управления") {
                    TextField("", value: $s.controlPort, format: .number.grouping(.never)).frame(width: 60)
                }
                LabeledContent("Модели") {
                    TextField("", value: $s.llamaPort, format: .number.grouping(.never)).frame(width: 60)
                }
            }
            .font(.caption)
            .textFieldStyle(.roundedBorder)

            Text("Токен").font(.subheadline.weight(.semibold))
            HStack {
                SecureField("токен из config.json", text: $s.token).textFieldStyle(.roundedBorder)
                Button("Из файла…") { s.importConfig() }
            }
            Text("Хранится в Связке ключей macOS").font(.caption2).foregroundStyle(.tertiary)

            if s.connected {
                modelSection
                contextSection
            }

            VStack(alignment: .leading, spacing: 4) {
                if s.connected, let a = s.autoRestart {
                    Toggle("Перезапускать модель, если упала", isOn: Binding(get: { a }, set: { s.setAutoRestart($0) }))
                        .help("Сервис на ПК сам запустит модель снова (не больше 3 раз за 10 минут)")
                }
                Toggle("Уведомлять о сбоях модели", isOn: Binding(get: { s.notifyEnabled }, set: { s.setNotifications($0) }))
                Toggle("Запускать при входе", isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
            }
            .font(.caption)

            Button(s.connected ? "Переподключиться" : "Подключиться") { s.connect() }
                .buttonStyle(.borderedProminent)
                .disabled(!s.configured)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear { s.loadServiceConfig(); s.loadModels() }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Модель").font(.subheadline.weight(.semibold))
            if !s.models.isEmpty {
                HStack {
                    Picker("", selection: Binding(get: { s.modelChoice ?? "" }, set: { s.modelChoice = $0 })) {
                        ForEach(s.models) { m in
                            Text(m.name + (m.vision ? " 👁" : "") + (m.sizeBytes > 0 ? "  " + ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file) : ""))
                                .tag(m.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(s.applyingModel)
                    Button {
                        s.applyModel()
                    } label: {
                        if s.applyingModel { ProgressView().controlSize(.small) } else { Text("Применить") }
                    }
                    .disabled(s.applyingModel || s.modelChoice == nil || s.modelChoice == s.serviceModelId)
                }
            }
            if let m = s.modelMessage {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !s.models.isEmpty {
                Text("Модели из папки на ПК. 👁 — понимает изображения. Применение перезапустит модель.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Контекст").font(.subheadline.weight(.semibold))
            HStack {
                Picker("", selection: $s.ctxChoice) {
                    ForEach(AppState.ctxChoices, id: \.self) { Text("\($0 / 1024)k").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(s.serviceCtx == nil || s.applyingCtx)
                Button {
                    s.applyContext()
                } label: {
                    if s.applyingCtx { ProgressView().controlSize(.small) } else { Text("Применить") }
                }
                .disabled(s.serviceCtx == nil || s.applyingCtx || s.ctxChoice == s.serviceCtx)
            }
            if let m = s.ctxMessage {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let cur = s.serviceCtx {
                let train = s.model?.ctxTrain ?? 0
                Text(train > 0 && s.ctxChoice > train
                     ? "Больше, чем модель обучена (\(train.formatted(.number))): качество может упасть"
                     : "Сейчас \(cur.formatted(.number)). Применение перезапустит модель.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct DonateView: View {
    @EnvironmentObject var s: AppState
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Поддержать LocalAIBar").font(.subheadline.weight(.semibold))
                Spacer()
                if s.loadingDonations { ProgressView().controlSize(.small) }
                Button { close() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
            }
            if let info = s.donations {
                if let m = info.message?.resolved(for: Donations.languages) {
                    Text(m).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(info.methods) { method in
                    Button { NSWorkspace.shared.open(method.url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.title.resolved(for: Donations.languages) ?? method.id).font(.callout.weight(.semibold))
                            if let d = method.description?.resolved(for: Donations.languages) {
                                Text(d).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            } else if !s.loadingDonations {
                Text("Не удалось загрузить способы поддержки. Проверьте интернет и откройте ещё раз.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Keeps the MenuBarExtra window opaque and exactly as tall as its SwiftUI content.
private struct PopoverWindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) { view.scheduleFit() }

    final class FitterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
            scheduleFit()
        }

        // Our size follows the content (we're its background), so a layout pass means the content changed.
        override func layout() {
            super.layout()
            scheduleFit()
        }

        func scheduleFit() {
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        private func fit() {
            guard let w = window, let content = w.contentView else { return }
            let target = bounds.height
            guard target > 0, abs(content.frame.height - target) > 0.5 else { return }
            var f = w.frame
            let top = f.maxY
            f.size.height = w.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: f.width, height: target))).height
            f.origin.y = top - f.size.height  // keep the top edge under the menu bar
            w.setFrame(f, display: true)
            w.invalidateShadow()
        }
    }
}

extension PcMetrics {
    var hasAny: Bool { cpu != nil || gpu != nil || ramTotal != nil || gpuDedicated != nil || gpuShared != nil || llamaRam != nil }
}

extension ISO8601DateFormatter {
    /// The service writes times like 2026-11-09T07:01:35.4819910Z (fractional seconds).
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
