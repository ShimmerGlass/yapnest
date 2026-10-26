//
// CapabilitiesModule.swift
//
// TigaseSwift
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//

import Foundation
import TigaseLogging

extension XmppModuleIdentifier {
    public static var caps: XmppModuleIdentifier<CapabilitiesModule> {
        return CapabilitiesModule.IDENTIFIER;
    }
}

/**
 Module implements support for [XEP-0115: Entity Capabilities].
 
 Requires `DiscoveryModule` to work properly.
 
 [XEP-0115: Entity Capabilities]:http://xmpp.org/extensions/xep-0115.html
 */
open class CapabilitiesModule: XmppModuleBase, XmppModule, EventHandler {
        
    /// ID of module for lookup in `XmppModulesManager`
    public static let ID = "caps";
    public static let IDENTIFIER = XmppModuleIdentifier<CapabilitiesModule>();
    
    private let logger = Logger(subsystem: "TigaseSwift", category: "CapabilitiesModule");
    
    public let criteria = Criteria.empty();
    public var features: [String] {
        return ["http://jabber.org/protocol/caps"] + additionalFeatures.map({ $0.rawValue });
    }
    
    open override weak var context: Context? {
        willSet {
            if let context = context {
                context.eventBus.unregister(handler: self, for: PresenceModule.BeforePresenceSendEvent.TYPE, PresenceModule.ContactPresenceChanged.TYPE);
                discoModule = nil;
                presenceModule = nil;
            }
        }
        
        didSet {
            if let context = context {
                context.eventBus.register(handler: self, for: PresenceModule.BeforePresenceSendEvent.TYPE, PresenceModule.ContactPresenceChanged.TYPE);
                discoModule = context.modulesManager.module(.disco);
                presenceModule = context.modulesManager.module(.presence);
            }
        }
    }
    
    /// Keeps instance of `CapabilitiesCache` responsible for caching discovery results
    public let cache: CapabilitiesCache;
    /// The hash registered with the disco module, and whether it is out of
    /// date. It is kept when invalidated so that working out the next one can
    /// unregister it. Guarded by `verificationLock`: the settings thread
    /// invalidates while the XMPP queue sends presence.
    private var verificationString: String?;
    private var verificationStringStale = false;
    private let verificationLock = NSLock();

    /// Node used in CAPS advertisement
    open var nodeName = "http://tigase.org/TigaseSwift" + "X";
    
    private var presenceModule: PresenceModule!;
    private var discoModule: DiscoveryModule!;
    private let dispatcher = QueueDispatcher(label: "capsInProgressSynchronizer");
    private var inProgress: [String] = [];
    /// node#ver whose answer didn't hash to it, not asked about again.
    private var unverifiable: Set<String> = [];
    
    public let additionalFeatures: [AdditionalFeatures];
    
    public init(cache: CapabilitiesCache = DefaultCapabilitiesCache(), additionalFeatures: [AdditionalFeatures] = []) {
        self.cache = cache;
        self.additionalFeatures = additionalFeatures;
    }
    
    /// Method do noting
    open func process(stanza: Stanza) throws {
        throw XMPPError.bad_request(nil);
    }
        
    open func handle(event: Event) {
        switch event {
        case let e as PresenceModule.BeforePresenceSendEvent:
            onBeforePresenceSend(event: e);
        case let e as PresenceModule.ContactPresenceChanged:
            onReceivedPresence(event: e);
        default:
            break;
        }
    }
    
    /**
     Method called before presence is sent by `PresenceModule.BeforePresenceSendEvent`
     This method is responsible for calculation of verification string if needed
     and injecting CAPS element to presence before it is send.
     
     - parameter event: event fired before `Presence` is send
     */
    func onBeforePresenceSend(event e: PresenceModule.BeforePresenceSendEvent) {
        let current: String? = verificationLock.withLock {
            return verificationStringStale ? calculateVerificationStringLocked() : (verificationString ?? calculateVerificationStringLocked());
        };
        guard let ver = current else {
            return;
        }
        
        let c = Element(name: "c", xmlns: "http://jabber.org/protocol/caps");
        c.setAttribute("hash", value: "sha-1");
        c.setAttribute("node", value: nodeName);
        c.setAttribute("ver", value: ver);
    
        e.presence.addChild(c);
    }
 
