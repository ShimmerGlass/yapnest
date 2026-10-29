//
// OMEMOModule.swift
//
// TigaseSwift OMEMO
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Martin
import libsignal
import Combine
import os

extension XmppModuleIdentifier {
    public static var omemo: XmppModuleIdentifier<OMEMOModule> {
        return OMEMOModule.IDENTIFIER;
    }
}

struct KeyDecryptionResult {
    let result: Result<Data,SignalError>;
    let address: SignalAddress;
    let isPrekey: Bool;
    
    var isSuccess: Bool {
        switch result {
        case .success(_):
            return true;
        case .failure(_):
            return false;
        }
    }
}

open class OMEMOModule: AbstractPEPModule, XmppModule, Resetable {
    
    public static let ID = "omemo";
    public static let IDENTIFIER = XmppModuleIdentifier<OMEMOModule>();
    public static let XMLNS = "eu.siacs.conversations.axolotl";
    public static let DEVICES_LIST_NODE = "eu.siacs.conversations.axolotl.devicelist";
    
    public let id: String = ID;

    // Default body to set for OMEMO encrypted messages
    open var defaultBody: String? = "I sent you an OMEMO encrypted message but your client doesn’t seem to support that.";
    
    public override var isPepAvailable: Bool {
        didSet {
            // Set on every account discovery result; publish once per session,
            // when PEP becomes available, not again for a repeated result.
            if isPepAvailable && !oldValue {
                bundlePublishLock.withLock { registrationAttempt = 0 };
                registerDevice();
            }
        }
    }

    public let criteria = Criteria.empty();

    public let features: [String] = [OMEMOModule.DEVICES_LIST_NODE + "+notify"];
    
    public let engine: AES_GCM_Engine;
    public let signalContext: SignalContext;
    public let storage: SignalStorage;
    fileprivate let devicesQueue: DispatchQueue = DispatchQueue(label: "omemo_devices_dispatch_queue");
    fileprivate var devices: [BareJID: [Int32]] = [:];
    /// When a list in `devices` came from our own fetch rather than from a
    /// notification. Only a notification keeps a list current, so a fetched
    /// one is trusted for `fetchedListLifetime`. Guarded by `devicesQueue`.
    fileprivate var devicesFetchedAt: [BareJID: Date] = [:];
    /// Why the last fetch of a contact's device list failed, until one works.
    /// Guarded by `devicesQueue`.
    fileprivate var deviceListErrors: [BareJID: PubSubError] = [:];
    /// Why the last fetch of a contact's bundle failed, with the error as the
    /// server gave it so that a passing one (a `wait`, a timeout) can be told
    /// from a final one. Cleared when a later bundle of theirs works, and by
    /// `forgetFetchFailures`. Guarded by `devicesQueue`.
    fileprivate var bundleErrors: [BareJID: PubSubError] = [:];
    /// Whether this module may publish our device list and bundles. Only the
    /// app does: the extensions use what the app stored, and a publish cut off
    /// by their time limit would leave keys stored here and not on the server.
    /// Set before the module is registered.
    public var publishesKeys = true;
    /// Cuts a device list we read for `jid` down before anything is built
    /// from it. A list can name thousands of devices, each one a bundle to
    /// fetch and a stanza to send; the policy is the app's. Nil keeps lists whole.
    public var limitDevices: ((BareJID, [Int32]) -> [Int32])?;
    /// Told what this module reads and publishes of our own keys, as plain
    /// facts with no address in them, for the app's diagnostics log. May be
    /// called from any thread. Set before the module is registered.
    public var diagnostics: (@Sendable (OMEMOEvent) -> Void)?;
    /// How long a fetched device list spares the next send a round trip. A
    /// contact who isn't subscribed to us sends no notifications, so it can't
    /// be forever; a minute is long enough for a conversation's messages.
    public static let fetchedListLifetime: TimeInterval = 60;
    /// The clock `fetchedListLifetime` is measured on; tests move it by hand.
    /// Set before the module is registered.
    public var now: @Sendable () -> Date = { Date() };
    /// Devices we couldn't build a session with, and when. They're skipped
    /// for a while rather than for the rest of the session: the failure may
    /// have been passing, and the device would otherwise never get messages.
    /// Guarded by `devicesQueue`.
    fileprivate var devicesFetchError: [BareJID: [Int32: Date]] = [:];
    public static let failedDeviceRetryInterval: TimeInterval = 60;
    private var ownBrokenDevices: [Int32] = [];
    /// Our own devices dropped from the list for having no bundle, and when.
    /// One that comes back is alive and has to publish its bundle itself, so
    /// it isn't dropped again for a day. Kept for the process, across
    /// sessions. Guarded by `devicesQueue`.
    fileprivate var ownDevicesDropped: [Int32: Date] = [:];
    /// Own devices whose drop is waiting for the list publish interval to be
    /// up. Guarded by `devicesQueue`.
    private var ownDropsDeferred: Set<Int32> = [];
    public static let ownDeviceDropBackoff: TimeInterval = 24 * 60 * 60;
    /// The least time between two automatic publishes of our device list,
    /// so that two clients disagreeing about it can't rewrite it at network
    /// speed. A publish that is held back is made once the time is up.
    public var listPublishInterval: TimeInterval = 10;
    /// Guarded by `listPublishLock`.
    private let listPublishLock = NSLock();
    private var lastListPublish: Date?;
    private var listPublishDeferred = false;
    private var deviceListPublishCount = 0;
    /// How many times this module has published our device list.
    public var deviceListPublishes: Int {
        return listPublishLock.withLock { deviceListPublishCount };
    }
    /// Bundle publishing runs one at a time: two at once generate keys with
    /// the same ids, and the second overwrites the first in the store while
    /// the server may keep the first bundle, whose private keys are gone.
    private let bundlePublishLock = NSLock();
    private var bundlePublish: (running: Bool, rerun: Bool, waiting: [() -> Void]) = (false, false, []);
    /// Whether our bundle is on the server in this session. The device list
    /// only counts us as ready once it is. Guarded by `bundlePublishLock`.
    private var bundleConfirmed = false;
    /// Whether the registration (device id after bundle) already waits for a
    /// publish, so retries don't queue it again. Guarded by `bundlePublishLock`.
    private var registrationQueued = false;
    /// How many retries registration has had, and the timer for the next.
    /// Guarded by `bundlePublishLock`.
    private var registrationAttempt = 0;
    private var registrationTimer: DispatchWorkItem?;
    /// How long to wait before each retry of a failed registration; the last
    /// one repeats. A failure is usually a passing one, but nothing else
    /// would try again within the session.
    public var registrationRetryDelays: [TimeInterval] = [5, 30, 120, 300];
    private let logger = os.Logger(subsystem: "MartinOMEMO", category: "OMEMOModule");

    @Published
    public private(set) var isReady: Bool = false {
        didSet {
            if isReady {
                cancelRegistrationRetry();
                endRegistration(ready: true);
            }
        }
    }

    /// How this connection's registration went, for the diagnostics log.
    /// Guarded by `bundlePublishLock`.
    private var registrationStartedAt: Date?;
    private var registrationResumed = false;
    private var registrationReported = false;

    private func beginRegistration(resumed: Bool) {
        bundlePublishLock.withLock {
            if registrationStartedAt == nil {
                registrationStartedAt = Date();
                registrationResumed = resumed;
            }
        }
    }

    /// Reports how the registration of this connection ended, once. `ready`
    /// false is a stream that went away before the device was.
    private func endRegistration(ready: Bool) {
        let ended: (resumed: Bool, seconds: TimeInterval?)? = bundlePublishLock.withLock {
            guard !registrationReported else {
                return nil;
            }
            registrationReported = true;
            let seconds = registrationStartedAt.map { Date().timeIntervalSince($0) };
            return (registrationResumed, seconds);
        };
        if let ended {
            report(.registrationEnded(resumed: ended.resumed, pepAvailable: isPepAvailable, ready: ready, seconds: ended.seconds));
        }
    }
    
    public let activeDevicesPublisher = PassthroughSubject<AvailabilityChanged,Never>();
    
    public func isAvailable(for jid: BareJID) -> Bool {
        return (!(self.devicesQueue.sync(execute: { self.devices[jid] })?.isEmpty ?? true)) || !self.storage.sessionStore.allDevices(for: jid.stringValue, activeAndTrusted: true).isEmpty;
    }
    
    public init(aesGCMEngine: AES_GCM_Engine, signalContext: SignalContext, signalStorage: SignalStorage) {
        self.signalContext = signalContext;
        self.storage = signalStorage;
        self.engine = aesGCMEngine;
        super.init();
    }
    
    public func reset(scopes: Set<ResetableScope>) {
        if !scopes.isDisjoint(with: [.session, .stream]) {
            if !isReady {
                endRegistration(ready: false);
            }
            bundlePublishLock.withLock {
                registrationStartedAt = nil;
                registrationResumed = false;
                registrationReported = false;
            }
        }
        if scopes.contains(.session) {
            self.isReady = false;
            bundlePublishLock.withLock {
                bundleConfirmed = false;
                registrationQueued = false;
                registrationAttempt = 0;
                bundlePublish.waiting.removeAll();
            }
            self.devicesQueue.async {
                self.devices.removeAll();
                self.devicesFetchedAt.removeAll();
                self.devicesFetchError.removeAll();
                self.ownBrokenDevices.removeAll();
            }
        }
        if !scopes.isDisjoint(with: [.session, .stream]) {
            // Nothing can be published while disconnected. A resumed stream
            // starts registration again through `resumeRegistrationIfNeeded`.
            cancelRegistrationRetry();
            // A disconnect can cut a sync short and nothing then finishes it.
            // Left in place it would hold back repair on the next connection
            // for good. What it postponed can't be sent from here, and the
            // next catch-up or message repairs what is still broken.
            self.devicesQueue.async {
                self.mamSyncsInProgress.removeAll();
                // The prekeys those sessions used are still published. Taking
                // them out is not left for a sync that will never finish.
                if self.postponedSessions.values.contains(where: { !$0.isEmpty }) && self.storage.preKeyStore.flushDeletedPreKeys() {
                    self.publishDeviceBundleIfNeeded(completionHandler: nil, afterPreKeyUse: true);
                }
                self.postponedSessions.removeAll();
                self.postponedHealing.removeAll();
                self.healing.reset();
            }
        }
    }
    
