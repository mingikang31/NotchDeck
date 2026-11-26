import AppKit
import Observation

/// Per-display UI state observed by `NotchRootView`.
@Observable
final class NotchViewModel {
    var state: NotchState = .collapsed
    var geometry: NotchGeometry
    var displayName: String
    var refreshRate: Int

    /// Invoked when the user clicks the collapsed / peeking silhouette.
    @ObservationIgnored var onTap: () -> Void = {}
    /// Invoked by expanded content that wants to close the notch (e.g. before opening Settings).
    @ObservationIgnored var onRequestCollapse: () -> Void = {}

    init(geometry: NotchGeometry, displayName: String, refreshRate: Int) {
        self.geometry = geometry
        self.displayName = displayName
        self.refreshRate = refreshRate
    }
}
