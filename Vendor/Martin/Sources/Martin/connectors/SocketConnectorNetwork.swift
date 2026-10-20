//
// SocketConnectorNetwork.swift
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
import Combine
import Network

/**
 Implementation of a C2S XMPP connector based on the `Network.framework`, with Apple's TLS.

 STARTTLS is done by `StartTLSFramer`, a protocol layer between TCP and TLS, so the
 handshake runs on the same connection once the server has said `<proceed/>`. A direct
 TLS connection (XEP-0368) has no such layer, and with TLS disabled there is no TLS at all.
 */
open class SocketConnectorNetwork: XMPPConnectorBase, Connector, NetworkDelegate {

    public class var supportedProtocols: [ConnectorProtocol] {
        return [ConnectorProtocol.XMPP, ConnectorProtocol.XMPPS];
    }

    /// Internal processing queue
    private let queue: QueueDispatcher = QueueDispatcher(label: "xmpp_socket_queue");

    private let userJid: BareJID;
    private var server: String {
        return userJid.domain;
    }
    public private(set) var currentEndpoint: ConnectorEndpoint?;

    /// The `xmlError` message of a connection that ended because the server doesn't offer
    /// STARTTLS, which is a different matter from one that misbehaves: it won't change on a retry.
    public static let startTLSNotOffered = "The server doesn't offer STARTTLS";
    
    /// The TLS version the connection negotiated, once it's up.
    public private(set) var negotiatedTLSVersion: tls_protocol_version_t?;
    /// What ties a sign-in to this connection's TLS (see `ChannelBindings`).
    public private(set) var channelBindings = ChannelBindings();

    private let options: Options;
    private let eventBus: EventBus;
    private let networkStack = SocketConnector.NetworkStack();

    private var connection: NWConnection?;
    /// The STARTTLS framer's account of why it gave up, for the connection in `connection`.
    private var startTLS: StartTLSContext?;
    /// The certificate that failed validation, for the connection in `connection`.
    private var rejectedTrust: RejectedTrust?;
    /// Names the timer that is armed. Bumping it disarms the timer: one already
    /// scheduled finds a different token when it fires, and does nothing.
    private var timeoutToken = 0;
    /// Names the call to `start`, so a DNS answer for an attempt that's over is ignored.
    private var attempt = 0;
    /// The SRV records not tried yet in this attempt, in the order to try them.
    private var remainingCandidates: [SocketConnectorNetwork.Endpoint] = [];
    /// When the DNS query, and the endpoint being connected to, began, for the durations in `ConnectEvent`.
    private var dnsStartedAt = Date();
    private var resolving = false;
    private var endpointStartedAt = Date();
    private var currentKind: EndpointKind = .redirect;

    public required init(context: Context) {
        self.userJid = context.connectionConfiguration.userJid;
        self.options = context.connectionConfiguration.connectorOptions as! Options;
        self.eventBus = context.eventBus;

        super.init(context: context);

        for provider in options.networkProcessorProviders {
            for feature in provider.providedFeatures {
                self.availableFeatures.insert(feature)
            }
        }

        availableFeatures.insert(.TLS);
        availableFeatures.insert(.ZLIB);

        networkStack.delegate = self;
    }

    public func prepareEndpoint(withResumptionLocation location: String?) -> ConnectorEndpoint? {
        guard let endpoint = self.currentEndpoint as? SocketConnectorNetwork.Endpoint, let (host, port) = SocketConnector.preprocessConnectionDetails(string: location) else {
            return nil;
        }
        return SocketConnectorNetwork.Endpoint(proto: endpoint.proto, host: host, port: port ?? endpoint.port);
    }

    public func prepareEndpoint(withSeeOtherHost seeOtherHost: String?) -> ConnectorEndpoint? {
        guard let endpoint = self.currentEndpoint as? SocketConnectorNetwork.Endpoint, let (host, port) = SocketConnector.preprocessConnectionDetails(string: seeOtherHost) else {
            return nil;
        }
        return SocketConnectorNetwork.Endpoint(proto: endpoint.proto, host: host, port: port ?? endpoint.port);
    }

