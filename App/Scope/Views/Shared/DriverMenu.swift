import SwiftUI
import ScopeDrivers

/// The items of a "New Thread With Driver" menu: one per profile, and under a profile that takes a model
/// (`modelArgs`) a submenu offering what the New Thread would run on — the default, the models the profile
/// lists, and a free field.
struct DriverMenuItems: View {
    @Environment(AppModel.self) private var model
    /// Called with the chosen profile id and model (`nil` for the defaults).
    let open: (String, String?) -> Void

    var body: some View {
        ForEach(model.drivers.profiles) { profile in
            if profile.acceptsModel {
                Menu(profile.name) {
                    Button(defaultTitle(profile)) { open(profile.id, nil) }
                    let known = profile.knownModels
                    if !known.isEmpty {
                        Divider()
                        ForEach(known, id: \.self) { name in
                            Button(name) { open(profile.id, name) }
                        }
                    }
                    Divider()
                    Button("Other Model…") {
                        if let name = model.promptModelName(for: profile) { open(profile.id, name) }
                    }
                }
            } else {
                Button(profile.name) { open(profile.id, nil) }
            }
        }
    }

    /// `Default (claude-opus-5-5)` when a scope or driver default would apply, `Default` when the driver decides.
    private func defaultTitle(_ profile: DriverProfile) -> String {
        guard let scope = model.currentScope, let name = model.resolvedModel(nil, profile: profile, in: scope) else {
            return "Default"
        }
        return "Default (\(name))"
    }
}
