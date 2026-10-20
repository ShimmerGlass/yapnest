//
// ExternalServiceDiscoveryModule.swift
//
// TigaseSwift
// Copyright (C) 2020 "Tigase, Inc." <office@tigase.com>
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
    public static var externalServiceDiscovery: XmppModuleIdentifier<ExternalServiceDiscoveryModule> {
        return ExternalServiceDiscoveryModule.IDENTIFIER;
    }
}

open class ExternalServiceDiscoveryModule: XmppModuleBase, XmppModule {

    public static let XMLNS = "urn:xmpp:extdisco:2";
    public static let ID = XMLNS;
    public static let IDENTIFIER = XmppModuleIdentifier<ExternalServiceDiscoveryModule>();
    
    public let criteria: Criteria = Criteria.empty();
    public let features: [String] = [];
    
    open var isAvailable: Bool {
        // Right after connecting the server's disco#info isn't known yet. Say yes then,
        // so the request goes out and fails by itself if the server can't answer it.
        guard let disco = context?.module(.disco), disco.serverDiscoResult.features.isEmpty == false || !disco.serverDiscoResult.identities.isEmpty else {
            return true;
        }
        return disco.serverDiscoResult.features.contains(ExternalServiceDiscoveryModule.XMLNS);
    }
    
    public override init() {
        
    }
    
    public func process(stanza: Stanza) throws {
        throw ErrorCondition.feature_not_implemented;
    }
    
    public func discover(from jid: JID?, type: String?, completionHandler: @escaping (Result<[Service],XMPPError>)->Void) {
        guard let context = context else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        let iq = Iq();
        iq.to = jid ?? JID(context.userBareJid.domain);
        iq.type = .get;
        let servicesEl = Element(name: "services", xmlns: ExternalServiceDiscoveryModule.XMLNS);
        if type != nil {
            servicesEl.setAttribute("type", value: type);
        }
        iq.addChild(servicesEl);
        
        write(iq, completionHandler: { result in
            completionHandler(result.map { response in
                return response.findChild(name: "services", xmlns: ExternalServiceDiscoveryModule.XMLNS)?.mapChildren(transform: Service.parse(_:)) ?? [];
            })
        })
    }
    
    /// Asks the server for the credentials of a service listed as `restricted`
    /// (XEP-0215, "Requesting Credentials"). The answer names the service by
    /// host and type, and by port too when several share the two, so the one
    /// that matches is used. Its username, password and expiry are put on a
    /// copy of `service`, as the answer need not repeat the rest.
    public func credentials(for service: Service, from jid: JID? = nil, completionHandler: @escaping (Result<Service,XMPPError>)->Void) {
        guard let context = context else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        let iq = Iq();
        iq.to = jid ?? JID(context.userBareJid.domain);
        iq.type = .get;
        let serviceEl = Element(name: "service");
        serviceEl.setAttribute("host", value: service.host);
        serviceEl.setAttribute("type", value: service.type);
        if let port = service.port {
            serviceEl.setAttribute("port", value: String(port));
        }
        iq.addChild(Element(name: "credentials", xmlns: ExternalServiceDiscoveryModule.XMLNS, children: [serviceEl]));
        
        write(iq, completionHandler: { result in
            completionHandler(result.flatMap { response in
                let found = response.findChild(name: "credentials", xmlns: ExternalServiceDiscoveryModule.XMLNS)?.mapChildren(transform: Service.parse(_:)) ?? [];
                guard let match = found.first(where: { $0.host == service.host && $0.type == service.type && ($0.port == nil || service.port == nil || $0.port == service.port) }),
                      let username = match.username, let password = match.password else {
                    return .failure(.item_not_found);
                }
                return .success(Service(type: service.type, host: service.host, port: service.port ?? match.port, transport: service.transport ?? match.transport, name: service.name, restricted: service.restricted, username: username, password: password, expires: match.expires));
            })
        })
    }
    
    open class Service {

        public let expires: Date?;
        public let host: String;
        public let name: String?;
        public let password: String?;
        public let port: UInt16?;
        public let restricted: Bool;
        public let transport: Transport?;
        public let type: String;
        public let username: String?;
                
        init(type: String, host: String, port: UInt16? = nil, transport: Transport? = nil, name: String? = nil, restricted: Bool = false, username: String? = nil, password: String? = nil, expires: Date? = nil) {
            self.type = type;
            self.host = host;
            self.port = port;
            self.transport = transport;
            self.name = name;
            self.restricted = restricted;
            self.username = username;
            self.password = password;
            self.expires = expires;
        }
        
        public enum Transport: String {
            case tcp
            case udp
        }
        
        public static func parse(_ el: Element) -> Service? {
            guard el.name == "service", let type = el.getAttribute("type"), let host = el.getAttribute("host") else {
                return nil;
            }
            
            let portStr = el.getAttribute("port");
            let transportStr = el.getAttribute("transport")?.lowercased();
            let restrictedStr = el.getAttribute("restricted");
            return Service(type: type, host: host, port: portStr == nil ? nil : UInt16(portStr!), transport: transportStr == nil ? nil : Transport(rawValue: transportStr!), name: el.getAttribute("name"), restricted: "1" == restrictedStr || "true" == restrictedStr, username: el.getAttribute("username"), password: el.getAttribute("password"), expires: TimestampHelper.parse(timestamp: el.getAttribute("expires")));
        }
    }
    
}

// async-await support
extension ExternalServiceDiscoveryModule {
    
    public func credentials(for service: Service, from jid: JID? = nil) async throws -> Service {
        return try await withUnsafeThrowingContinuation { continuation in
            credentials(for: service, from: jid, completionHandler: { result in
                continuation.resume(with: result);
            })
        }
    }
    
    public func discover(from jid: JID?, type: String?) async throws -> [Service] {
        return try await withUnsafeThrowingContinuation { continuation in
            discover(from: jid, type: type, completionHandler: { result in
                continuation.resume(with: result);
            })
        }
    }
    
}
