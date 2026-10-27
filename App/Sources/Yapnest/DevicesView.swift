import SwiftUI
import YapnestKit

/// OMEMO devices and fingerprints for a contact, or for our own account, as a sheet.
struct DevicesView: View {
    let session: XMPPSession
    /// The contact whose devices to show; nil for our own account.
    let peer: JID?

    var body: some View {
        NavigationStack {
            DevicesList(session: session, peer: peer)
        }
        .closableFromPushedScreens()
    }
}

/// The device list itself, for a sheet or a pushed screen.
struct DevicesList: View {
    let session: XMPPSession
    let peer: JID?

    /// nil until the first read, so the empty note doesn't flash.
    @State private var devices: [OMEMODevice]?
    @State private var ownFingerprint: String?
    /// A verification waiting for the user to accept that it stops other devices.
    @State private var pendingVerification: PendingVerification?

    /// Our own devices waiting for the user to confirm taking them off the account.
    @State private var pendingRemoval: [OMEMODevice]?
    @State private var isRemoving = false
    @State private var removalError: String?

    private struct PendingVerification: Identifiable {
        let device: OMEMODevice
        let demoted: [OMEMODevice]
        var id: Int32 { device.id }
    }

    private var jid: JID { peer ?? session.account }

    /// Our devices that "Remove all unused" would take.
    private var unusedDevices: [OMEMODevice] { peer == nil ? (devices ?? []).filter { $0.isInactive() } : [] }

    private static var thresholdDays: Int { Int(OMEMODevice.inactivityThreshold / 86400) }

