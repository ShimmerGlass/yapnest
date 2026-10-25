//
// Sasl2Module.swift
//
// Yapnest's addition to Martin, under the same license.
//

import Foundation
import TigaseLogging

extension XmppModuleIdentifier {
    public static var sasl2: XmppModuleIdentifier<Sasl2Module> {
        return Sasl2Module.IDENTIFIER;
    }
}

/**
 [XEP-0388: Extensible SASL Profile], with [XEP-0386: Bind 2] and stream
 resumption (XEP-0198) inline, and [XEP-0484: FAST] tokens. Signing in,
 binding a resource and resuming or enabling stream management take one
 round trip instead of several, and with a FAST token, no password hashing.

 `AuthModule` uses it in place of `SaslModule` when the server offers it.
 Unlike SASL, success doesn't restart the stream: `SocketSessionLogic`
 takes the outcome with `takeOutcome()` when the next features arrive.
 A resumed stream is the exception: the server has nothing new to
 announce, so no features follow, and the session carries on at once
 (`resumedOutcome`).

 [XEP-0388: Extensible SASL Profile]: https://xmpp.org/extensions/xep-0388.html
 [XEP-0386: Bind 2]: https://xmpp.org/extensions/xep-0386.html
 [XEP-0484: FAST]: https://xmpp.org/extensions/xep-0484.html
 */
open class Sasl2Module: XmppModuleBase, XmppModule, Resetable {

    public static let XMLNS = "urn:xmpp:sasl:2";
    static let BIND_XMLNS = "urn:xmpp:bind:0";
    static let FAST_XMLNS = "urn:xmpp:fast:0";
    static let SASL_XMLNS = "urn:ietf:params:xml:ns:xmpp-sasl";
    public static let ID = XMLNS;
    public static let IDENTIFIER = XmppModuleIdentifier<Sasl2Module>();

    private let logger = Logger(subsystem: "TigaseSwift", category: "Sasl2Module");

    public let criteria = Criteria.or(
        Criteria.name("challenge", xmlns: XMLNS),
        Criteria.name("success", xmlns: XMLNS),
        Criteria.name("failure", xmlns: XMLNS),
        Criteria.name("continue", xmlns: XMLNS)
    );
    public let features = [String]();

    /// Who's signing in, which the server ties resources and tokens to.
    public struct UserAgent {
        /// Stable for this installation of this client (a UUID).
        public var id: String;
        public var software: String?;
        public var device: String?;

        public init(id: String, software: String? = nil, device: String? = nil) {
            self.id = id;
            self.software = software;
            self.device = device;
        }
    }

    /// A XEP-0484 token: signs in instead of the password until it expires.
    public struct FastToken: Codable, Equatable {
        public var mechanism: String;
        public var token: String;
        public var expiry: Date;

        public init(mechanism: String, token: String, expiry: Date) {
            self.mechanism = mechanism;
            self.token = token;
            self.expiry = expiry;
        }
    }

    /// What signing in also did.
    public struct Outcome {
        /// The full JID bound with Bind 2, if it was.
        public var boundJid: JID?;
        /// The stream management `<enabled>` from binding.
        public var smEnabled: Element?;
        /// The stream management `<resumed>` of a resumption.
        public var smResumed: Element?;
    }

    public var userAgent: UserAgent?;
    /// Bind 2's client tag, which servers start the resource with.
    public var bindTag: String?;
    /// Enable message carbons while binding.
    public var enableCarbons = false;
    /// The token to sign in with, if any. Kept up to date with what the
    /// server hands out; `tokenChanged` says when to store it.
    public var fastToken: FastToken?;
    /// A new token arrived (store it), or the server refused ours (nil).
    public var tokenChanged: ((FastToken?) -> Void)?;

    @Published
    public private(set) var state: AuthModule.AuthorizationStatus = .notAuthorized;
    /// Whether the last sign-in used a FAST token rather than the password.
    public private(set) var signedInWithToken = false;

    private var mechanism: SaslMechanism?;
    /// The mechanism the last sign-in used, for tests and diagnostics.
    open private(set) var lastMechanism: String?;
    private var usesFastToken = false;
    private var outcome: Outcome?;
    /// Whether the server enabled message carbons while binding, so that no separate request is needed.
    open internal(set) var carbonsEnabledInline = false;

    public override init() {
    }

    open func reset(scopes: Set<ResetableScope>) {
        if scopes.contains(.stream) || scopes.contains(.session) {
            mechanism = nil;
            usesFastToken = false;
            outcome = nil;
            carbonsEnabledInline = false;
            if state != .notAuthorized {
                state = .notAuthorized;
            }
        }
    }

