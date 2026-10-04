#if os(macOS)
import SwiftUI

/// Models grouped by provider for the picker.
public struct ModelGroup: Identifiable, Hashable {
    public var id: ProviderID
    public var name: String
    public var isLocal: Bool
    public var models: [ModelInfo]

    public init(id: ProviderID, name: String, isLocal: Bool, models: [ModelInfo]) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.models = models
    }
}

/// A compact menu for picking the chat's model (M4). Local models are
/// listed first and marked, so offline use is obvious.
public struct ModelPicker: View {
    public var groups: [ModelGroup]
    @Binding public var selection: ModelRef?
    public var onOpen: (() -> Void)?

    public init(groups: [ModelGroup], selection: Binding<ModelRef?>, onOpen: (() -> Void)? = nil) {
        self.groups = groups
        self._selection = selection
        self.onOpen = onOpen
    }

    public var body: some View {
        Menu {
            if groups.allSatisfy({ $0.models.isEmpty }) {
                Text("No models. Add a provider in Settings or start Ollama.")
            }
            ForEach(sortedGroups) { group in
                Section(group.isLocal ? "\(group.name) · Local" : group.name) {
                    ForEach(group.models) { model in
                        Button {
                            selection = model.ref
                        } label: {
                            if model.ref == selection {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if currentIsLocal { Image(systemName: "desktopcomputer") }
                Text(currentName).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a model")
        .onAppear { onOpen?() }
    }

    private var sortedGroups: [ModelGroup] {
        groups.filter { !$0.models.isEmpty }.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var currentModel: ModelInfo? {
        guard let selection else { return nil }
        return groups.lazy.flatMap(\.models).first { $0.ref == selection }
    }

    private var currentName: String {
        currentModel?.displayName ?? selection?.modelID ?? "Choose model"
    }

    private var currentIsLocal: Bool {
        currentModel?.isLocal ?? false
    }
}
#endif
