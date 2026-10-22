//
// StreamFeaturesModule.swift
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

extension XmppModuleIdentifier {
    public static var streamFeatures: XmppModuleIdentifier<StreamFeaturesModule> {
        return StreamFeaturesModule.IDENTIFIER;
    }
}

/**
 Module provides support for XMPP [stream features]
 
 [stream features]: http://xmpp.org/rfcs/rfc6120.html#streams-negotiation-features
 */
open class StreamFeaturesModule: XmppModuleBaseSessionStateAware, XmppModule, Resetable {

    public static let ID = "stream:features";
    public static let STREAM_FEATURES_KEY = "stream:features";
    public static let IDENTIFIER = XmppModuleIdentifier<StreamFeaturesModule>();
    
    public let criteria = Criteria.name("features", xmlns: "http://etherx.jabber.org/streams");
    public let features = [String]();
    
    @Published
    open private(set) var streamFeatures: StreamFeatures = .none;
    
    /**
     Retrieves stream features which were recevied from server
     - parameter sessionObject: instance of `SessionObject` to retrieve cached stream features element
     - returns: element with stream features
     */
    @available(*, deprecated, message: "Use stream features property on StreamFeaturesModule")
    public static func getStreamFeatures(_ sessionObject:SessionObject) -> Element? {
        return sessionObject.context.module(.streamFeatures).streamFeatures.element;
    }
    
    
    public override init() {
        
    }
    
    /**
     Processes received stream features and fires event
     - parameter stanza: stanza to process
     */
    open func process(stanza:Stanza) throws {
        setStreamFeatures(stanza.element);
    }

    open func fireEvent(streamFeatures element: Element) {
        if let context = context {
            fire(StreamFeaturesReceivedEvent(context: context, element: element));
        }
    }
    
    /// What a server accepts when it says nothing, as Prosody's `c2s_stanza_size_limit` does.
    public static let defaultMaxStanzaBytes = 262144;

    private let limitLock = NSLock();
    private var _authenticatedMaxBytes: Int?;
    private var _stanzaRefused: ((String, Int, Int) -> Void)?;

    /// The `max-bytes` of XEP-0478 from features received after authentication. Before it a
    /// server advertises the limit for unauthenticated streams, which is far lower (Prosody: 10000)
    /// and would wrongly refuse a key bundle. A resumed SASL2 stream gets no new features, so the
    /// default applies there.
    var authenticatedMaxBytes: Int? {
        get { limitLock.withLock { _authenticatedMaxBytes } }
        set { limitLock.withLock { _authenticatedMaxBytes = newValue } }
    }

    /// The most bytes the server takes in one stanza.
    public var maxStanzaBytes: Int {
        return authenticatedMaxBytes ?? StreamFeaturesModule.defaultMaxStanzaBytes;
    }

    /// Called with the element's name, its size and the limit when a stanza is refused for being over it.
    public var stanzaRefused: ((String, Int, Int) -> Void)? {
        get { limitLock.withLock { _stanzaRefused } }
        set { limitLock.withLock { _stanzaRefused = newValue } }
    }

    /// Whether the server takes `stanza`. A server closes the stream on one past its limit, which
    /// takes every stanza queued behind it too.
    public func fits(_ stanza: Stanza) -> Bool {
        return excess(of: stanza) == nil;
    }

    /// Whether `stanza` is to be refused rather than written, reported through `stanzaRefused` if so.
    func refuses(_ stanza: Stanza) -> Bool {
        guard let (size, limit) = excess(of: stanza) else {
            return false;
        }
        stanzaRefused?(stanza.element.name, size, limit);
        return true;
    }

    /// The size of `stanza` and the limit it is over, or nil if it fits.
    private func excess(of stanza: Stanza) -> (size: Int, limit: Int)? {
        let size = stanza.element.stringValue.utf8.count;
        let limit = maxStanzaBytes;
        return size > limit ? (size, limit) : nil;
    }

    func setStreamFeatures(_ element: Element) {
        if let auth = context?.moduleOrNil(.auth), case .authorized = auth.state {
            let limit = element.findChild(name: "limits", xmlns: "urn:xmpp:stream-limits:0")?.findChild(name: "max-bytes")?.value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) };
            authenticatedMaxBytes = limit.flatMap { $0 > 0 ? $0 : nil };
        }
        self.streamFeatures = StreamFeatures(element: element);
        fireEvent(streamFeatures: element);
    }
    
    public func reset(scopes: Set<ResetableScope>) {
        if scopes.contains(.stream) {
            streamFeatures = .none;
            authenticatedMaxBytes = nil;
        }
    }
}

/// Event fired when stream features are received
@available(*, deprecated, message: "Use StreamFeaturesModule.$streamFeatures publisher")
open class StreamFeaturesReceivedEvent: AbstractEvent {

    /// Identifier of event which should be used during registration of `EventHandler`
    public static let TYPE = StreamFeaturesReceivedEvent();

    /// Element with stream features
    public let featuresElement:Element!;

    init() {
        featuresElement = nil;
        super.init(type: "StreamFeaturesReceivedEvent")
    }

    public init(context: Context, element:Element) {
        self.featuresElement = element;
        super.init(type: "StreamFeaturesReceivedEvent", context: context);
    }

}

public struct StreamFeatures {
    
    public static let none = StreamFeatures(element: nil);
    
    public let element: Element?;
 
    public var isNone: Bool {
        return element == nil;
    }
    
    private init(element: Element?) {
        self.element = element;
    }
    
    public init(element: Element) {
        self.element = element;
    }
    
    public func contains(_ feature: StreamFeature) -> Bool {
        guard let elem = self.element else {
            return false;
        }
        return feature.check(in: elem);
    }
    
    public struct StreamFeature {
        public struct Node {
            public let name: String;
            public let xmlns: String?;
            public let value: String?;
        }
        
        public let path: [Node];
        
        public init(_ path: Node...) {
            self.path = path;
        }
                
        public init(name: String, xmlns: String) {
            self.init(.init(name: name, xmlns: xmlns, value: nil));
        }

        public func check(in element: Element) -> Bool {
            var elem = element;
            for node in path {
                guard let subelem = elem.findChild(name: node.name, xmlns: node.xmlns) else {
                    return false;
                }
                if node.value != nil {
                    guard subelem.value == node.value else {
                        return false;
                    }
                }
                elem = subelem;
            }
            return true;
        }
        
    }
    
}