    private var authentication: Element? {
        return context?.module(.streamFeatures).streamFeatures.element?.findChild(name: "authentication", xmlns: Sasl2Module.XMLNS);
    }

    /// Whether this stream offers SASL2.
    open var isAvailable: Bool {
        return !(authentication?.getChildren(name: "mechanism").isEmpty ?? true);
    }

    /// What signing in also did, once; nil if it wasn't through SASL2.
    open func takeOutcome() -> Outcome? {
        defer {
            outcome = nil;
        }
        return outcome;
    }

    /// Whether signing in resumed the old stream. The server sends no
    /// features after that, so the session mustn't wait for them.
    open var resumedOutcome: Bool {
        return outcome?.smResumed != nil;
    }

    open func login() {
        lastMechanism = nil;
        signedInWithToken = false;
        guard let context = context, let authentication = authentication else {
            state = .error(SaslError.invalid_mechanism);
            return;
        }
        let offered = authentication.getChildren(name: "mechanism").compactMap({ $0.value });
        let inline = authentication.findChild(name: "inline");
        let fast = inline?.findChild(name: "fast", xmlns: Sasl2Module.FAST_XMLNS);
        let fastMechanisms = fast?.getChildren(name: "mechanism").compactMap({ $0.value }) ?? [];

        usesFastToken = false;
        if let token = fastToken, token.expiry > Date(), fastMechanisms.contains(token.mechanism), token.mechanism == HTMechanism.sha256None, userAgent != nil, context.mayTransmitSecrets {
            mechanism = HTMechanism(token: token.token);
            usesFastToken = true;
        } else {
            let candidates: [SaslMechanism] = [
                ScramMechanism.ScramSha256(plus: true), ScramMechanism.ScramSha1(plus: true),
                ScramMechanism.ScramSha256(), ScramMechanism.ScramSha1(), PlainMechanism(),
            ];
            mechanism = candidates.first(where: { offered.contains($0.name) && $0.isAllowedToUse(context) });
        }
        guard let mechanism = mechanism else {
            state = .error(SaslError.invalid_mechanism);
            return;
        }
        lastMechanism = mechanism.name;

        do {
            let authenticate = Stanza(name: "authenticate", xmlns: Sasl2Module.XMLNS);
            authenticate.setAttribute("mechanism", value: mechanism.name);
            if let response = try mechanism.evaluateChallenge(nil, context: context) {
                authenticate.addChild(Element(name: "initial-response", cdata: response));
            }
            if let userAgent = userAgent {
                let agent = Element(name: "user-agent", attributes: ["id": userAgent.id]);
                if let software = userAgent.software {
                    agent.addChild(Element(name: "software", cdata: software));
                }
                if let device = userAgent.device {
                    agent.addChild(Element(name: "device", cdata: device));
                }
                authenticate.addChild(agent);
            }
            let streamManagement = context.modulesManager.moduleOrNil(.streamManagement);
            // Resume where the server lets us; it binds instead if it can't.
            if inline?.findChild(name: "sm", xmlns: StreamManagementModule.SM_XMLNS) != nil, let resume = streamManagement?.sasl2ResumeRequest() {
                authenticate.addChild(resume);
            }
            if let bind = inline?.findChild(name: "bind", xmlns: Sasl2Module.BIND_XMLNS) {
                let request = Element(name: "bind", xmlns: Sasl2Module.BIND_XMLNS);
                if let tag = bindTag {
                    request.addChild(Element(name: "tag", cdata: tag));
                }
                let bindFeatures = bind.findChild(name: "inline")?.getChildren(name: "feature").compactMap({ $0.getAttribute("var") }) ?? [];
                if bindFeatures.contains(StreamManagementModule.SM_XMLNS), let enable = streamManagement?.sasl2EnableRequest() {
                    request.addChild(enable);
                }
                if enableCarbons && bindFeatures.contains(MessageCarbonsModule.MC_XMLNS) {
                    request.addChild(Element(name: "enable", xmlns: MessageCarbonsModule.MC_XMLNS));
                }
                authenticate.addChild(request);
            }
            if usesFastToken {
                authenticate.addChild(Element(name: "fast", xmlns: Sasl2Module.FAST_XMLNS));
            } else if fastMechanisms.contains(HTMechanism.sha256None), userAgent != nil {
                authenticate.addChild(Element(name: "request-token", attributes: ["xmlns": Sasl2Module.FAST_XMLNS, "mechanism": HTMechanism.sha256None]));
            }
            if state != .inProgress {
                state = .inProgress;
            }
            write(authenticate);
        } catch {
            logger.error("Authentication aborted: \(error)");
            state = .error(SaslError.aborted);
        }
    }