    public func regenerateKeys(wipe: Bool = false) -> Bool {
        let regenerated = self.storage.regenerateKeys(wipe: wipe);
        if regenerated && isPepAvailable {
            self.publishDeviceBundle(currentBundle: nil) {
                self.publishDeviceIdIfNeeded();
            }
        }
        return regenerated;
    }
    
    public func devices(for jid: BareJID) -> [Int32]? {
        return devicesQueue.sync {
            if let fetched = devicesFetchedAt[jid], now().timeIntervalSince(fetched) > OMEMOModule.fetchedListLifetime {
                return nil;
            }
            return self.devices[jid].map { self.withoutRecentFailures($0, of: jid) }
        }
    }

    /// Tells the module that notifications for `jid`'s device list have
    /// stopped, because we are no longer subscribed to their presence. A list
    /// that came by notification is trusted for the life of the process; from
    /// now on it is treated as one we fetched just now, so it is reused for
    /// `fetchedListLifetime` and then read again before a send, and a device
    /// they add later is found. Lists without a notification date, and our own,
    /// are left alone. Hops onto `devicesQueue` with `async`: callers may be
    /// on it, and a `sync` from there deadlocks.
    public func listNoLongerNotified(for jid: BareJID) {
        let ended = now();
        devicesQueue.async {
            guard self.context?.userBareJid != jid, self.devices[jid] != nil, self.devicesFetchedAt[jid] == nil else {
                return;
            }
            self.devicesFetchedAt[jid] = ended;
        }
    }

    /// Call on `devicesQueue`.
    private func withoutRecentFailures(_ devices: [Int32], of jid: BareJID) -> [Int32] {
        guard let failed = devicesFetchError[jid] else {
            return devices;
        }
        let now = Date();
        return devices.filter { deviceId in
            failed[deviceId].map { now.timeIntervalSince($0) >= OMEMOModule.failedDeviceRetryInterval } ?? true
        };
    }

    
    public func process(stanza: Stanza) throws {
        throw ErrorCondition.feature_not_implemented;
    }
    
    public func decode(message: Message, serverMsgId: String? = nil) -> DecryptionResult<Message, SignalError> {
        guard let from = message.from?.bareJid else {
            return .failure(.invalidArgument);
        }
        return self.decode(message: message, from: from, serverMsgId: serverMsgId);
    }
    
    
    public func decode(message: Message, from: BareJID, serverMsgId: String? = nil) -> DecryptionResult<Message, SignalError> {
        guard let context = context else {
            return .failure(.unknown);
        }

        guard let encryptedEl = message.findChild(name: "encrypted", xmlns: OMEMOModule.XMLNS) else {
            return .failure(SignalError.notEncrypted);
        }
        
        guard let headerEl = encryptedEl.findChild(name: "header"), let sid = UInt32(headerEl.getAttribute("sid") ?? "") else {
            return .failure(.invalidArgument);
        }
        
        let localDeviceIdStr = String(signalContext.storage.identityKeyStore.localRegistrationId());
        
        guard headerEl.findChild(where: { (el) -> Bool in
            return el.name == "key" && el.getAttribute("rid") == localDeviceIdStr;
        }) != nil else {
            guard context.userBareJid != from || sid != signalContext.storage.identityKeyStore.localRegistrationId() else {
                return .failure(.duplicateMessage);
            }
            guard encryptedEl.findChild(name: "payload") != nil else {
                return .failure(.duplicateMessage);
            }
            return .failure(.invalidMessage);
        }
        
        let possibleKeys = headerEl.getChildren(where: { (el) -> Bool in
            return el.name == "key" && el.getAttribute("rid") == localDeviceIdStr;
        }).map({ (keyEl) -> KeyDecryptionResult in
            let prekey = "true" == keyEl.getAttribute("prekey") || keyEl.getAttribute("prekey") == "1";
            let address = SignalAddress(name: from.stringValue, deviceId: Int32(bitPattern: sid));
            guard let keyElValue = keyEl.value, let key = Data(base64Encoded: keyElValue) else {
                return .init(result: .failure(.invalidArgument), address: address, isPrekey: prekey);
            }
            guard let session = SignalSessionCipher(withAddress: address, andContext: self.signalContext) else {
                return .init(result: .failure(SignalError.noMemory), address: address, isPrekey: prekey);
            }
            return .init(result: session.decrypt(key: SignalSessionCipher.Key(key: key,deviceId: Int32(bitPattern: sid), prekey: prekey)), address: address, isPrekey: prekey);
        });
        
        guard let possibleKey = possibleKeys.first(where: { $0.isSuccess }) else {
            if let key = possibleKeys.first {
                switch key.result {
                case .failure(let error):
                    switch error {
                    case .noSession, .invalidMessage:
                        if serverMsgId != nil {
                            if !postponeHealing(for: message.type == .groupchat ? message.from?.bareJid : nil, address: key.address) {
                                if claimHealing(key.address) {
                                    self.repairSession(forAddress: key.address);
                                }
                            }
                        }
                    default:
                        break;
                    }
                    return .failure(error);
                case .success(_):
                    return .failure(.unknown);
                }
            } else {
                guard encryptedEl.findChild(name: "payload") != nil else {
                    return .failure(.duplicateMessage);
                }
                return .failure(.invalidMessage);
            }
        }
        
        switch possibleKey.result {
        case .failure(let error):
            return .failure(error);
        case .success(let data):
            message.removeChild(encryptedEl);
            // The session works again, so a later failure deserves a repair.
            healing.sessionWorks(possibleKey.address);

            let address = possibleKey.address;
            let prekey = possibleKey.isPrekey;
            var decodedKey = data;
            
            if prekey {
                // pre key was removed so we need to republish the bundle!
                if !postponeSession(for: message.type == .groupchat ? message.from?.bareJid : nil, address: address) {
                    if self.storage.preKeyStore.flushDeletedPreKeys() {
                        self.publishDeviceBundleIfNeeded(completionHandler: nil, afterPreKeyUse: true);
                    }
                }
            }

            var auth: Data? = nil;
            if decodedKey.count >= 32 {
                auth = decodedKey.subdata(in: 16..<decodedKey.count);
                decodedKey = decodedKey.subdata(in: 0..<16);
            }
            
            guard let ivStr = headerEl.findChild(name: "iv")?.value, let iv = Data(base64Encoded: ivStr) else {
                return .failure(.invalidArgument);
            }
            
            guard let payloadValue = encryptedEl.findChild(name: "payload")?.value, let payload = Data(base64Encoded: payloadValue) else {
                return .successTransportKey(decodedKey, iv: iv);
            }


            var decoded = Data();
            guard engine.decrypt(iv: iv, key: decodedKey, encoded: payload, auth: auth, output: &decoded) else {
                print("decoding of encrypted message failed!");
                return .failure(.invalidMac);
            }
            
            let body = String(data: decoded, encoding: .utf8);
            message.body = body;
            
            if let content = body, content.starts(with: "aesgcm://"), URLComponents(string: content) != nil {
                message.oob = content;
            }

            _ = storage.identityKeyStore.setStatus(active: true, forIdentity: address);
            return .successMessage(message, fingerprint: storage.identityKeyStore.identityFingerprint(forAddress: address));
        }
    }
    
    public func encode(message: Message, withStoreHint: Bool = true, completionHandler: @escaping (EncryptionResult<Message, SignalError>)->Void) {
        guard let jid = message.to?.bareJid else {
            completionHandler(.failure(.noDestination));
            return;
        }

        encode(message: message, for: [jid], withStoreHint: withStoreHint, completionHandler: completionHandler);
    }
    
    /// What every publish asks of its node: open to everyone. XEP-0060 §7.1.5
    /// wants the form to say what it is, which a server may check.
    static func openPublishOptions() -> PubSubNodeConfig {
        let options = PubSubNodeConfig();
        options.FORM_TYPE = "http://jabber.org/protocol/pubsub#publish-options";
        options.accessModel = .open;
        return options;
    }

    /// Why the last attempt to read `jid`'s device list failed, if it did: a
    /// server that keeps the list from non-subscribers says not-authorized.
    /// The error is kept whole, as whether it passes depends on its type.
    public func deviceListError(for jid: BareJID) -> PubSubError? {
        devicesQueue.sync { deviceListErrors[jid] }
    }

    /// Why `jid`'s bundle couldn't be fetched, if the last attempt failed.
    public func bundleError(for jid: BareJID) -> PubSubError? {
        devicesQueue.sync { bundleErrors[jid] }
    }

    /// Lets the next send try `jid`'s devices again at once: a device whose
    /// bundle failed is otherwise skipped for `failedDeviceRetryInterval`,
    /// which a caller that retries a passing failure must not wait for.
    public func forgetFetchFailures(for jid: BareJID) {
        devicesQueue.sync {
            devicesFetchError[jid] = nil;
            bundleErrors[jid] = nil;
            deviceListErrors[jid] = nil;
        }
    }