    public func activate(feature: ConnectorFeature) {
        switch feature {
        case .ZLIB:
            self.serialize(.stanza(Stanza(elem: Element(name: "compress", xmlns: "http://jabber.org/protocol/compress", children: [Element(name: "method", cdata: "zlib")]))), completion: .none);
        default:
            // TLS is on from the first byte, so the session never has to ask for it.
            break;
        }
    }

    public func start(endpoint: ConnectorEndpoint?) {
        queue.sync {
            guard state == .disconnected() else {
                logger.log("start() - stopping connetion as state is not connecting \(self.state)");
                return;
            }

            state = .connecting;
            attempt += 1;
            remainingCandidates = [];
            resolving = false;
            // Armed before resolving so that a hung DNS query ends too; every endpoint re-arms it.
            armTimeout();
            if let endpoint = endpoint as? SocketConnectorNetwork.Endpoint {
                self.connect(endpoint: endpoint, kind: .redirect);
            } else if let details = self.options.connectionDetails {
                self.connect(endpoint: details, kind: .configured);
            } else {
                self.dnsStartedAt = Date();
                self.resolving = true;
                self.logger.debug("\(self.userJid) - connecting to server: \(self.server)");
                let attempt = self.attempt;
                self.options.dnsResolver.resolve(domain: server, for: self.userJid) { result in
                    // The resolver answers on its own queue.
                    self.queue.async {
                        guard self.attempt == attempt, self.state == .connecting else {
                            return;
                        }
                        self.resolving = false;
                        var candidates: [SocketConnectorNetwork.Endpoint] = [];
                        if case .success(let dnsResult) = result {
                            candidates = dnsResult.candidates().map { SocketConnectorNetwork.Endpoint(proto: $0.directTls ? .XMPPS : .XMPP, host: $0.target, port: $0.port) };
                        }
                        let found = candidates.count;
                        let fallback = candidates.isEmpty;
                        if fallback {
                            candidates = [SocketConnectorNetwork.Endpoint(proto: .XMPP, host: self.server, port: 5222)];
                        }
                        self.report(.resolved(candidates: found, fallback: fallback, duration: Date().timeIntervalSince(self.dnsStartedAt)));
                        self.remainingCandidates = Array(candidates.dropFirst());
                        self.connect(endpoint: candidates[0], kind: fallback ? .fallbackHost : nil);
                    }
                }
            }
        }
    }

