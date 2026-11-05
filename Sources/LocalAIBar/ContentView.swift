import SwiftUI

struct ContentView: View {
    @EnvironmentObject var s: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if showSettings || !s.configured {
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
        HStack {
            if let t = s.lastUpdate, s.connected {
                Text("Обновлено \(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Выход") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
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
                if s.status == .running || s.status == .loading { details }
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

    @ViewBuilder private var stateRows: some View {
        row("Сервер модели", s.llamaHealthy ? "готов" : "не отвечает")
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

            Toggle("Запускать при входе", isOn: Binding(get: { s.launchAtLogin }, set: { s.setLaunchAtLogin($0) }))
                .font(.caption)

            Button(s.connected ? "Переподключиться" : "Подключиться") { s.connect() }
                .buttonStyle(.borderedProminent)
                .disabled(!s.configured)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