    /**
     Method called by event when `Presence` is received. It looks for CAPS payload
     and if unknown verification string is found it executes discovery to add it
     to cache.
     
     - parameter event: event fired when `Presence` is received
     */
    func onReceivedPresence(event e: PresenceModule.ContactPresenceChanged) {
        let type = (e.presence.type ?? .available);
        guard e.presence != nil, let from = e.presence.from, type == .available else {
            return;
        }
        
        guard let nodeName = e.presence.capsNode, let c = e.presence.element.findChild(name: "c", xmlns: "http://jabber.org/protocol/caps") else {
            return;
        }
        let ver = c.getAttribute("ver"), hash = c.getAttribute("hash");
        
        dispatcher.async {
            guard !self.inProgress.contains(nodeName), !self.unverifiable.contains(nodeName) else {
                return;
            }
            self.cache.isCached(node: nodeName) { cached in
                guard !cached else {
                    return;
                }
                self.dispatcher.async {
                    guard !self.inProgress.contains(nodeName) else {
                        return;
                    }
                    self.inProgress.append(nodeName);
                    self.logger.debug("\(self.context) - caps disco#info send for: \(nodeName, privacy: .public) to: \(from, privacy: .auto(mask: .hash))");
                    self.discoModule.getInfo(for: from, node: nodeName, errorDecoder: XMPPError.from(stanza:), completionHandler: { (result: Result<Iq, XMPPError>) in
                        self.dispatcher.async {
                            if let idx = self.inProgress.firstIndex(of: nodeName) {
                                self.inProgress.remove(at: idx);
                                self.logger.debug("\(self.context) - caps disco#info received from: \(from, privacy: .private(mask: .hash)) result: \(result, privacy: .private(mask: .hash))");
                            }
                            guard case .success(let iq) = result, let query = iq.findChild(name: "query", xmlns: DiscoveryModule.INFO_XMLNS) else {
                                return;
                            }
                            // The answer is cached for everyone who shows this
                            // node#ver, so it's only taken if it hashes to it:
                            // anyone can claim a popular client's and answer for it.
                            guard let ver, CapabilitiesModule.verificationString(of: query, hash: hash) == ver else {
                                self.logger.debug("\(self.context) - caps answer doesn't match its hash: \(nodeName, privacy: .public)");
                                self.unverifiable.insert(nodeName);
                                return;
                            }
                            let identity = query.firstChild(where: { $0.name == "identity" }).flatMap { e -> DiscoveryModule.Identity? in
                                guard let category = e.getAttribute("category"), let type = e.getAttribute("type") else {
                                    return nil;
                                }
                                return DiscoveryModule.Identity(category: category, type: type, name: e.getAttribute("name"));
                            };
                            let features = query.getChildren(name: "feature").compactMap { $0.getAttribute("var") };
                            self.cache.store(node: nodeName, identity: identity, features: features);
                        }
                    });
                }
            }
        }
    }
    
    /// Marks the verification string stale, so the next presence works it out
    /// again from the features the modules offer then. Without this, a module
    /// that starts or stops offering a feature leaves the old hash in our
    /// presence. The old string is kept rather than forgotten: the next
    /// calculation compares against it, and unregisters the old node#ver
    /// callback only if the hash changed. Forgotten, that callback would stay
    /// registered for good.
    public func invalidateVerificationString() {
        verificationLock.withLock { verificationStringStale = true };
    }

    /**
     Method calculates verification string
     - returns: calculated verification string
     */
    func calculateVerificationString() -> String? {
        return verificationLock.withLock { calculateVerificationStringLocked() };
    }