    /// The devices of each of `jids`, with sessions built for any we lack.
    /// Our own account may be among them: this device is left out, since
    /// there's no session to have with ourselves.
    public func addresses(for jids: [BareJID], completionHandler: @escaping(Result<[SignalAddress],SignalError>)->Void) {
        guard let context = context else {
            completionHandler(.failure(.unknown));
            return;
        }
        let pubsubModule = context.module(.pubsub);
        let localId = storage.identityKeyStore.localRegistrationId();
        // Each JID's results stay its own; the fetches complete on any queue.
        let lock = NSLock();
        var addresses: [SignalAddress] = [];
        let group = DispatchGroup();

        func collect(_ jid: BareJID, _ deviceIds: [Int32]) {
            let found = deviceIds
                .filter { !(jid == context.userBareJid && UInt32(bitPattern: $0) == localId) }
                .map { SignalAddress(name: jid.stringValue, deviceId: $0) };
            lock.withLock { addresses.append(contentsOf: found) };
            for address in found where !storage.sessionStore.containsSessionRecord(forAddress: address) {
                group.enter();
                buildSession(forAddress: address, completionHandler: {
                    group.leave();
                });
            }
        }

        for jid in jids {
            if let devices = self.devices(for: jid) {
                collect(jid, devices);
                continue;
            }
            group.enter();
            pubsubModule.retrieveItems(from: jid, for: OMEMOModule.DEVICES_LIST_NODE, limit: .lastItems(1), completionHandler: { result in
                defer { group.leave() }
                guard case .success(let items) = result, let listEl = items.items.first?.payload,
                      listEl.name == "list" && listEl.xmlns == OMEMOModule.XMLNS else {
                    if case .failure(let error) = result {
                        self.devicesQueue.sync { self.deviceListErrors[jid] = error };
                        self.logger.info("No device list for \(jid.stringValue, privacy: .private(mask: .hash)): \(error.error.errorCondition.rawValue, privacy: .public)");
                    }
                    return;
                }
                let listedDevices: [Int32] = listEl.mapChildren(transform: { $0.getAttribute("id") }).compactMap({ Int32(omemoId: $0) });
                let knownActiveDevices = self.limitDevices?(jid, listedDevices) ?? listedDevices;
                self.activeDevicesPublisher.send(AvailabilityChanged(jid: jid, activeDevices: knownActiveDevices, readFromServer: true));
                let allDevices = self.storage.sessionStore.allDevices(for: jid.stringValue, activeAndTrusted: true);
                for deviceId in allDevices where !knownActiveDevices.contains(deviceId) {
                    _ = self.storage.identityKeyStore.setStatus(active: false, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
                }
                for deviceId in knownActiveDevices where !allDevices.contains(deviceId) {
                    _ = self.storage.identityKeyStore.setStatus(active: true, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
                }
                // Remembered, or every message would wait for this round trip.
                // A notification's list, which has no date, is left alone.
                let usable: [Int32] = self.devicesQueue.sync {
                    self.deviceListErrors[jid] = nil;
                    self.bundleErrors[jid] = nil;
                    if self.devices[jid] == nil || self.devicesFetchedAt[jid] != nil {
                        self.devices[jid] = knownActiveDevices;
                        self.devicesFetchedAt[jid] = self.now();
                    }
                    return self.withoutRecentFailures(knownActiveDevices, of: jid);
                };
                collect(jid, usable);
            })
        }
        // Not the main queue: a busy interface would hold up every send.
        group.notify(queue: DispatchQueue.global(qos: .userInitiated), execute: {
            completionHandler(.success(lock.withLock { addresses }));
        })
    }
    
    public func encode(message: Message, for jids: [BareJID], withStoreHint: Bool = true, completionHandler: @escaping (EncryptionResult<Message, SignalError>)->Void) {
        
        addresses(for: jids, completionHandler: { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error));
            case .success(let addresses):
                if addresses.isEmpty {
                    completionHandler(.failure(.noSession));
                } else {
                    self.encode(message: message, forAddresses: addresses, withStoreHint: withStoreHint, completionHandler: completionHandler);
                }
            }
            
        })
    }
     
    /// - Parameter forSelf: also encrypt for our own devices, as it always did.
    ///   Off, `addresses` is all there is, so the caller picks our devices.
    public func encode(message: Message, forAddresses addresses: [SignalAddress], withStoreHint: Bool = true, forSelf: Bool = true, completionHandler: @escaping (EncryptionResult<Message, SignalError>)->Void) {

        let result = self._encode(message: message, for: addresses, forSelf: forSelf);
        
        switch result {
        case .successMessage(let encodedMessage, _):
            encodedMessage.body = self.defaultBody;
            if withStoreHint {
                encodedMessage.addChild(Element(name: "store", xmlns: "urn:xmpp:hints"));
            }
        default:
            break;
        }
        
        completionHandler(result);
    }
    
    public func decryptFile(url localUrl: URL, fragment: String) -> Result<Data,ErrorCondition> {
        guard let data = try? Data(contentsOf: localUrl) else {
            return .failure(ErrorCondition.item_not_found);
        }

        return decryptFile(data: data, fragment: fragment);
    }
    
    public func decryptFile(data inData: Data, fragment: String) -> Result<Data,ErrorCondition> {
        guard fragment.count % 2 == 0 && fragment.count > 64 && inData.count > 32 else {
            return .failure(.not_acceptable);
        }
        
        let fragmentData = fragment.map { (c) -> UInt8 in
            return UInt8(c.hexDigitValue ?? 0);
        };

        let ivLen = fragmentData.count - (32 * 2);
        
        var iv = Data();
        var key = Data();
        
        for i in 0..<(ivLen/2) {
            iv.append(fragmentData[i*2]*16 + fragmentData[i*2+1]);
        }
        for i in (ivLen/2)..<(fragmentData.count/2) {
            key.append(fragmentData[i*2]*16 + fragmentData[i*2+1]);
        }
        
        let tag = inData.subdata(in: inData.count-16..<inData.count);
        let encodedData = inData.subdata(in: 0..<(inData.count-16));
        var decoded = Data();
        
        guard engine.decrypt(iv: iv, key: key, encoded: encodedData, auth: tag, output: &decoded) else {
            return .failure(.not_acceptable);
        }
        
        return .success(decoded);
    }
    
    public func encryptFile(url: URL) -> Result<(Data, String),ErrorCondition> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ErrorCondition.item_not_found);
        }

        return encryptFile(data: data);
    }
    
    public func encryptFile(data: Data) -> Result<(Data, String),ErrorCondition> {
        var iv = Data(count: 12);
        iv.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, bytes.baseAddress!);
        }

        var key = Data(count: 32);
        key.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!);
        }

        var encryptedBody = Data();
        var tag = Data();

        guard engine.encrypt(iv: iv, key: key, message: data, output: &encryptedBody, tag: &tag) else {
            return .failure(.not_acceptable);
        }
        
        let combinedKey = iv + key;

        return .success((encryptedBody + tag, combinedKey.map({ String(format: "%02x", $0) }).joined()));
    }
    
    private func _encode(message: Message, for remoteAddresses: [SignalAddress], forSelf: Bool = true) -> EncryptionResult<Message,SignalError> {
        guard let context = self.context else {
            return .failure(.unknown);
        }
        
        var iv = Data(count: 12);
        iv.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, bytes.baseAddress!);
        }

        var key = Data(count: 16);
        key.withUnsafeMutableBytes { (bytes) -> Void in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, bytes.baseAddress!);
        }
        
        var tag = Data();
        var combinedKey = key;
        
        let encryptedEl = Element(name: "encrypted", xmlns: OMEMOModule.XMLNS);

        if let data = message.body?.data(using: .utf8) {
            var encryptedBody = Data();
            guard engine.encrypt(iv: iv, key: key, message: data, output: &encryptedBody, tag: &tag) else {
                return .failure(.notEncrypted);
            }
            encryptedEl.addChild(Element(name: "payload", cdata: encryptedBody.base64EncodedString()));
        }
                
        combinedKey.append(tag);

        let header = Element(name: "header");
        header.setAttribute("sid", value: String(signalContext.storage.identityKeyStore.localRegistrationId()));
        encryptedEl.addChild(header);
        
        let localAddresses = forSelf ? storage.sessionStore.allDevices(for: context.userBareJid.stringValue, activeAndTrusted: true).map({ (deviceId) -> SignalAddress in
            return SignalAddress(name: context.userBareJid.stringValue, deviceId: deviceId);
        }) : [];
        let destinations: Set<SignalAddress> = Set(remoteAddresses + localAddresses);
        header.addChildren(destinations.map({ (addr) -> Result<SignalSessionCipher.Key,SignalError> in
                // TODO: maybe we should cache this session?
                guard let session = SignalSessionCipher(withAddress: addr, andContext: self.signalContext) else {
                    return .failure(.noMemory);
                }
                return session.encrypt(data: combinedKey);
            }).map({ (result) -> Element? in
                switch result {
                case .success(let key):
                    let keyEl = Element(name: "key", cdata: key.key.base64EncodedString());
                    keyEl.setAttribute("rid", value: key.deviceId.omemoId);
                    if key.prekey {
                        keyEl.setAttribute("prekey", value: "true");
                    }
                    return keyEl;
                case .failure(_):
                    return nil;
                }
            }).filter({ (el) -> Bool in
                return el != nil;
            }).map({ el -> Element in
                return el!;
            }));
        header.addChild(Element(name: "iv", cdata: iv.base64EncodedString()));

        message.body = nil;
        message.addChild(Element(name: "store", xmlns: "urn:xmpp:hints"));
        message.addChild(encryptedEl);
        
        let fingerprint = storage.identityKeyStore.identityFingerprint(forAddress: SignalAddress(name: context.userBareJid.stringValue, deviceId: Int32(bitPattern: storage.identityKeyStore.localRegistrationId())));
        
        return .successMessage(message, fingerprint: fingerprint);
    }
    
    private var mamSyncsInProgress: Set<BareJID?> = [];
    
    open func mamSyncStarted(for jid: BareJID?) {
        self.devicesQueue.sync {
            self.mamSyncsInProgress.insert(jid);
            self.postponedSessions[jid] = [];
            // Without this, `postponeHealing` finds no list to add to and
            // lets every undecryptable archived message start its own repair.
            self.postponedHealing[jid] = [];
        }
    }
    
    open func mamSyncFinished(for jid: BareJID?) {
        self.devicesQueue.sync {
            self.mamSyncsInProgress.remove(jid);
            self.processPostponed(for: jid);
        }
    }
    
    open override func onItemNotification(notification: PubSubModule.ItemNotification) {
        if notification.node == OMEMOModule.DEVICES_LIST_NODE, let context = self.context {
            switch notification.action {
            case .published(let item):
                let from = notification.message.from?.bareJid ?? context.userBareJid;
                checkAndPublishDevicesListIfNeeded(jid: from, list: item.payload, fromNotification: true)
            default:
                break;
            }
        }
    }
    
    /// `completionHandler` runs once the list is published, or it's known it
    /// won't be: only used when removing devices, which has to tell the user.
    func publishDeviceIdIfNeeded(removeDevicesWithIds: [UInt32]? = nil, removalReason: OMEMOEvent.ListPublishReason = .removalRequested, completionHandler: ((Result<Void, PubSubError>) -> Void)? = nil) {
        guard publishesKeys, isPepAvailable, let context = context else {
            completionHandler?(.failure(.undefined_condition));
            return;
        }
        let pepJid = context.userBareJid;
        context.module(.pubsub).retrieveItems(from: pepJid, for: OMEMOModule.DEVICES_LIST_NODE, limit: .lastItems(1), completionHandler: { result in
            switch result {
            case .success(let items):
                self.logger.debug("Read our published devices");
                self.checkAndPublishDevicesListIfNeeded(jid: pepJid, list: items.items.first?.payload, removeDevicesWithIds: removeDevicesWithIds, removalReason: removalReason, completionHandler: completionHandler);
            case .failure(let pubsubError):
                guard pubsubError.error == .item_not_found || pubsubError.error == .internal_server_error() else {
                    completionHandler?(.failure(pubsubError));
                    return;
                }
                // An empty node is a real, empty list; a server error says nothing about the list.
                self.checkAndPublishDevicesListIfNeeded(jid: pepJid, list: nil, readFromServer: pubsubError.error == .item_not_found, completionHandler: completionHandler);
            }
        });
    }

    fileprivate func checkAndPublishDevicesListIfNeeded(jid: BareJID, list input: Element?, readFromServer: Bool = true, fromNotification: Bool = false, removeDevicesWithIds: [UInt32]? = nil, removalReason: OMEMOEvent.ListPublishReason = .removalRequested, completionHandler: ((Result<Void, PubSubError>) -> Void)? = nil) {
        guard let context = context else {
            completionHandler?(.failure(.undefined_condition));
            return;
        }

        let pubsubModule = context.module(.pubsub);
        var listEl = input;

        if listEl?.name != "list" || listEl?.xmlns != "eu.siacs.conversations.axolotl" {
            listEl = Element(name: "list", xmlns: "eu.siacs.conversations.axolotl");
        }
        
        
        let me = context.userBareJid == jid;
        
        if me, readFromServer || fromNotification {
            let listed = listEl!.filterChildren(name: "device", xmlns: nil).compactMap { $0.getAttribute("id") };
            report(.ownListRead(count: listed.count, includesThisDevice: listed.contains(String(storage.identityKeyStore.localRegistrationId())), source: fromNotification ? .notification : .fetch));
        }

        if me && publishesKeys {
            var changed = false;
            var reason = removalReason;
            
            if removeDevicesWithIds != nil && listEl != nil {
                let deviceIds = removeDevicesWithIds!.map { (deviceId) -> String in
                    return String(deviceId);
                }
                listEl!.removeChildren(where: { (el) -> Bool in
                    guard let id = el.getAttribute("id") else {
                        return false;
                    }
                    return deviceIds.contains(id);
                });
                changed = true;
            }
        
            let ourDeviceId = self.storage.identityKeyStore.localRegistrationId();
            let ourDeviceIdStr = String(ourDeviceId);
            var missingSelf = false;
            if listEl?.findChild(where: { (deviceEl) -> Bool in
                deviceEl.getAttribute("id") == ourDeviceIdStr;
            }) == nil {
                listEl?.addChild(Element(name: "device", attributes: ["id": ourDeviceIdStr]));
                changed = true;
                missingSelf = true;
                if removeDevicesWithIds == nil {
                    reason = isReady ? .readdedSelf : .registration;
                }
            }
        
            if changed, removeDevicesWithIds == nil, let wait = reserveAutomaticListPublish() {
                logger.info("Not publishing our device list again for \(Int(wait.rounded(.up)), privacy: .public)s: it was published just now");
                deferListPublish(after: wait);
                completionHandler?(.success(()));
            } else if changed {
                if removeDevicesWithIds != nil {
                    listPublishLock.withLock { lastListPublish = Date() };
                }
                let list = listEl!;
                let publish = {
                    self.publishDeviceList(list, at: jid, deviceId: ourDeviceIdStr, reason: reason, completionHandler: completionHandler);
                };
                if missingSelf && removeDevicesWithIds == nil {
                    // Another of our clients may have dropped us for having no
                    // bundle, and deleted it; re-adding just our id would have
                    // it drop us again, forever. Make sure the bundle is there.
                    publishDeviceBundleIfNeeded(completionHandler: publish);
                } else {
                    publish();
                }
            } else if bundlePublishLock.withLock({ bundleConfirmed }) {
                // Listed isn't enough: a bundle that never got published
                // leaves contacts unable to encrypt for us. Once it is, the
                // registration checks the list again.
                self.isReady = true;
                context.sessionObject.setProperty(OMEMOModule.DEVICES_LIST_NODE, value: true);
                completionHandler?(.success(()));
            } else {
                completionHandler?(.success(()));
            }
        } else {
            completionHandler?(.success(()));
        }

        let listedDevices = listEl!.mapChildren(transform: { (el) -> Int32? in
            guard let id = el.getAttribute("id") else {
                return nil;
            }
            // Ids are unsigned 32-bit numbers in the protocol; stored as their bit pattern.
            return Int32(omemoId: id);
        });
        let knownActiveDevices = limitDevices?(jid, listedDevices) ?? listedDevices;
        
        let allDevices = storage.sessionStore.allDevices(for: jid.stringValue, activeAndTrusted: true);
        allDevices.filter { (id) -> Bool in
            return !knownActiveDevices.contains(id);
            }.forEach { (deviceId) in
                _ = storage.identityKeyStore.setStatus(active: false, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
        }
        
        knownActiveDevices.filter { (id) -> Bool in
            return !allDevices.contains(id);
            }.forEach { (deviceId) in
                // TODO: we should enable this device key if we have its identity!
                _ = storage.identityKeyStore.setStatus(active: true, forIdentity: SignalAddress(name: jid.stringValue, deviceId: deviceId));
        }
        
        if me {
            let group = DispatchGroup();
            group.enter();
            knownActiveDevices.forEach { (deviceId) in
                guard deviceId != self.storage.identityKeyStore.localRegistrationId() else {
                    return;
                }
                let address = SignalAddress(name: jid.stringValue, deviceId: deviceId);
                if !self.storage.sessionStore.containsSessionRecord(forAddress: address) {
                    // we do not have a session, so we need to build one!
                    group.enter();
                    self.buildSession(forAddress: address, completionHandler: {
                        group.leave();
                    });
                }
            }
            group.leave();
            // Only once the sessions above are tried: registered before them,
            // this ran at once on what earlier rounds had found.
            group.notify(queue: self.devicesQueue, execute: {
                let brokenIds = self.ownBrokenDevices.filter { knownActiveDevices.contains($0) };
                self.ownBrokenDevices.removeAll();
                guard !brokenIds.isEmpty, self.publishesKeys else {
                    return;
                }
                self.dropOwnDevices(brokenIds);
            })
        }
        self.devicesQueue.async {
            self.devices[jid] = knownActiveDevices;
            self.devicesFetchedAt[jid] = nil;
            self.activeDevicesPublisher.send(AvailabilityChanged(jid: jid, activeDevices: knownActiveDevices, readFromServer: readFromServer));
            self.fire(AvailabilityChangedEvent(sessionObject: context.sessionObject, jid: jid));
        }
    }

    /// Takes our own bundle-less devices out of the list, unless they were
    /// taken out within `ownDeviceDropBackoff`. When the list was published
    /// just now the drop waits for the interval to be up, as the publish does:
    /// the round that found them is over and nothing else would find them
    /// again. Runs on `devicesQueue`.
    private func dropOwnDevices(_ brokenIds: [Int32]) {
        let now = Date();
        let due = brokenIds.filter { id in
            guard let at = ownDevicesDropped[id] else {
                return true;
            }
            return now.timeIntervalSince(at) >= OMEMOModule.ownDeviceDropBackoff;
        };
        guard !due.isEmpty else {
            logger.info("Own devices \(brokenIds, privacy: .private(mask: .hash)) have no bundles but came back after being dropped; leaving them be");
            return;
        }
        if let wait = reserveAutomaticListPublish() {
            logger.info("Not dropping own devices \(due, privacy: .private(mask: .hash)) for \(Int(wait.rounded(.up)), privacy: .public)s: the list was published just now");
            report(.ownDropDeferred(count: due.count));
            let schedule = ownDropsDeferred.isEmpty;
            ownDropsDeferred.formUnion(due);
            if schedule {
                devicesQueue.asyncAfter(deadline: .now() + wait, execute: { [weak self] in
                    guard let self else {
                        return;
                    }
                    let ids = Array(self.ownDropsDeferred);
                    self.ownDropsDeferred.removeAll();
                    self.recheckAndDropOwnDevices(ids);
                });
            }
            return;
        }
        due.forEach { ownDevicesDropped[$0] = now };
        report(.ownDevicesDropped(count: due.count));
        logger.info("Dropping own devices \(due, privacy: .private(mask: .hash)) from the list: they have no bundles");
        removeDevices(withIds: due, deleteBundles: false);
    }

    /// The wait before a deferred drop was long enough for a device to
    /// publish its bundle, and dropping it then would start the fight this
    /// is here to stop. Fetches the bundles again, which is what found them
    /// missing, and drops only those still missing. Runs on `devicesQueue`.
    private func recheckAndDropOwnDevices(_ ids: [Int32]) {
        guard let account = context?.userBareJid else {
            return;
        }
        let group = DispatchGroup();
        // A session made during the wait means the device is alive. Building
        // again would replace it and use up one of its one-time prekeys.
        let alive = Set(ids.filter { storage.sessionStore.containsSessionRecord(forAddress: SignalAddress(name: account.stringValue, deviceId: $0)) });
        ids.filter { !alive.contains($0) }.forEach { id in
            group.enter();
            // Off `devicesQueue`: a fetch records its outcome on it, and one
            // that answers at once would wait for the queue it is running on.
            DispatchQueue.global().async {
                self.buildSession(forAddress: SignalAddress(name: account.stringValue, deviceId: id), completionHandler: {
                    group.leave();
                });
            }
        }
        group.notify(queue: devicesQueue, execute: { [weak self] in
            guard let self else {
                return;
            }
            // A fetch that found no bundle has put the id back in
            // `ownBrokenDevices`; one that found it, or failed otherwise, has not.
            let stillBroken = ids.filter { !alive.contains($0) && self.ownBrokenDevices.contains($0) };
            self.ownBrokenDevices.removeAll(where: { ids.contains($0) });
            guard !stillBroken.isEmpty else {
                return;
            }
            self.dropOwnDevices(stillBroken);
        });
    }

    /// Reserves the next automatic publish of our device list: nil if it may
    /// go out now, else how long it has to wait.
    private func reserveAutomaticListPublish() -> TimeInterval? {
        return listPublishLock.withLock {
            let now = Date();
            if let last = lastListPublish, now.timeIntervalSince(last) < listPublishInterval {
                return listPublishInterval - now.timeIntervalSince(last);
            }
            lastListPublish = now;
            return nil;
        }
    }

    private func deferListPublish(after wait: TimeInterval) {
        let schedule = listPublishLock.withLock { () -> Bool in
            if listPublishDeferred {
                return false;
            }
            listPublishDeferred = true;
            return true;
        };
        guard schedule else {
            return;
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: { [weak self] in
            guard let self else {
                return;
            }
            self.listPublishLock.withLock { self.listPublishDeferred = false };
            self.publishDeviceIdIfNeeded();
        });
    }

    private func report(_ event: OMEMOEvent) {
        diagnostics?(event);
    }

    /// Publishes our device list. A node configured otherwise refuses the
    /// publish options (precondition-not-met, a conflict condition, whatever
    /// text the server adds); reconfigure it and try again.
    private func publishDeviceList(_ list: Element, at jid: BareJID, deviceId: String, reason: OMEMOEvent.ListPublishReason, completionHandler: ((Result<Void, PubSubError>) -> Void)? = nil) {
        guard let pubsubModule = context?.module(.pubsub) else {
            completionHandler?(.failure(.undefined_condition));
            return;
        }
        let publishOptions = OMEMOModule.openPublishOptions();
        let registered = {
            self.listPublishLock.withLock { self.deviceListPublishCount += 1 };
            self.isReady = true;
            self.logger.info("Device \(deviceId, privacy: .private(mask: .hash)) registered");
            let listed = list.filterChildren(name: "device", xmlns: nil).compactMap { $0.getAttribute("id") };
            self.report(.ownListPublished(count: listed.count, includesThisDevice: listed.contains(deviceId), reason: reason));
        };
        pubsubModule.publishItem(at: jid, to: OMEMOModule.DEVICES_LIST_NODE, itemId: "current", payload: list, publishOptions: publishOptions, completionHandler: { result in
            switch result {
            case .success(_):
                registered();
                self.ensureOpen(node: OMEMOModule.DEVICES_LIST_NODE, at: jid);
                completionHandler?(.success(()));
            case .failure(let pubsubError):
                guard case .conflict = pubsubError.error else {
                    self.logger.error("Publishing the device list failed: \(pubsubError.error.errorCondition.rawValue, privacy: .public)");
                    self.report(.ownListPublishFailed(condition: pubsubError.error.errorCondition.rawValue, type: pubsubError.errorType));
                    completionHandler?(.failure(pubsubError));
                    return;
                }
                self.reconfigureOpen(node: OMEMOModule.DEVICES_LIST_NODE, at: jid, failed: {
                    completionHandler?(.failure(pubsubError));
                }) {
                    pubsubModule.publishItem(at: jid, to: OMEMOModule.DEVICES_LIST_NODE, itemId: "current", payload: list, publishOptions: publishOptions, completionHandler: { result in
                        switch result {
                        case .success(_):
                            registered();
                            completionHandler?(.success(()));
                        case .failure(let error):
                            self.logger.error("Publishing the device list failed again: \(error.error.errorCondition.rawValue, privacy: .public)");
                            self.report(.ownListPublishFailed(condition: error.error.errorCondition.rawValue, type: error.errorType));
                            completionHandler?(.failure(error));
                        }
                    });
                }
            }
        });
    }

    /// Some servers (Openfire) answer a publish with success and keep their
    /// own access model, which hides the node from contacts who aren't
    /// subscribed to us. Checks what the node ended up with and opens it.
    private func ensureOpen(node: String, at jid: BareJID?) {
        guard let pubsubModule = context?.module(.pubsub), let pepJid = jid ?? context?.userBareJid else {
            return;
        }
        pubsubModule.retrieveNodeConfiguration(from: pepJid, node: node, resultHandler: { result in
            guard case .success(let form) = result, form.accessModel != .open else {
                return;
            }
            self.logger.info("The server ignored the access model asked for \(node, privacy: .public); opening it")
            form.accessModel = .open;
            pubsubModule.configureNode(at: pepJid, node: node, with: form, completionHandler: { result in
                if case .failure(let error) = result {
                    self.logger.error("Opening \(node, privacy: .public) failed: \(error.error.errorCondition.rawValue, privacy: .public)");
                }
            });
        });
    }

    private func reconfigureOpen(node: String, at jid: BareJID?, failed: (() -> Void)? = nil, then: @escaping () -> Void) {
        guard let pubsubModule = context?.module(.pubsub), let pepJid = jid ?? context?.userBareJid else {
            failed?();
            return;
        }
        pubsubModule.retrieveNodeConfiguration(from: pepJid, node: node, resultHandler: { result in
            switch result {
            case .success(let form):
                form.accessModel = .open;
                pubsubModule.configureNode(at: pepJid, node: node, with: form, completionHandler: { result in
                    switch result {
                    case .success(_):
                        then();
                    case .failure(let error):
                        self.logger.error("Reconfiguring \(node, privacy: .public) failed: \(error.error.errorCondition.rawValue, privacy: .public)");
                        failed?();
                    }
                });
            case .failure(let error):
                self.logger.error("Reading the configuration of \(node, privacy: .public) failed: \(error.error.errorCondition.rawValue, privacy: .public)");
                failed?();
            }
        });
    }

    /// Publishes our bundle, then our device id, and tries again with a
    /// growing delay for as long as that hasn't worked and PEP is available.
    private func registerDevice(resumed: Bool = false) {
        guard publishesKeys else {
            return;
        }
        beginRegistration(resumed: resumed);
        // Prekeys used while a catch-up was cut short, or in an extension that
        // ended first, are only marked deleted; the bundle then still has them.
        _ = storage.preKeyStore.flushDeletedPreKeys();
        publishDeviceBundleIfNeeded(completionHandler: nil, registration: true);
        scheduleRegistrationRetry();
    }

    /// For a resumed stream: discovery doesn't run again there, so nothing
    /// else would retry a registration that failed before the disconnect.
    public func resumeRegistrationIfNeeded() {
        guard isPepAvailable, !isReady else {
            return;
        }
        bundlePublishLock.withLock { registrationAttempt = 0 };
        registerDevice(resumed: true);
    }

    private func scheduleRegistrationRetry() {
        bundlePublishLock.withLock {
            registrationTimer?.cancel();
            let delays = registrationRetryDelays;
            guard !delays.isEmpty else {
                return;
            }
            let delay = delays[min(registrationAttempt, delays.count - 1)];
            let work = DispatchWorkItem { [weak self] in
                self?.retryRegistration();
            };
            registrationTimer = work;
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work);
        }
    }

    private func cancelRegistrationRetry() {
        bundlePublishLock.withLock {
            registrationTimer?.cancel();
            registrationTimer = nil;
        }
    }

    private func retryRegistration() {
        guard isPepAvailable, !isReady, context != nil else {
            return;
        }
        let busy: Bool = bundlePublishLock.withLock {
            registrationAttempt += 1;
            return bundlePublish.running;
        };
        guard !busy else {
            // Not another publish on top of the one in flight.
            scheduleRegistrationRetry();
            return;
        }
        logger.info("Registering our device again");
        registerDevice();
    }

    /// Publishes our bundle if it's missing or out of date, then calls
    /// `completionHandler`. If publishing fails the handlers keep waiting for
    /// the next publish that works, so that no device id goes out without a
    /// bundle. Calls made meanwhile wait for the one running, which then runs
    /// once more for them. `registration` adds the step that lists our device,
    /// once however often it is asked for.
    func publishDeviceBundleIfNeeded(completionHandler: (()->Void)?, registration: Bool = false, afterPreKeyUse: Bool = false) {
        // A prekey used here is gone from the store and from the list of ones
        // to republish for, so an extension that left it published would
        // leave others starting sessions with a key nobody holds.
        guard publishesKeys || afterPreKeyUse else {
            completionHandler?();
            return;
        }
        let start: Bool = bundlePublishLock.withLock {
            if let completionHandler {
                bundlePublish.waiting.append(completionHandler);
            }
            if registration && !registrationQueued {
                registrationQueued = true;
                bundlePublish.waiting.append({ [weak self] in
                    guard let self else {
                        return;
                    }
                    self.publishDeviceIdIfNeeded();
                    if let context = self.context {
                        context.sessionObject.setProperty(OMEMOModule.XMLNS + ".bundle", value: true);
                    }
                });
            }
            if bundlePublish.running {
                bundlePublish.rerun = true;
                return false;
            }
            bundlePublish.running = true;
            return true;
        };
        if start {
            runBundlePublish();
        }
    }

    private func runBundlePublish() {
        fetchAndPublishBundle { succeeded in
            let next: [() -> Void]? = self.bundlePublishLock.withLock {
                if succeeded && self.bundlePublish.rerun {
                    self.bundlePublish.rerun = false;
                    return nil;
                }
                guard succeeded else {
                    self.bundlePublish.running = false;
                    self.bundlePublish.rerun = false;
                    return [];
                }
                let waiting = self.bundlePublish.waiting;
                self.bundlePublish = (false, false, []);
                self.registrationQueued = false;
                self.bundleConfirmed = true;
                return waiting;
            };
            if let next {
                next.forEach { $0() };
            } else {
                self.runBundlePublish();
            }
        }
    }

    private func fetchAndPublishBundle(done: @escaping (Bool) -> Void) {
        guard let pepJid = context?.userBareJid, let pubsubModule = context?.module(.pubsub) else {
            done(false);
            return;
        }
        
        pubsubModule.retrieveItems(from: pepJid, for: bundleNode(for: storage.identityKeyStore.localRegistrationId()), limit: .items(withIds: ["current"]), completionHandler: { result in
            switch result {
            case .success(let items):
                self.publishDeviceBundle(currentBundle: items.items.first?.payload, completionHandler: { done(true) }, failure: { done(false) });
            case .failure(let pubsubError):
                guard pubsubError.error == .item_not_found || pubsubError.error == .internal_server_error() else {
                    self.logger.error("Reading our bundle failed: \(pubsubError.error.errorCondition.rawValue, privacy: .public)");
                    done(false);
                    return;
                }
                self.publishDeviceBundle(currentBundle: nil, completionHandler: { done(true) }, failure: { done(false) });
            }
        });
    }
    
    /// Takes our own devices out of our published device list. This device
    /// is always kept in it. `completionHandler` runs once the new list is
    /// published, or has failed to be.
    public func removeDevices(withIds requested: [Int32], completionHandler: ((Result<Void, PubSubError>) -> Void)? = nil) {
        // Removed on purpose: if it comes back it is in use, and stays.
        let now = Date();
        devicesQueue.sync {
            requested.forEach { self.ownDevicesDropped[$0] = now };
        }
        removeDevices(withIds: requested, deleteBundles: true, completionHandler: completionHandler);
    }

    /// `deleteBundles` is off when we drop a device for having none: there is
    /// nothing to delete, and a device that is alive would be racing us to
    /// publish the one it makes.
    fileprivate func removeDevices(withIds requested: [Int32], deleteBundles: Bool, completionHandler: ((Result<Void, PubSubError>) -> Void)? = nil) {
        guard let pepJid = context?.userBareJid, let pubsubModule = context?.module(.pubsub) else {
            completionHandler?(.failure(.undefined_condition));
            return;
        }
        // Not this device: that would delete its own bundle.
        let localId = storage.identityKeyStore.localRegistrationId();
        let withIds = requested.filter { UInt32(bitPattern: $0) != localId };

        let ids = withIds.map { (deviceId) -> UInt32 in
            return UInt32(bitPattern: deviceId);
        }
        
        withIds.forEach { deviceId in
            _ = self.storage.identityKeyStore.setStatus(active: false, forIdentity: SignalAddress(name: pepJid.stringValue, deviceId: deviceId));
            
            if deleteBundles {
                pubsubModule.deleteNode(from: pepJid, node: bundleNode(for: UInt32(bitPattern: deviceId)), completionHandler: nil);
            }
        }
        
        self.publishDeviceIdIfNeeded(removeDevicesWithIds: ids, removalReason: deleteBundles ? .removalRequested : .droppedWithoutBundles, completionHandler: completionHandler);
    }
    
    private var postponedSessions: [BareJID?:[SignalAddress]] = [:];
    private var postponedHealing: [BareJID?:[SignalAddress]] = [:];

    /// When each device's session was last repaired, and which repairs are
    /// still under way. One broken session makes every message sent in it
    /// fail, and a server that stored a burst of them while we were away
    /// delivers them live, before any sync starts to hold repairs back.
    /// Without this each one fetched the bundle and sent the peer a message
    /// that used up one of its prekeys. It has its own lock, not
    /// `devicesQueue`: every decrypted message reports in, and none should
    /// wait for that queue.
    private final class HealingClaims: @unchecked Sendable {
        private let lock = NSLock();
        private var healedAt: [SignalAddress: Date] = [:];
        private var inFlight: Set<SignalAddress> = [];

        /// Whether to repair `address` now, noting that it is being.
        func claim(_ address: SignalAddress) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if inFlight.contains(address) { return false }
            if let last = healedAt[address], Date().timeIntervalSince(last) < OMEMOModule.healingInterval { return false }
            healedAt[address] = Date();
            inFlight.insert(address);
            return true;
        }

        /// A repair ended. One that came to nothing gives up its claim too.
        func finish(_ address: SignalAddress, succeeded: Bool) {
            lock.lock(); defer { lock.unlock() }
            inFlight.remove(address);
            if !succeeded { healedAt.removeValue(forKey: address) }
        }

        /// A message decrypted, so a later failure deserves a repair. Not
        /// while one is under way: that session is the one just being built,
        /// and a second repair would replace it.
        func sessionWorks(_ address: SignalAddress) {
            lock.lock(); defer { lock.unlock() }
            guard !healedAt.isEmpty, !inFlight.contains(address) else { return }
            healedAt.removeValue(forKey: address);
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            healedAt.removeAll();
            inFlight.removeAll();
        }

    }
    private let healing = HealingClaims();
    private static let healingInterval: TimeInterval = 600;

    /// What a successful decrypt from `address` does, for tests: a real one
    /// needs a whole second client.
    public func sessionWorksForTesting(_ address: SignalAddress) {
        healing.sessionWorks(address);
    }

    /// Whether to repair `address` now, noting that it is being.
    private func claimHealing(_ address: SignalAddress) -> Bool {
        return healing.claim(address);
    }
    
    /// Starts a new session with `address` and tells it so. A repair that
    /// comes to nothing (no bundle, a session that wouldn't start, a message
    /// that couldn't be made) gives up its claim, or the device couldn't be
    /// repaired again for `healingInterval`.
    private func repairSession(forAddress address: SignalAddress) {
        report(.sessionRepairStarted(deviceId: address.deviceId, ownAccount: address.name == context?.userBareJid.stringValue));
        buildSession(forAddress: address, completionHandler: {
            let built = self.devicesQueue.sync { self.devicesFetchError[BareJID(address.name)]?[address.deviceId] == nil };
            let succeeded = built && self.completeSession(forAddress: address);
            self.healing.finish(address, succeeded: succeeded);
        });
    }

    private func postponeSession(for jid: BareJID?, address: SignalAddress) -> Bool {
        return devicesQueue.sync {
            if mamSyncsInProgress.contains(jid) {
                if var tmp = postponedSessions[jid] {
                    tmp.append(address);
                    postponedSessions[jid] = tmp;
                    return true;
                }
            }
            if mamSyncsInProgress.contains(nil) {
                if var tmp = postponedSessions[nil] {
                    tmp.append(address);
                    postponedSessions[nil] = tmp;
                    return true;
                }
            }
            return false;
        }
    }
    
    private func postponeHealing(for jid: BareJID?, address: SignalAddress) -> Bool {
        return devicesQueue.sync {
            if mamSyncsInProgress.contains(jid) {
                if var tmp = postponedHealing[jid] {
                    // One repair per device is enough, however many of its
                    // messages failed.
                    if !tmp.contains(address) { tmp.append(address) }
                    postponedHealing[jid] = tmp;
                    return true;
                }
            }
            if mamSyncsInProgress.contains(nil) {
                if var tmp = postponedHealing[nil] {
                    if !tmp.contains(address) { tmp.append(address) }
                    postponedHealing[nil] = tmp;
                    return true;
                }
            }
            return false;
        }
    }
    
    private func processPostponed(for jid: BareJID?) {
        if let sessions = postponedSessions.removeValue(forKey: jid) {
            if !sessions.isEmpty {
                if self.storage.preKeyStore.flushDeletedPreKeys() {
                    self.publishDeviceBundleIfNeeded(completionHandler: nil, afterPreKeyUse: true);
                }
            }
            
            for address in sessions {
                self.completeSession(forAddress: address);
            }
        }
        if let healings = postponedHealing.removeValue(forKey: jid) {
            for healing in healings where claimHealing(healing) {
                self.repairSession(forAddress: healing);
            }
        }
    }
    
    /// Asked whenever the bundle is checked: whether the signed prekey in use
    /// is due for replacing. The schedule, and what becomes of the old key,
    /// are the app's; the new key gets the next id, and the old one stays in
    /// the store until the app deletes it.
    public var signedPreKeyRotationDue: (() -> Bool)? = nil;

    fileprivate func signedPreKey(regenerate: Bool = false) -> SignalSignedPreKey? {
        let signedPreKeyId = storage.signedPreKeyStore.countSignedPreKeys();
        var signedPreKey: SignalSignedPreKey? = nil;
        if (!regenerate) && (signedPreKeyId != 0) && !(signedPreKeyRotationDue?() ?? false) {
            if let data = signalContext.storage.signedPreKeyStore.loadSignedPreKey(withId: UInt32(signedPreKeyId)) {
                signedPreKey = SignalSignedPreKey(fromSerializedData: data);
            }
        }
        
        if signedPreKey == nil {
            let identityKeyPair = storage.identityKeyStore.keyPair()!;
            print("regenerating signed pre key!");
            signedPreKey = signalContext.generateSignedPreKey(withIdentity: identityKeyPair, signedPreKeyId: UInt32(signedPreKeyId + 1))
            guard signedPreKey != nil else {
                return nil;
            }
            guard signalContext.storage.signedPreKeyStore.storeSignedPreKey(signedPreKey!.serializedData!, withId: signedPreKey!.preKeyId) else {
                return nil;
            }
        }
        return signedPreKey;
    }
    
