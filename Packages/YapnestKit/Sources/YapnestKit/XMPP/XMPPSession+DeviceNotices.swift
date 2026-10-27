import Foundation

extension XMPPSession {
    /// A device list arrived, ours or a contact's. The first one for each
    /// address is what later devices are told apart from.
    func deviceListHeard(of name: String, ids: [Int32]) {
        let database = database
        Task.detached(priority: .utility) {
            do { try database.noteDeviceList(of: name, ids: ids) } catch {
                DiagLog.error(.omemo, "Device list not recorded", .error(error))
            }
        }
    }

    /// Under blind trust a device that appears on the account is trusted
    /// silently and gets every message, so each one raises a warning that
    /// stays until dismissed. The notices are in the database, written by
    /// whichever process met the device, so one met by an extension shows at
    /// the next launch. Dismissing one only hides it; trust is the user's to change.
    func warnOfNewOwnDevices() {
        let task = Task.detached(priority: .utility) { [weak self, database, account] in
            var posted: Set<String> = []
            await database.forEachValue(of: database.observeDeviceNotices(of: account), "Device notices") { notices in
                guard let self else { return }
                let keys = Set(notices.map { Self.newDeviceKey($0.deviceId) })
                for gone in posted.subtracting(keys) { self.warnings.clear(gone) }
                for notice in notices where !posted.contains(Self.newDeviceKey(notice.deviceId)) {
                    let (id, jid) = (notice.deviceId, notice.jid)
                    self.warnings.postDevice(
                        Self.newDeviceKey(id),
                        title: String(localized: "New device on your account"),
                        detail: String(localized: "A device with the fingerprint \(notice.groupedFingerprint) was added to your account. If it isn't one of yours, someone may be reading your messages."),
                    ) { [weak self] in
                        guard let self else { return }
                        let database = self.database
                        Task.detached(priority: .utility) {
                            do { try database.dismissDeviceNotice(of: jid, deviceId: id) } catch {
                                DiagLog.error(.omemo, "Device notice not dismissed", .error(error))
                            }
                        }
                    }
                }
                posted = keys
            }
        }
        lock.withLock { $0.ownDeviceNoticeTask = task }
    }

    static func newDeviceKey(_ deviceId: Int32) -> String { "new-device:\(deviceId)" }
}
