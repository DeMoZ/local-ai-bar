import SwiftUI

@main
struct LocalAIBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(state)
        } label: {
            Image(systemName: state.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppState {
    var menuIcon: String {
        guard connected else { return "brain" }
        switch status {
        case .running: return slots.map { $0.busy > 0 } == true ? "brain.fill" : "brain.head.profile.fill"
        case .loading: return "hourglass"
        case .stopped: return "brain.head.profile"
        case .unreachable, .unauthorized: return "exclamationmark.triangle"
        case .unknown: return "brain"
        }
    }
}

extension ModelStatus {
    var title: String {
        switch self {
        case .running: return "Модель работает"
        case .loading: return "Загружается…"
        case .stopped: return "Выключена"
        case .unreachable: return "Нет связи с ПК"
        case .unauthorized: return "Неверный токен"
        case .unknown: return "Не подключено"
        }
    }
    var color: Color {
        switch self {
        case .running: return .green
        case .loading: return .orange
        case .stopped: return .gray
        case .unreachable, .unauthorized: return .red
        case .unknown: return .secondary
        }
    }
}