//    fileprivate func publishDeviceBundleNoKeys(regenerate: Bool = false, completionHandler: @escaping ()->Void) {
//        if let signedPreKey = signedPreKey(regenerate: regenerate) {
//            let preKeys = signalContext.generatePreKeys(withStartingPreKeyId: 0, count: 20);
//            preKeys.forEach { (preKey) in
//                _ = self.storage.preKeyStore.storePreKey(preKey.serializedData!, withId: preKey.preKeyId);
//            }
//            publishDeviceBundle(signedPreKey: signedPreKey, preKeys: preKeys, completionHandler: completionHandler);
//        }
//    }

    fileprivate func publishDeviceBundle(currentBundle: Element?, completionHandler: (()->Void)?, failure: (()->Void)? = nil) {
        guard let identityPublicKey = storage.identityKeyStore.keyPair()?.publicKey?.base64EncodedString() else {
            completionHandler?();
            return;
        }

        let signedPreKeysBefore = storage.signedPreKeyStore.countSignedPreKeys();
        var flush: Bool = currentBundle == nil;
        if !flush {
            flush = identityPublicKey != currentBundle?.findChild(name: "identityKey")?.value;
        }
        
        if let signedPreKey = self.signedPreKey(regenerate: flush), let signedPreKeyBase64 = signedPreKey.publicKeyData?.base64EncodedString() {
            let signatureBase64 = signedPreKey.signature.base64EncodedString();
            var changed = flush || signedPreKeyBase64 != currentBundle?.findChild(name: "signedPreKeyPublic")?.value || signatureBase64 != currentBundle?.findChild(name: "signedPreKeySignature")?.value;
            
            let currentKeys = currentBundle?.findChild(name: "prekeys")?.mapChildren(transform: { (preKeyEl) -> UInt32? in
                guard let preKeyId = preKeyEl.getAttribute("preKeyId") else {
                    return nil;
                }
                return UInt32(preKeyId);
            });
            
            var validKeys = currentKeys?.map({ (preKeyId) -> SignalPreKey? in
                // A used one stays readable until the flush, for others who picked it too, but is
                // never offered again.
                guard !self.storage.preKeyStore.isPreKeyDeleted(withId: preKeyId), let key = self.storage.preKeyStore.loadPreKey(withId: preKeyId) else {
                    return nil;
                }
                return SignalPreKey(fromSerializedData: key);
            }).filter({ (preKey) -> Bool in
                return preKey != nil;
            }).map({ preKey -> SignalPreKey in
                return preKey!;
            }) ?? [];
            let needKeys = 100 - validKeys.count;
            if needKeys > 0 {
                changed = true;
                let currentPreKeyId = self.storage.preKeyStore.currentPreKeyId();
                var newKeys = self.signalContext.generatePreKeys(withStartingPreKeyId: currentPreKeyId + 1, count: UInt32(needKeys));
                newKeys = newKeys.filter { (key) in
                    self.storage.preKeyStore.storePreKey(key.serializedData!, withId: key.preKeyId);
                };
                validKeys = validKeys + newKeys;
            }

            if changed {
                // something has changed, we need to publish new bundle!
                publishDeviceBundle(signedPreKey: signedPreKey, preKeys: validKeys, rotated: Int(signedPreKey.preKeyId) != signedPreKeysBefore, flushed: flush, completionHandler: completionHandler, failure: failure);
            } else {
                completionHandler?();
            }
        } else {
            logger.error("No signed prekey to publish");
            failure?();
        }
    }

    func publishDeviceBundle(signedPreKey: SignalSignedPreKey, preKeys: [SignalPreKey], rotated: Bool = false, flushed: Bool = false, completionHandler: (()->Void)?, failure: (()->Void)? = nil) {
        let identityKeyPair = storage.identityKeyStore.keyPair()!;
        
        let bundleEl = Element(name: "bundle", xmlns: OMEMOModule.XMLNS);
        bundleEl.addChild(Element(name: "signedPreKeyPublic", cdata: signedPreKey.publicKeyData!.base64EncodedString(), attributes: ["signedPreKeyId": String(signedPreKey.preKeyId)]));
        bundleEl.addChild(Element(name: "signedPreKeySignature", cdata: signedPreKey.signature.base64EncodedString()));
        bundleEl.addChild(Element(name: "identityKey", cdata: identityKeyPair.publicKey!.base64EncodedString()));
        let preKeysElems = preKeys.map({ (preKey) -> Element in
            return Element(name: "preKeyPublic", cdata: preKey.serializedPublicKey!.base64EncodedString(), attributes: ["preKeyId": String(preKey.preKeyId)]);
        });
        bundleEl.addChild(Element(name: "prekeys", children: preKeysElems));
        
        let publishOptions = OMEMOModule.openPublishOptions();
        
        guard let pubsubModule = context?.module(.pubsub) else {
            failure?();
            return;
        }
        let node = bundleNode(for: storage.identityKeyStore.localRegistrationId());
        pubsubModule.publishItem(at: nil, to: node, itemId: "current", payload: bundleEl, publishOptions: publishOptions, completionHandler: { result in
            switch result {
            case .success(_):
                self.logger.info("Published our bundle");
                self.report(.bundlePublished(signedPreKeyId: signedPreKey.preKeyId, rotated: rotated, flushed: flushed, preKeys: preKeys.count));
                self.ensureOpen(node: node, at: nil);
                completionHandler?();
            case .failure(let pubsubError):
                guard case .conflict = pubsubError.error else {
                    self.logger.error("Publishing our bundle failed: \(pubsubError.error.errorCondition.rawValue, privacy: .public)");
                    self.report(.bundlePublishFailed(condition: pubsubError.error.errorCondition.rawValue, type: pubsubError.errorType));
                    failure?();
                    return;
                }
                // The node exists with other settings; see publishDeviceList.
                self.reconfigureOpen(node: node, at: nil, failed: failure) {
                    pubsubModule.publishItem(at: nil, to: node, itemId: "current", payload: bundleEl, publishOptions: publishOptions, completionHandler: { result in
                        switch result {
                        case .success(_):
                            self.report(.bundlePublished(signedPreKeyId: signedPreKey.preKeyId, rotated: rotated, flushed: flushed, preKeys: preKeys.count));
                            completionHandler?();
                        case .failure(let error):
                            self.logger.error("Publishing our bundle failed again: \(error.error.errorCondition.rawValue, privacy: .public)");
                            self.report(.bundlePublishFailed(condition: error.error.errorCondition.rawValue, type: error.errorType));
                            failure?();
                        }
                    });
                }
            }
        });
    }
    
    /// Sends the device a message to finish its side of the session. Whether one could be made.
    @discardableResult
    private func completeSession(forAddress address: SignalAddress) -> Bool {
        let message = Message()
        message.type = .chat;
        message.to = JID(address.name);
        let result = self._encode(message: message, for: [address], forSelf: false);
        switch result {
        case .successMessage(let message, _):
            message.hints = [.store];
            self.write(message);
            return true;
        case .failure(let error):
            self.logger.error("Failed to complete a session for \(address.name, privacy: .private(mask: .hash)):\(address.deviceId, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private)");
            return false;
        }
    }
    
    /// Fetches the device's bundle and starts a session from it. Always
    /// calls `completionHandler`, whether or not a session came of it.
    open func buildSession(forAddress address: SignalAddress, completionHandler: (()->Void)? = nil) {
        let pepJid = BareJID(address.name);
        guard let pubsubModule: PubSubModule = context?.module(.pubsub) else {
            completionHandler?();
            return;
        }
        pubsubModule.retrieveItems(from: pepJid, for: bundleNode(for: UInt32(bitPattern: address.deviceId)), limit: .lastItems(1), completionHandler: { result in
            defer { completionHandler?() }
            switch result {
            case .success(let items):
                guard let bundle = OMEMOBundle(from: items.items.first?.payload), !bundle.preKeys.isEmpty else {
                    self.logger.warning("Unusable bundle for \(address.name, privacy: .private(mask: .hash)):\(address.deviceId, privacy: .private(mask: .hash))");
                    self.markDeviceAsFailed(for: pepJid, andDeviceId: address.deviceId);
                    return;
                }
                
                let preKey = bundle.preKeys[Int.random(in: 0..<bundle.preKeys.count)];
                guard let preKeyBundle = SignalPreKeyBundle(registrationId: 0, deviceId: address.deviceId, preKey: preKey, bundle: bundle),
                      let builder = SignalSessionBuilder(withAddress: address, andContext: self.signalContext),
                      builder.processPreKeyBundle(bundle: preKeyBundle) else {
                    self.logger.warning("Couldn't start a session with \(address.name, privacy: .private(mask: .hash)):\(address.deviceId, privacy: .private(mask: .hash))");
                    self.markDeviceAsFailed(for: pepJid, andDeviceId: address.deviceId);
                    return;
                }
                self.devicesQueue.sync {
                    _ = self.devicesFetchError[pepJid]?.removeValue(forKey: address.deviceId);
                    if self.devicesFetchError[pepJid]?.isEmpty ?? true { self.bundleErrors[pepJid] = nil }
                }
            case .failure(let pubsubError):
                self.logger.warning("No bundle for \(address.name, privacy: .private(mask: .hash)):\(address.deviceId, privacy: .private(mask: .hash)): \(pubsubError.error.errorCondition.rawValue, privacy: .public)");
                if let account = self.context?.userBareJid, pubsubError.error == .item_not_found, account == pepJid {
                    // One of our devices without a bundle: dropped from our
                    // list once the round of sessions is through, unless it
                    // was dropped before. It is also tried again later, as
                    // it may publish its bundle.
                    self.devicesQueue.sync {
                        self.ownBrokenDevices.append(address.deviceId);
                    }
                }
                self.devicesQueue.sync { self.bundleErrors[pepJid] = pubsubError }
                self.markDeviceAsFailed(for: pepJid, andDeviceId: address.deviceId);
            }
        });
    }
    
    /// What `jid`'s own server says of the identity key of one of their devices.
    public enum IdentityKeyRead {
        case published(Data)
        case unavailable(PubSubError)
        /// A bundle with no identity key we can read.
        case unusable
    }

    /// `jid`'s device list as their own server has it now, whole: before any
    /// cap, as the cap is about what we send to, not about which devices are
    /// theirs. Empty when they have none. A group's messages name their
    /// sender only on the room's word; this is where the member's own account
    /// says which devices are theirs.
    public func readDeviceList(of jid: BareJID, completionHandler: @escaping (Result<[Int32], PubSubError>) -> Void) {
        guard let pubsubModule: PubSubModule = context?.module(.pubsub) else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        pubsubModule.retrieveItems(from: jid, for: OMEMOModule.DEVICES_LIST_NODE, limit: .lastItems(1), completionHandler: { result in
            switch result {
            case .success(let items):
                let listEl = items.items.first?.payload;
                let listed = listEl.flatMap { $0.name == "list" && $0.xmlns == OMEMOModule.XMLNS ? $0 : nil }?
                    .mapChildren(transform: { $0.getAttribute("id") }).compactMap({ Int32(omemoId: $0) }) ?? [];
                completionHandler(.success(listed));
            case .failure(let error) where error.error == .item_not_found:
                completionHandler(.success([]));
            case .failure(let error):
                completionHandler(.failure(error));
            }
        });
    }

    /// The identity key `jid`'s bundle for `deviceId` publishes. It builds no
    /// session, so it uses none of their one-time prekeys and leaves the
    /// session a prekey message sets up alone.
    public func readIdentityKey(of deviceId: Int32, of jid: BareJID, completionHandler: @escaping (IdentityKeyRead) -> Void) {
        guard let pubsubModule: PubSubModule = context?.module(.pubsub) else {
            completionHandler(.unavailable(.remote_server_timeout));
            return;
        }
        pubsubModule.retrieveItems(from: jid, for: bundleNode(for: UInt32(bitPattern: deviceId)), limit: .lastItems(1), completionHandler: { result in
            switch result {
            case .success(let items):
                guard let key = OMEMOBundle.identityKey(in: items.items.first?.payload) else {
                    completionHandler(.unusable);
                    return;
                }
                completionHandler(.published(key));
            case .failure(let error):
                completionHandler(.unavailable(error));
            }
        });
    }

    fileprivate func markDeviceAsFailed(for jid: BareJID, andDeviceId deviceId: Int32) {
        devicesQueue.sync {
            self.devicesFetchError[jid, default: [:]][deviceId] = Date();
        }
    }
    
    func bundleNode(for deviceId: UInt32) -> String {
        return "eu.siacs.conversations.axolotl.bundles:\(deviceId)";
    }
    
    open class OMEMOBundle {

        /// The identity key a bundle publishes, as libsignal serializes it.
        /// Read on its own, as a bundle whose prekeys have all been used up
        /// still says whose device it is.
        static func identityKey(in el: Element?) -> Data? {
            guard let el, el.name == "bundle" && el.xmlns == OMEMOModule.XMLNS,
                  let value = el.findChild(name: "identityKey")?.value,
                  let key = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }
            // Some clients publish the bare 32-byte Curve25519 key, without
            // the type byte libsignal puts in front.
            switch key.count {
            case 33 where key.first == 0x05: return key;
            case 32: return Data([0x05]) + key;
            default: return nil;
            }
        }
        
        let preKeys: [OMEMOPreKey];
        
        let signedPreKeyId: UInt32;
        let signedPreKeyPublic: Data;
        let identityKey: Data;
        let signature: Data;
        
        init?(from: Element?) {
            guard let el = from, el.name == "bundle" && el.xmlns == OMEMOModule.XMLNS else {
                return nil;
            }
            
            guard let preKeys = el.findChild(name: "prekeys")?.mapChildren(transform: { (el) -> OMEMOPreKey? in
                return OMEMOPreKey(from: el);
            }), !preKeys.isEmpty else {
                return nil;
            }
            
            guard let signedKeyPublic = el.findChild(name: "signedPreKeyPublic"), let signedPreKeyIdStr = signedKeyPublic.getAttribute("signedPreKeyId"), let signedPreKeyId = UInt32(signedPreKeyIdStr), let signedKeyPublicValue = signedKeyPublic.value, let signedKeyPublicData = Data(base64Encoded: signedKeyPublicValue, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }

            guard let identityKeyValue = el.findChild(name: "identityKey")?.value, let identityKeyData = Data(base64Encoded: identityKeyValue, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }

            guard let signatureValue = el.findChild(name: "signedPreKeySignature")?.value, let signatureData = Data(base64Encoded: signatureValue, options: [.ignoreUnknownCharacters]) else {
                return nil;
            }
            
            self.signedPreKeyId = signedPreKeyId;
            self.signedPreKeyPublic = signedKeyPublicData;
            self.signature = signatureData;
            self.identityKey = identityKeyData;
            self.preKeys = preKeys;
        }
        
    }
    
    open class OMEMOPreKey {
        
        public let preKeyId: UInt32;
        public let data: Data;
        
        public convenience init?(from: Element) {
            guard from.name == "preKeyPublic", let value = from.value, let preKeyIdStr = from.getAttribute("preKeyId") else {
                return nil;
            }
            guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]), let preKeyId = UInt32(preKeyIdStr) else {
                return nil;
            }
            
            self.init(data: data, preKeyId: preKeyId);
        }

        public init(data: Data, preKeyId: UInt32) {
            self.data = data;
            self.preKeyId = preKeyId;
        }

    }
    
    public struct AvailabilityChanged {
        
        public let jid: BareJID;
        public let activeDevices: [Int32];
        /// Whether the list was read from the server, rather than made up
        /// after a failed read: only a list that was read says what exists.
        public let readFromServer: Bool;
        
    }
    
    open class AvailabilityChangedEvent: Event {
        
        public static let TYPE = AvailabilityChangedEvent();
        
        public let type = "OMEMOAvailabilityChangedEvent";
        
        public let sessionObject: SessionObject!;
        public var account: BareJID {
            return sessionObject.context.userBareJid;
        }
        public let jid: BareJID!;
        
        init() {
            self.sessionObject = nil;
            self.jid = nil;
        }
        
        public init(sessionObject: SessionObject, jid: BareJID) {
            self.sessionObject = sessionObject;
            self.jid = jid;
        }
        
    }
}

