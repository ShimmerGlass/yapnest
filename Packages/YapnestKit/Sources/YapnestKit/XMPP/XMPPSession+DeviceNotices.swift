import Foundation

extension XMPPSession {
    /// A device list arrived, ours or a contact's. The first one for each
    /// address is what later devices are told apart from, so once it is
    /// recorded the rest are ignored here; the lists heard in a burst (all
    /// the contacts' on connecting) are written in one background run.
    func deviceListHeard(of name: String, ids: [Int32]) {
        let starts = lock.withLock { state -> Bool in
            guard !state.deviceListsNoted.contains(name), state.deviceListsHeard[name] == nil else { return false }
            state.deviceListsHeard[name] = ids
            guard !state.isNotingDeviceLists else { return false }
            state.isNotingDeviceLists = true
            return true
        }
        guard starts else { return }
        Task.detached(priority: .utility) { [weak self] in
            while let self {
                let batch = self.lock.withLock { state -> [String: [Int32]] in
                    let batch = state.deviceListsHeard
                    state.deviceListsHeard = [:]
                    state.deviceListsNoted.formUnion(batch.keys)
                    if batch.isEmpty { state.isNotingDeviceLists = false }
                    return batch
                }
                if batch.isEmpty { return }
                do {
                    for (name, ids) in batch { try self.database.noteDeviceList(of: name, ids: ids) }
                } catch {
                    DiagLog.error(.omemo, "Device list not recorded", .error(error))
                }
            }
        }
    }

    /// Under blind trust a device that appears on the account is trusted
    /// silently and gets every message, so each one raises a warning that
    /// stays until dismissed. The notices are in the database, written by
    /// whichever process met the device, so one met by an extension shows at
    /// the next launch. Dismissing one only hides it; trust is the user's to change.
    func warnOfNewOwnDevices() {
        let (database, warnings) = (database, warnings)
        let task = Task.detached(priority: .utility) {
            var posted: Set<String> = []
            await database.forEachValue(of: database.observeDeviceNotices(), "Device notices") { notices in
                let keys = Dictionary(uniqueKeysWithValues: notices.map { (Self.newDeviceKey($0.deviceId), $0) })
                for gone in posted.subtracting(keys.keys) { warnings.clear(gone) }
                for (key, notice) in keys where !posted.contains(key) {
                    let id = notice.deviceId
                    warnings.post(
                        key,
                        title: String(localized: "New device on your account"),
                        detail: String(localized: "A device with the fingerprint \(OMEMODevice.grouped(notice.fingerprint)) was added to your account. If it isn't one of yours, someone may be reading your messages."),
                        action: .openDevices,
                    ) {
                        Self.inBackground("Device notice not dismissed") { try database.dismissDeviceNotice(deviceId: id) }
                    }
                }
                posted = Set(keys.keys)
            }
        }
        lock.withLock { $0.ownDeviceNoticeTask = task }
    }

    static func newDeviceKey(_ deviceId: Int32) -> String { "new-device:\(deviceId)" }

    /// Runs a database write off the caller's thread, logging that it failed.
    private static func inBackground(_ failure: StaticString, _ write: @escaping @Sendable () throws -> Void) {
        Task.detached(priority: .utility) {
            do { try write() } catch { DiagLog.error(.omemo, failure, .error(error)) }
        }
    }
}