    /// Gives the endpoint being connected to `connectionTimeout` from now, replacing the last timer.
    private func armTimeout() {
        timeoutToken += 1;
        guard let timeout = options.connectionTimeout else {
            return;
        }
        let token = timeoutToken;
        queue.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.connectionTimedOut(token: token) };
    }

    /**
     Should always be called from local dispatch queue!
     */
    private func connect(endpoint: SocketConnectorNetwork.Endpoint, kind: EndpointKind?) -> Void {
        logger.debug("connecting to: \(endpoint)");
        guard state == .connecting else {
            logger.log("connect(addr) - stopping connetion as state is not connecting \(self.state)");
            return;
        }

        self.currentEndpoint = endpoint;
        let kind = kind ?? (endpoint.proto == .XMPPS ? .srvDirectTLS : .srvStartTLS);
        currentKind = kind;
        endpointStartedAt = Date();
        report(.attempting(kind: kind, port: endpoint.port));
        armTimeout();

        let tcpOptions = NWProtocolTCP.Options();
        tcpOptions.noDelay = options.tcpNoDelay;
        // Left off on purpose: with the OS's default timers (hours) it detects
        // nothing, and tuned ones would wake the radio every few seconds. A dead
        // link is found by the session's ping.
        tcpOptions.enableKeepalive = false;

        // A direct TLS connection (XEP-0368) is TLS from the first byte. Otherwise TLS
        // comes by STARTTLS, unless the account turned it off.
        let direct = endpoint.proto == .XMPPS;
        let starttls = !direct && !(context?.connectionConfiguration.disableTLS ?? false);
        let useTLS = direct || starttls;
        let startTLSContext = starttls ? StartTLSContext(domain: server) : nil;
        let rejected = RejectedTrust();
        let parameters: NWParameters;
        if useTLS {
            parameters = NWParameters(tls: tlsOptions(direct: direct, rejected: rejected), tcp: tcpOptions);
            if let startTLSContext {
                guard #available(macOS 12.3, iOS 15.4, macCatalyst 15.4, *) else {
                    close(with: .xmlError("STARTTLS needs a newer system"));
                    return;
                }
                // TLS is the lowest of the application protocols, and the framer goes under it.
                parameters.defaultProtocolStack.applicationProtocols.append(StartTLSFramer.options(context: startTLSContext));
            }
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions);
        }
        parameters.serviceClass = .responsiveData;
        let conn = NWConnection(host: .name(endpoint.host, nil), port: .init(integerLiteral: UInt16(endpoint.port)), using: parameters);
        connection = conn;
        // A new connection's TLS has its own; the last one's must not be signed with.
        channelBindings = ChannelBindings();
        self.startTLS = startTLSContext;
        self.rejectedTrust = rejected;

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let that = self, let conn, that.connection === conn else {
                return;
            }
            that.logger.debug("\(that.userJid) - changed state to: \(state)")
            switch state {
            case .ready:
                guard that.state == .connecting else {
                    return;
                }
                that.timeoutToken += 1;
                if useTLS {
                    that.activeFeatures.insert(.TLS);
                    that.negotiatedTLSVersion = Self.negotiatedTLSVersion(of: conn);
                    if let metadata = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        that.channelBindings = ChannelBindings.read(from: metadata.securityProtocolMetadata);
                    }
                    that.logger.debug("\(that.userJid) - TLS version: \(String(describing: that.negotiatedTLSVersion))");
                }
                that.report(.ready(kind: that.currentKind, port: endpoint.port, family: Self.addressFamily(of: conn), duration: Date().timeIntervalSince(that.endpointStartedAt)));
                that.state = .connected;
                that.initiateParser();
                that.scheduleRead(conn);
                that.restartStream();
            case .failed(let error):
                that.logger.debug("\(that.userJid) - connection failed: \(error)");
                that.disconnect(becauseOf: error);
            case .waiting(let error):
                // Network.framework keeps retrying in the background, which isn't
                // what the session wants: it reconnects when it sees fit.
                that.logger.debug("\(that.userJid) - no route to connect to:\(that.server, privacy: .auto(mask: .hash))! \(error)");
                // Without a usable network no endpoint is at fault, so none is avoided
                // and the others aren't tried. A refused connection is reported the same
                // way but with a network, and that one falls back.
                if that.state == .connecting, let status = conn.currentPath?.status, status != .satisfied {
                    that.reportFailure(.noRoute, error, triesNext: false);
                    that.close(with: .noRouteToServer);
                    return;
                }
                that.disconnect(becauseOf: error);
            case .cancelled:
                that.close(with: .none);
            default:
                break;
            }
        }

        conn.start(queue: self.queue.queue);
    }

    /// What the connection's failure means: a certificate that didn't pass, the server
    /// not doing STARTTLS, or the connection not coming up.
    private func disconnect(becauseOf error: NWError) {
        if let trust = rejectedTrust?.trust {
            reportFailure(.certificate, error, triesNext: false);
            close(with: .sslCertError(trust));
            return;
        }
        if let failure = startTLS?.failure {
            logger.error("\(self.userJid) - STARTTLS failed: \(String(describing: failure))");
            reportFailure(.startTLS, error, triesNext: false);
            close(with: .xmlError(failure == .notOffered ? Self.startTLSNotOffered : "STARTTLS: \(failure)"));
            return;
        }
        if state == .connecting {
            endpointFailed(.noRouteToServer, error: error);
            return;
        }
        close(with: .timeout);
    }

    private func connectionTimedOut(token: Int) {
        guard token == timeoutToken, state == .connecting else {
            return;
        }
        logger.debug("\(self.userJid) - establishing connection to:\(self.server, privacy: .auto(mask: .hash)) timed out!");
        if resolving {
            // No endpoint is at fault: the lookup never answered.
            resolving = false;
            report(.resolveTimedOut(duration: Date().timeIntervalSince(dnsStartedAt)));
            close(with: .timeout);
            return;
        }
        endpointFailed(.timeout, error: nil);
    }

    /// The endpoint being connected to didn't come up. It's avoided for a while, and the next
    /// SRV record is tried, so that one dead port doesn't keep the account offline. Only when
    /// none is left does the attempt end, for the last endpoint's reason.
    private func endpointFailed(_ reason: ConnectorState.DisconnectionReason, error: NWError?) {
        if let endpoint = currentEndpoint as? SocketConnectorNetwork.Endpoint {
            reportFailure(error == nil ? .timeout : .network, error, triesNext: !remainingCandidates.isEmpty);
            options.dnsResolver.markAsInvalid(for: server, host: endpoint.host, port: endpoint.port, for: 15 * 60.0);
        }
        guard !remainingCandidates.isEmpty else {
            close(with: reason);
            return;
        }
        let next = remainingCandidates.removeFirst();
        logger.debug("\(self.userJid) - \(String(describing: self.currentEndpoint)) failed, trying \(next)");
        // Dropped without a state change: the attempt goes on.
        dropConnection();
        connect(endpoint: next, kind: nil);
    }

    /// Drops the connection and, unless it's gone already, reports why. Only the
    /// first reason counts: the connection's cancellation follows every failure.
    private func close(with reason: ConnectorState.DisconnectionReason) {
        timeoutToken += 1;
        remainingCandidates = [];
        dropConnection();
        if state != .disconnected() {
            state = .disconnected(reason);
        }
    }

    /// Lets go of the connection without reporting it: its own state changes are
    /// ignored from here on, including the cancellation this causes.
    private func dropConnection() {
        networkStack.reset();
        let conn = connection;
        connection = nil;
        conn?.stateUpdateHandler = nil;
        conn?.cancel();
    }

    private func tlsOptions(direct: Bool, rejected: RejectedTrust) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options();
        let security = tls.securityProtocolOptions;
        // The connection goes to the SRV target, but the certificate is for the account's domain.
        sec_protocol_options_set_tls_server_name(security, server);
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12);
        if direct {
            sec_protocol_options_add_tls_application_protocol(security, "xmpp-client");
        }
        let validation = options.sslCertificateValidation;
        let domain = server;
        sec_protocol_options_set_verify_block(security, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue();
            let valid = Self.validate(trust, domain: domain, with: validation);
            if !valid {
                rejected.trust = trust;
            }
            complete(valid);
        }, queue.queue);
        return tls;
    }

    private static func validate(_ trust: SecTrust, domain: String, with validation: SSLCertificateValidation) -> Bool {
        switch validation {
        case .default:
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString));
            return SecTrustEvaluateWithError(trust, nil);
        case .fingerprint(let fingerprint):
            return SslCertificateValidator.validateSslCertificate(domain: domain, fingerprint: fingerprint, trust: trust);
        case .customValidator(let validator):
            return validator(trust);
        }
    }

    private static func negotiatedTLSVersion(of connection: NWConnection) -> tls_protocol_version_t? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil;
        }
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata);
    }

    private func scheduleRead(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096 * 2, completion: { [weak self, weak conn] data, context, complete, error in
            guard let self, let conn, self.connection === conn else {
                return;
            }
            if let data = data {
                self.networkStack.read(data: data);
            }
            // The data may have ended the connection.
            guard self.connection === conn else {
                return;
            }
            if let error {
                self.logger.debug("\(self.userJid) - read failed: \(error)")
                self.close(with: .timeout);
            } else if complete {
                self.logger.debug("connection closed by the server")
                self.close(with: .none);
            } else {
                self.scheduleRead(conn);
            }
        })
    }

    public func stop(force: Bool, completionHandler: @escaping ()->Void) {
        self.queue.async {
            guard !force else {
                self.close(with: .none);
                completionHandler();
                return;
            }
            switch self.state {
            case .disconnected(_), .disconnecting:
                self.logger.debug("\(self.userJid) - not connected or already disconnecting");
                completionHandler();
                return;
            case .connected:
                self.state = .disconnecting;
                self.logger.debug("\(self.userJid) - closing XMPP stream");

                self.sendSync("</stream:stream>", completion: .written({ result in
                    self.close(with: .none);
                    completionHandler();
                }));
            case .connecting:
                self.state = .disconnecting;
                self.logger.debug("\(self.userJid) - closing TCP connection");
                self.close(with: .timeout);
                completionHandler();
            }
        }
    }

    public func restartStream() {
        queue.async {
            self.initiateParser();
            self.streamEvents.send(.streamStart);
        }
    }

    private func proceedZlib() {
        if let provider = self.options.networkProcessorProviders.first(where: { $0.providedFeatures.contains(.ZLIB) }) {
            self.networkStack.addProcessor(provider.supply());
        } else {
            self.networkStack.addProcessor(ZLIBProcessor());
        }
        self.activeFeatures.insert(.ZLIB);
        self.restartStream();

    }

    public override func parsed(_ event: StreamEvent) {
        super.parsed(event);
        switch event {
        case .stanza(let packet):
            if packet.name == "error" && packet.xmlns == "http://etherx.jabber.org/streams" {
                close(with: .streamError(packet.element));
            } else if packet.name == "compressed" && packet.xmlns == "http://jabber.org/protocol/compress" {
                proceedZlib();
            } else {
                streamEvents.send(event);
            }
        case .streamClose(let reason):
            if (state != .disconnected()) {
                state = .disconnecting;
            }
            sendSync("</stream:stream>",  completion: .written({ _ in
                self.close(with: reason == .xmlError ? .xmlError(nil) : .none);
            }));
        default:
            streamEvents.send(event);
        }
    }

    private func sendSync(_ data:String, completion: WriteCompletion) {
        self.logger.debug("\(self.userJid) - sending stanza: \(data)");
        let buf = data.data(using: String.Encoding.utf8)!;
        self.networkStack.write(data: buf, completion: completion);
    }

    public override func serialize(_ event: StreamEvent, completion: WriteCompletion) {
        super.serialize(event, completion: completion);
        switch event {
        case .stanza(let stanza):
            self.sendSync(stanza.element.stringValue, completion: completion);
        case .streamClose:
            self.sendSync("<stream:stream/>", completion: completion);
        case .streamOpen(let attributes):
            let attributesString = attributes.map({ "\($0.key)='\($0.value)' "}).joined();
            let openString = "<stream:stream \(attributesString) version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>";
            self.sendSync(openString, completion: completion);
        default:
            break;
        }
    }

    public func send(_ data: StreamEvent, completion: WriteCompletion) {
        queue.async {
            guard self.state == .connected else {
                return;
            }
            self.serialize(data, completion: completion);
        }
    }

    public func read(data: Data) {
        super.read(data: data);
    }

    public func write(data: Data, completion: WriteCompletion) {
        let state = self.connection?.state;
        switch (state) {
        case nil, .failed(_), .cancelled:
            completion.completed(result: .failure(NetworkError.connectionFailed))
        default:
            self.connection?.send(content: data, completion: completion.sendCompletion)
        }
    }

    /// What happened while connecting, as plain values: no host, address or
    /// error text, so a client can log them wherever it likes. Martin's own
    /// logging can't be read back by the app.
    public enum ConnectEvent: Sendable {
        /// The SRV lookup came back with `candidates` records, or with none and the domain itself
        /// will be tried at the default port (`fallback`).
        case resolved(candidates: Int, fallback: Bool, duration: TimeInterval)
        /// The SRV lookup didn't answer before the connection timeout.
        case resolveTimedOut(duration: TimeInterval)
        case attempting(kind: EndpointKind, port: Int)
        case ready(kind: EndpointKind, port: Int, family: AddressFamily, duration: TimeInterval)
        case failed(kind: EndpointKind, port: Int, reason: FailureReason, error: ErrorKind?, code: Int, duration: TimeInterval, triesNext: Bool)
    }

    public enum EndpointKind: String, Sendable, CaseIterable {
        case srvStartTLS, srvDirectTLS
        /// The domain itself, as nothing was found by SRV.
        case fallbackHost
        /// Fixed by the options.
        case configured
        /// Given by the server (a resumption location or another host).
        case redirect
    }

    public enum AddressFamily: String, Sendable, CaseIterable {
        case ipv4, ipv6, unknown
    }

    public enum FailureReason: String, Sendable, CaseIterable {
        case timeout, noRoute, network, certificate, startTLS
    }

    /// The kind of a Network.framework error, which with its code says what went wrong.
    public enum ErrorKind: String, Sendable, CaseIterable {
        case posix, dns, tls, other

        init(_ error: NWError) {
            switch error {
            case .posix: self = .posix
            case .dns: self = .dns
            case .tls: self = .tls
            default: self = .other
            }
        }
    }

    private func report(_ event: ConnectEvent) {
        options.diagnostics?(event);
    }

    private func reportFailure(_ reason: FailureReason, _ error: NWError?, triesNext: Bool) {
        guard let endpoint = currentEndpoint as? SocketConnectorNetwork.Endpoint else {
            return;
        }
        report(.failed(kind: currentKind, port: endpoint.port, reason: reason, error: error.map(ErrorKind.init), code: error.map(Self.errorCode) ?? 0, duration: Date().timeIntervalSince(endpointStartedAt), triesNext: triesNext));
    }

    private static func errorCode(_ error: NWError) -> Int {
        switch error {
        case .posix(let code): return Int(code.rawValue);
        case .dns(let code): return Int(code);
        case .tls(let status): return Int(status);
        default: return 0;
        }
    }

    private static func addressFamily(of connection: NWConnection) -> AddressFamily {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else {
            return .unknown;
        }
        switch host {
        case .ipv4: return .ipv4;
        case .ipv6: return .ipv6;
        default: return .unknown;
        }
    }

    /// The certificate a validator turned down, handed from the verify block to the
    /// connection's failure.
    private final class RejectedTrust: @unchecked Sendable {
        private let lock = NSLock();
        private var _trust: SecTrust?;

        var trust: SecTrust? {
            get {
                lock.lock();
                defer { lock.unlock() }
                return _trust;
            }
            set {
                lock.lock();
                _trust = newValue;
                lock.unlock();
            }
        }
    }

    public struct Endpoint: ConnectorEndpoint, CustomStringConvertible {

        public let proto: ConnectorProtocol;
        public let host: String;
        public let port: Int;

        public var description: String {
            return "\(proto.rawValue):\(host):\(port)";
        }

        public init(proto: ConnectorProtocol, host: String, port: Int) {
            self.proto = proto;
            self.host = host;
            self.port = port;
        }

    }

    public struct Options: ConnectorOptions {

        public var connector: Connector.Type {
            return SocketConnectorNetwork.self;
        }

        public var sslCertificateValidation: SSLCertificateValidation = .default;
        public var connectionDetails: SocketConnectorNetwork.Endpoint?;
        public var lastConnectionDetails: XMPPSrvRecord?;
        /// How long each step of connecting may take: the DNS query, then each endpoint's TCP,
        /// STARTTLS and TLS handshake.
        public var connectionTimeout: Double?;
        public var dnsResolver: DNSSrvResolver = XMPPDNSSrvResolver(directTlsEnabled: true);
        public var tcpNoDelay: Bool = true;
        /// Told what happens while connecting, from the connector's queue.
        public var diagnostics: (@Sendable (ConnectEvent) -> Void)?;

        /// For features that aren't TLS, such as compression.
        public var networkProcessorProviders: [NetworkProcessorProvider] = []

        public init() {}
    }
}

extension WriteCompletion {

    public var sendCompletion: NWConnection.SendCompletion {
        switch self {
        case .none:
            return .idempotent;
        case .written(let callback):
            return .contentProcessed({ error in
                guard let err = error else {
                    callback(.success(Void()));
                    return;
                }
                callback(.failure(err));
            })
        }
    }

}