public protocol AES_GCM_Engine {
    
    func encrypt(iv: Data, key: Data, message: Data, output: UnsafeMutablePointer<Data>?, tag: UnsafeMutablePointer<Data>?) -> Bool;
    
    func decrypt(iv: Data, key: Data, encoded: Data, auth tag: Data?, output: UnsafeMutablePointer<Data>?) -> Bool;
    
}

public enum EncryptionResult<Success, Failure> {
    case successMessage(_ success: Success, fingerprint: String?)
    case failure(_ error: Failure)
}

public enum DecryptionResult<Success, Failure> {
    case successMessage(_ success: Success, fingerprint: String?)
    case successTransportKey(_ key: Data, iv: Data)
    case failure(_ error: Failure)
}

/// What the module did with our own keys, as facts without any address, for
/// the app's diagnostics log. A device id is the only identifier, and the
/// app hashes it.
public enum OMEMOEvent: Sendable {
    public enum ListSource: Sendable, CaseIterable {
        case fetch, notification
    }

    /// Why our device list was published. `registration` is the first
    /// publish of a session, `readdedSelf` one made because the list lost
    /// this device after it was ready.
    public enum ListPublishReason: Sendable, CaseIterable {
        case registration, readdedSelf, droppedWithoutBundles, removalRequested
    }

    case ownListRead(count: Int, includesThisDevice: Bool, source: ListSource)
    case ownListPublished(count: Int, includesThisDevice: Bool, reason: ListPublishReason)
    /// `condition` is an RFC 6120 condition's name, `type` the error's own.
    case ownListPublishFailed(condition: String, type: String?)
    case ownDevicesDropped(count: Int)
    case ownDropDeferred(count: Int)
    case bundlePublished(signedPreKeyId: UInt32, rotated: Bool, flushed: Bool, preKeys: Int)
    case bundlePublishFailed(condition: String, type: String?)
    case sessionRepairStarted(deviceId: Int32, ownAccount: Bool)
    /// How a connection's registration ended: `resumed` if it began on a
    /// resumed stream, `ready` false if the stream went away first, and
    /// `seconds` from its start to the end, nil if it never started.
    case registrationEnded(resumed: Bool, pepAvailable: Bool, ready: Bool, seconds: TimeInterval?)
}