    var body: some View {
        List {
            if peer == nil, let fingerprint = ownFingerprint {
                Section {
                    FingerprintText(fingerprint: fingerprint)
                } header: {
                    Text("This device")
                } footer: {
                    Text("Compare this with what your contacts see for you, in person or over another trusted channel.")
                }
            }

            Section {
                if devices?.isEmpty == true {
                    Text(peer == nil ? "No other devices." : "No devices yet. They appear once you exchange encrypted messages.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices ?? []) { device in
                    DeviceRow(
                        device: device,
                        setTrust: { trust in change(trust, of: device) },
                        remove: peer == nil && !isRemoving ? { pendingRemoval = [device] } : nil,
                    )
                }
            } header: {
                Text(peer == nil ? "Your other devices" : "\(jid.description)'s devices")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New devices are trusted automatically until you verify one. After that, new devices only receive messages once you trust them, and verifying a device stops messages going to the others you haven't verified until you decide on each.")
                    Text("A device that hasn't sent anything for \(Self.thresholdDays) days is inactive, and stops receiving messages unless it would leave no device that does. It starts again once it sends something.")
                }
            }

            if !unusedDevices.isEmpty {
                Section {
                    Button(role: .destructive) {
                        pendingRemoval = unusedDevices
                    } label: {
                        HStack {
                            Text("Remove \(unusedDevices.count) unused")
                            if isRemoving { ProgressView() }
                        }
                    }
                    .disabled(isRemoving)
                    .accessibilityIdentifier("removeUnusedDevices")
                } footer: {
                    Text("The inactive devices: none has sent anything for \(Self.thresholdDays) days. A recently added device isn't counted, even if it hasn't sent anything yet.")
                }
            }
        }
        .navigationTitle(peer == nil ? "Encryption" : "Devices")
        .navigationBarTitleDisplayMode(.inline)
        .sheetDoneButton()
        .task { await reload() }
        .toolbar {
            if isRemoving {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .confirmationDialog(
            "Verify this device?",
            isPresented: Binding(isPresent: $pendingVerification),
            titleVisibility: .visible,
            presenting: pendingVerification,
        ) { pending in
            Button("Verify") {
                apply(.verified, to: pending.device)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.demoted.count == 1 {
                Text("The other device that is only trusted will stop receiving messages until you verify or trust it.")
            } else {
                Text("The other \(pending.demoted.count) devices that are only trusted will stop receiving messages until you verify or trust each of them.")
            }
        }
        .alert(
            pendingRemoval?.count == 1 ? "Remove this device?" : "Remove \(pendingRemoval?.count ?? 0) devices?",
            isPresented: Binding(isPresent: $pendingRemoval),
            presenting: pendingRemoval,
        ) { devices in
            Button("Remove", role: .destructive) { remove(devices) }
            Button("Cancel", role: .cancel) {}
        } message: { devices in
            Text(devices.count == 1
                ? "It will stop receiving your encrypted messages. If you still use it, it adds itself back the next time it connects."
                : "They will stop receiving your encrypted messages. Any you still use add themselves back the next time they connect.")
        }
        .alert("Couldn't remove", isPresented: Binding(isPresent: $removalError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
    }

    private func remove(_ targets: [OMEMODevice]) {
        isRemoving = true
        Task {
            do {
                try await session.removeOwnDevices(targets)
            } catch {
                removalError = error.localizedDescription
            }
            await reload()
            isRemoving = false
        }
    }

    /// The store is the database's, so it's read and written off the main thread.
    private func reload() async {
        let jid = jid, ownsList = peer == nil
        let (list, fingerprint) = await offMain { [session] in
            (
                session.devices(of: jid).sorted { ($0.isActive && !$0.isInactive() ? 0 : 1, $0.id) < ($1.isActive && !$1.isInactive() ? 0 : 1, $1.id) },
                ownsList ? session.ownFingerprint : nil,
            )
        }
        devices = list
        ownFingerprint = fingerprint
    }

    private func change(_ trust: OMEMODevice.Trust, of device: OMEMODevice) {
        Task {
            let demoted = await offMain { [session] in session.devicesDemoted(bySetting: trust, for: device) }
            if demoted.isEmpty {
                await apply(trust, to: device)
            } else {
                pendingVerification = PendingVerification(device: device, demoted: demoted)
            }
        }
    }

    private func apply(_ trust: OMEMODevice.Trust, to device: OMEMODevice) {
        Task {
            await offMain { [session] in session.setTrust(trust, for: device) }
            await reload()
        }
    }
}

private struct DeviceRow: View {
    let device: OMEMODevice
    let setTrust: (OMEMODevice.Trust) -> Void
    /// Takes one of our own devices off the account; nil for a contact's.
    let remove: (() -> Void)?

    private var isInactive: Bool { device.isInactive() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(device.trust.title, systemImage: device.trust.symbol)
                    .foregroundStyle(device.trust.color)
                    .font(.subheadline.weight(.medium))
                if !device.isActive {
                    // The owner took it out of their device list.
                    Text("No longer listed").font(.caption).foregroundStyle(.secondary)
                } else if isInactive {
                    Text("Inactive").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("Trust", selection: Binding(get: { device.trust }, set: setTrust)) {
                        ForEach([OMEMODevice.Trust.verified, .trusted, .undecided, .compromised], id: \.self) { trust in
                            Label(trust.action, systemImage: trust.symbol).tag(trust)
                        }
                    }
                    if let remove {
                        Divider()
                        Button("Remove device", systemImage: "trash", role: .destructive, action: remove)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Device options")
            }
            FingerprintText(fingerprint: device.fingerprint)
                .opacity(device.isActive && !isInactive ? 1 : 0.5)
            if let lastUsed = device.lastUsed {
                Text("Last used \(lastUsed, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Never seen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-\(device.id)")
    }
}

/// A fingerprint in groups of eight, the way other OMEMO clients show it.
struct FingerprintText: View {
    let fingerprint: String

    var body: some View {
        Text(OMEMODevice.grouped(fingerprint))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
    }
}

private extension OMEMODevice.Trust {
    var title: LocalizedStringKey {
        switch self {
        case .verified: "Verified"
        case .trusted: "Trusted"
        case .undecided: "Not trusted yet"
        case .compromised: "Blocked"
        }
    }

    var action: LocalizedStringKey {
        switch self {
        case .verified: "Verified"
        case .trusted: "Trust without verifying"
        case .undecided: "Undecided"
        case .compromised: "Block"
        }
    }

    var symbol: String {
        switch self {
        case .verified: "checkmark.seal.fill"
        case .trusted: "lock.fill"
        case .undecided: "questionmark.circle"
        case .compromised: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .verified: .green
        case .trusted: .primary
        case .undecided: .orange
        case .compromised: .red
        }
    }
}
