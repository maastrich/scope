import SwiftUI

/// Publishes the focused window's `AppModel` so `ScopeCommands` — which lives outside the view tree —
/// can act on the model of the window that currently has focus.
struct AppModelFocusedKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    /// The `AppModel` of the focused window. `RootView` sets it with `.focusedSceneValue(\.appModel, model)`.
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }
}