    open func process(stanza: Stanza) throws {
        do {
            switch stanza.name {
            case "challenge":
                try processChallenge(stanza);
            case "success":
                try processSuccess(stanza);
            case "failure":
                processFailure(stanza);
            default:
                // Tasks after authentication (2FA and the like) aren't supported.
                logger.error("Server asked for SASL2 tasks we don't support");
                state = .error(SaslError.aborted);
            }
        } catch ClientSaslException.invalidServerSignature, ClientSaslException.wrongNonce {
            state = .error(SaslError.server_not_trusted);
        } catch {
            logger.debug("SASL2 failed: \(error)");
            state = .error(SaslError.temporary_auth_failure);
        }
    }

    private func processChallenge(_ stanza: Stanza) throws {
        guard let context = context, let mechanism = mechanism, mechanism.status != .completed else {
            throw XMPPError.bad_request("Authentication is already completed!");
        }
        let response = Stanza(name: "response", xmlns: Sasl2Module.XMLNS);
        response.element.value = try mechanism.evaluateChallenge(stanza.element.value, context: context);
        write(response);
    }

    private func processSuccess(_ stanza: Stanza) throws {
        guard let context = context, let mechanism = mechanism else {
            throw XMPPError.unexpected_request("No authentication in progress");
        }
        // The server's proof, such as SCRAM's signature, must check out.
        let additionalData = stanza.findChild(name: "additional-data")?.value;
        if mechanism.status != .completed {
            _ = try mechanism.evaluateChallenge(additionalData, context: context);
        }
        guard mechanism.status == .completed else {
            throw ClientSaslException.invalidServerSignature;
        }

        if let tokenEl = stanza.findChild(name: "token", xmlns: Sasl2Module.FAST_XMLNS), let token = tokenEl.getAttribute("token"),
           let expiry = tokenEl.getAttribute("expiry").flatMap({ TimestampHelper.parse(timestamp: $0) }) {
            let new = FastToken(mechanism: HTMechanism.sha256None, token: token, expiry: expiry);
            fastToken = new;
            tokenChanged?(new);
        }

        let usedToken = usesFastToken;
        if stanza.findChild(name: "failed", xmlns: StreamManagementModule.SM_XMLNS) != nil {
            // The old session is gone. Clear it now, before the new one's
            // `<enabled>` and JID are applied below, as a reset afterwards
            // would undo them. This module's own state is rebuilt below.
            context.reset(scopes: [.session]);
        }
        var outcome = Outcome();
        if let identifier = stanza.findChild(name: "authorization-identifier")?.value, case let jid = JID(identifier), jid.resource != nil,
           stanza.findChild(name: "bound", xmlns: Sasl2Module.BIND_XMLNS) != nil {
            outcome.boundJid = jid;
            outcome.smEnabled = stanza.findChild(name: "bound", xmlns: Sasl2Module.BIND_XMLNS)?.findChild(name: "enabled", xmlns: StreamManagementModule.SM_XMLNS);
        }
        outcome.smResumed = stanza.findChild(name: "resumed", xmlns: StreamManagementModule.SM_XMLNS);
        carbonsEnabledInline = stanza.findChild(name: "bound", xmlns: Sasl2Module.BIND_XMLNS)?.findChild(name: "enabled", xmlns: MessageCarbonsModule.MC_XMLNS) != nil;
        self.outcome = outcome;
        if let resumed = outcome.smResumed {
            // Now, not when the session logic gets to it: the server's
            // `<r/>` and the stanzas it resends follow `<success>` at
            // once, and without the counters running they'd be dropped or
            // go uncounted.
            context.modulesManager.moduleOrNil(.streamManagement)?.processResumed(Stanza.from(element: resumed));
        }
        if let jid = outcome.boundJid {
            // Likewise for a binding: the first stanzas after `<success>`
            // must be counted and answered, and sent from the bound JID,
            // before the session logic gets to the authorization.
            context.modulesManager.moduleOrNil(.resourceBind)?.bindedJid = jid;
            if let enabled = outcome.smEnabled {
                context.modulesManager.moduleOrNil(.streamManagement)?.processEnabled(Stanza.from(element: enabled));
            }
        }
        signedInWithToken = usedToken;
        logger.debug("Authenticated with SASL2");
        state = .authorized;
    }

    private func processFailure(_ stanza: Stanza) {
        let condition = stanza.findChild(xmlns: Sasl2Module.SASL_XMLNS)?.name;
        if usesFastToken {
            // A token the server no longer takes: forget it, and sign in
            // with the password on the same stream.
            logger.debug("FAST token refused (\(condition ?? "?")), using the password");
            fastToken = nil;
            tokenChanged?(nil);
            login();
            return;
        }
        mechanism = nil;
        state = .error(condition.flatMap(SaslError.init(rawValue:)) ?? SaslError.not_authorized);
    }
}
