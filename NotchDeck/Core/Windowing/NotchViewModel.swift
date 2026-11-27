import AppKit
import Observation

/// Per-display UI state observed by `NotchRootView`.
@Observable
final class NotchViewModel {
    var state: NotchState = .collapsed
    var geometry: NotchGeometry
    var displayName: String
    var refreshRate: Int
    /// The module tab shown when expanded (nil = first enabled module).
    var selectedModule: NotchModule?
    /// Measured natural body height of content-fitted modules (see `ExpandedLayout.fitted`).
    var fittedBodyHeights: [NotchModule: CGFloat] = [:]

    /// Invoked when the user clicks the collapsed / peeking silhouette.
    @ObservationIgnored var onTap: () -> Void = {}
    /// Invoked by expanded content that wants to close the notch (e.g. before opening Settings).
    @ObservationIgnored var onRequestCollapse: () -> Void = {}
    /// The user clicked a tab in the expanded notch (not a programmatic switch).
    @ObservationIgnored var onUserSelectedModule: (NotchModule) -> Void = { _ in }

    init(geometry: NotchGeometry, displayName: String, refreshRate: Int) {
        self.geometry = geometry
        self.displayName = displayName
        self.refreshRate = refreshRate
    }
}
