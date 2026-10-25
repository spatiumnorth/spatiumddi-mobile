//
//  ServerListView.swift
//  SpatiumDDI
//

import SwiftUI

/// The configured control planes, and the way between them.
///
/// Deliberately shows **no data from any of them**. Non-negotiable #3 aside,
/// a screen that aggregated across estates would imply this app is a place
/// where two production networks meet, which it is not — nothing here is
/// fetched, and switching tears the previous session down rather than holding
/// two open.
struct ServerListView: View {
    let servers: [StoredServer]
    let currentID: String?
    /// Whether a token is already sealed for this server, so a row can say
    /// whether the next tap is an unlock or a sign-in.
    let hasToken: (StoredServer) -> Bool
    let protection: (StoredServer) -> KeychainProtection?
    let onSelect: (StoredServer) -> Void
    let onAdd: () -> Void
    let onRemove: (StoredServer) -> Void
    let onRename: (StoredServer, String?) -> Void

    @State private var renaming: StoredServer?
    @State private var confirmingRemoval: StoredServer?

    var body: some View {
        NavigationStack {
            List {
                BrandHeader(caption: "Choose a control plane.")

                Section {
                    ForEach(servers) { server in
                        Button {
                            onSelect(server)
                        } label: {
                            ServerRow(
                                server: server,
                                isCurrent: server.id == currentID,
                                hasToken: hasToken(server),
                                protection: protection(server)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                confirmingRemoval = server
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button {
                                renaming = server
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                } footer: {
                    Text(
                        "Each server keeps its own token and its own approved certificate. Nothing is shared between them, and switching signs out of the one you're leaving."
                    )
                }

                Section {
                    Button {
                        onAdd()
                    } label: {
                        Label("Add Server", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Servers")
            .sheet(item: $renaming) { server in
                RenameServerSheet(server: server) { label in
                    onRename(server, label)
                    renaming = nil
                } onCancel: {
                    renaming = nil
                }
            }
            // Removal takes a token and a trust decision with it. Non-negotiable
            // #6's spirit — nothing consequential on a single tap — applies to
            // the app's own state, not only to the control plane's.
            .confirmationDialog(
                "Remove \(confirmingRemoval?.displayName ?? "")?",
                isPresented: .init(
                    get: { confirmingRemoval != nil },
                    set: { if !$0 { confirmingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirmingRemoval
            ) { server in
                Button("Remove Server", role: .destructive) {
                    onRemove(server)
                    confirmingRemoval = nil
                }
            } message: { server in
                Text(
                    "This deletes the stored token for \(server.address.displayName) and the certificate you approved for it. Nothing on the server changes."
                )
            }
        }
    }
}

private struct ServerRow: View {
    let server: StoredServer
    let isCurrent: Bool
    let hasToken: Bool
    let protection: KeychainProtection?

    var body: some View {
        HStack(spacing: 12) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.displayName)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                if let subtitle = server.subtitle {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if isCurrent { Badge(localised: "current", tint: .accentColor) }
                    if hasToken, let protection {
                        // Says which gate, not just that there is one — a
                        // passcode-protected token is a different promise from
                        // a biometric one, and "Device unlock only" a weaker
                        // one again; the operator chose it, and this is where
                        // they next see that choice. Changed from the Server
                        // screen once signed in.
                        Label(protection.summary, systemImage: protection.symbol)
                            .font(.caption2)
                            .foregroundStyle(protection == .passcode ? .orange : .secondary)
                    } else {
                        Text("Sign-in needed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Naming a server, reachable from the list and from the Server screen.
struct RenameServerSheet: View {
    let server: StoredServer
    let onSave: (String?) -> Void
    let onCancel: () -> Void

    @State private var label: String

    init(server: StoredServer, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: server.trimmedLabel ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Prod EU", text: $label)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown instead of \(server.address.displayName). Leave it empty to use the address.")
                }
            }
            .navigationTitle("Rename Server")
            .dismissableKeyboard()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(label) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ServerListView(
        servers: [
            StoredServer(address: ServerAddress(host: "ddi.internal.example", port: nil), label: "Prod EU"),
            StoredServer(address: ServerAddress(host: "lab.internal.example", port: 8443), label: "Lab"),
            StoredServer(address: ServerAddress(host: "10.20.30.40", port: 8443)),
        ],
        currentID: "https://ddi.internal.example:443",
        hasToken: { $0.address.port == nil },
        protection: { _ in .biometrics },
        onSelect: { _ in }, onAdd: {}, onRemove: { _ in }, onRename: { _, _ in }
    )
}