    private func calculateVerificationStringLocked() -> String? {
        guard let context = self.context else {
            return nil;
        }
        let identity = "\(discoModule.identity.category)/\(discoModule.identity.type)//\(discoModule.identity.name ?? SoftwareVersionModule.DEFAULT_NAME_VAL)";
        
        let ver = generateVerificationString([identity], features: Array(context.modulesManager.availableFeatures));
        
        let oldVer: String? = verificationString;
        if oldVer != nil && ver != oldVer {
            discoModule.setNodeCallback(nodeName + "#" + oldVer!, entry: nil);
        }
        if ver != nil {
            let identity = discoModule.identity;
            discoModule.setNodeCallback(nodeName + "#" + ver!, entry: DiscoveryModule.NodeDetailsEntry(
                identity: { (context: Context, stanza: Stanza, node: String?) -> DiscoveryModule.Identity? in
                    return identity;
                },
                features: { (context: Context, stanza: Stanza, node: String?) -> [String]? in
                    return Array(context.modulesManager.availableFeatures);
                },
                items: { (context: Context, stanza: Stanza, node: String?) -> [DiscoveryModule.Item]? in
                    return nil;
            }));
        }
        
        self.verificationString = ver;
        self.verificationStringStale = false;
        
        return ver;
    }

    /**
     Method generates verification string from passed parameters.
     - parameter identities: XMPP client identities
     - parameter features: available feature for client
     - returns: verification string
     */
    /// XEP-0115 §5.1's verification string of a disco#info answer, with the
    /// hash the presence named; nil for one we can't check, or an answer the
    /// spec says not to cache (§5.4: a repeated identity or feature, or a
    /// form whose FORM_TYPE isn't one hidden value).
    static func verificationString(of query: Element, hash: String?) -> String? {
        let digest: Digest;
        switch hash?.lowercased() {
        case "sha-1": digest = .sha1;
        case "sha-256": digest = .sha256;
        default: return nil;
        }
        // i;octet: by the bytes of the UTF-8.
        func ordered(_ lhs: String, _ rhs: String) -> Bool {
            return Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8));
        }
        let identities = query.getChildren(name: "identity").map { e in
            [e.getAttribute("category") ?? "", e.getAttribute("type") ?? "", e.getAttribute("xml:lang") ?? "", e.getAttribute("name") ?? ""]
        };
        let features = query.getChildren(name: "feature").compactMap { $0.getAttribute("var") };
        guard Set(identities).count == identities.count, Set(features).count == features.count else {
            return nil;
        }
        var string = "";
        for identity in identities.sorted(by: { lhs, rhs in
            // Category, then type, then language; the name breaks no tie.
            let l = lhs[0..<3].joined(separator: "/"), r = rhs[0..<3].joined(separator: "/");
            return l == r ? ordered(lhs[3], rhs[3]) : ordered(l, r);
        }) {
            string += identity.joined(separator: "/") + "<";
        }
        for feature in features.sorted(by: ordered) {
            string += feature + "<";
        }
        var forms: [(type: String, fields: [(name: String, values: [String])])] = [];
        for form in query.getChildren(name: "x", xmlns: "jabber:x:data") {
            let fields = form.getChildren(name: "field");
            let typeFields = fields.filter { $0.getAttribute("var") == "FORM_TYPE" };
            // A form without a FORM_TYPE is left out of the hash.
            guard !typeFields.isEmpty else {
                continue;
            }
            let typeValues = typeFields.first!.getChildren(name: "value").compactMap { $0.value };
            guard typeFields.count == 1, typeFields.first!.getAttribute("type") == "hidden", typeValues.count == 1 else {
                return nil;
            }
            let others = fields.compactMap { field -> (name: String, values: [String])? in
                guard let name = field.getAttribute("var"), name != "FORM_TYPE" else {
                    return nil;
                }
                return (name, field.getChildren(name: "value").map { $0.value ?? "" }.sorted(by: ordered));
            };
            forms.append((typeValues[0], others.sorted(by: { ordered($0.name, $1.name) })));
        }
        guard Set(forms.map(\.type)).count == forms.count else {
            return nil;
        }
        for form in forms.sorted(by: { ordered($0.type, $1.type) }) {
            string += form.type + "<";
            for field in form.fields {
                string += field.name + "<";
                for value in field.values {
                    string += value + "<";
                }
            }
        }
        return digest.digest(toBase64: string.data(using: .utf8));
    }

    func generateVerificationString(_ identities: [String], features availableFeatures: [String]) -> String? {
        let features = availableFeatures.sorted();
        var string: String = "";
        
        for identity in identities {
            string += identity + "<";
        }
        
        for feature in features {
            string += feature + "<";
        }
        
        return Digest.sha1.digest(toBase64: string.data(using: String.Encoding.utf8));
    }
        
    public enum FeatureSupported {
        case all
        case some([JID])
        case none
    }
    
    public func isFeatureSupported(_ feature: String, by jid: BareJID) -> FeatureSupported {
        guard let context = self.context else {
            return .none;
        }
        
        let presences = presenceModule.store.presences(for: jid, context: context);
        guard !presences.isEmpty else {
            return .none;
        }
        
        let withSupport = presences.filter({ presence in
            if let capsNode = presence.capsNode, cache.isSupported(for: capsNode, feature: feature) {
                return true;
            }
            return false;
        }).compactMap({ $0.from });
        
        guard presences.count == withSupport.count else {
            return withSupport.isEmpty ? .none : .some(withSupport);
        }
        return .all;
    }
    
    public func isFeatureSupported(_ feature: String, by jid: JID) -> Bool {
        guard let context = self.context else {
            return false;
        }
        guard let capsNode = presenceModule.store.presence(for: jid, context: context)?.capsNode else {
            return false;
        }
        return cache.isSupported(for: capsNode, feature: feature);
    }
    
    public struct AdditionalFeatures: RawRepresentable {
        public let rawValue: String
        
        public init(rawValue: String) {
            self.rawValue = rawValue;
        }
    }
}

