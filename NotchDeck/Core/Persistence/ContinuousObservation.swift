import Observation

/// Calls `onChange` with the new value every time an `@Observable` property read in `read` changes.
/// Lets AppKit controllers react to settings without Combine. Lives as long as the app.
func observeContinuously<Value>(
    _ read: @escaping @MainActor @Sendable () -> Value,
    onChange: @escaping @MainActor @Sendable (Value) -> Void
) {
    _ = withObservationTracking(read) {
        Task { @MainActor in
            onChange(read())
            observeContinuously(read, onChange: onChange)
        }
    }
}
