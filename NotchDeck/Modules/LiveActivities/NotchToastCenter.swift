import Foundation
import Observation

/// A short-lived pill shown in the collapsed notch's wings (charging, AirPods connected, a new
/// download, a Pomodoro phase ending). One at a time; a new toast replaces the current one.
nonisolated struct LiveToast: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case charging(percent: Int)
        case onBattery(percent: Int, minutesLeft: Int?)
        case lowBattery(percent: Int)
        case charged
        case deviceConnected(name: String, symbol: String, battery: Int?)
        case download(name: String)
        case pomodoro(title: String, detail: String, isBreak: Bool)
    }

    var id = UUID()
    var kind: Kind
    var duration: TimeInterval

    init(_ kind: Kind, duration: TimeInterval? = nil) {
        self.kind = kind
        self.duration = duration ?? Self.defaultDuration(for: kind)
    }

    /// The tab the notch opens to when the toast is hovered or clicked.
    var module: NotchModule {
        if case .pomodoro = kind { return .pomodoro }
        return .liveActivities
    }

    static func defaultDuration(for kind: Kind) -> TimeInterval {
        switch kind {
        case .lowBattery, .pomodoro: 8
        case .download: 6
        case .deviceConnected: 5
        case .charging, .onBattery, .charged: 4
        }
    }
}

/// Owns the current toast and dismisses it when its time is up.
@Observable
final class NotchToastCenter {
    private(set) var current: LiveToast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ toast: LiveToast) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