/**
 Protocol which is required to be implemented by class responsible for caching
 information about features and identities.
 */
public protocol CapabilitiesCache {
    /**
     Retreives array of features available for particular node from cache
     - parameter for: node for which we want to check supported features
     - returns: array of supported features or `nil` if there is not entry in
     cache for this node
     */
    func getFeatures(for node: String) -> [String]?;
    
    /**
     Retrieve identity of remote client which adverties this node
     - parameter for: node to look for identity
     - returns: XMPP client idenitity or `nil` if no available in cache
     */
    func getIdentity(for node: String) -> DiscoveryModule.Identity?;
    
    /**
     Retrieves array of nodes which supports feature
     - parameter withFeature: feature which should be supported
     - returns: array of nodes supporting this feature known in cache
     */
    func getNodes(withFeature feature: String) -> [String];
    
    /**
     Check if information for node are in cache
     - parameter node: node to check
     - returns: true if data is available in cache
     */
    func isCached(node: String, handler: @escaping (Bool)->Void);
    
    /**
     Check if feature is supported for node in cache.
     - parameter for: node to check
     - parameter feature: feature to check support
     - returns: true if feature is supported by this node
     */
    func isSupported(for node: String, feature: String) -> Bool;
    
    /**
     Store data in cache
     - parameter node: node for which we store data
     - parameter identitity: XMPP client identity
     - parameter features: array of feature supported by client
     */
    func store(node: String, identity: DiscoveryModule.Identity?, features: [String]);
    
}

extension Presence {
    open var capsNode: String? {
        get {
            guard let c = element.findChild(name: "c", xmlns: "http://jabber.org/protocol/caps") else {
                return nil;
            }
            guard let node = c.getAttribute("node"), let ver = c.getAttribute("ver") else {
                return nil;
            }
            return node + "#" + ver;
        }
    }
}
