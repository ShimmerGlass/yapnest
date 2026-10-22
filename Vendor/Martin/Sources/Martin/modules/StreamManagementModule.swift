//
// StreamManagementModule.swift
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
import Combine
import TigaseLogging

extension XmppModuleIdentifier {
    public static var streamManagement: XmppModuleIdentifier<StreamManagementModule> {
        return StreamManagementModule.IDENTIFIER;
    }
}

extension StreamFeatures.StreamFeature {
    public static let sm = StreamFeatures.StreamFeature(name: "sm", xmlns: StreamManagementModule.SM_XMLNS);
}

/**
 Module implements support for [XEP-0198: Stream Management]
 
 [XEP-0198: Stream Management]: http://xmpp.org/extensions/xep-0198.html
 */
open class StreamManagementModule: XmppModuleBase, XmppModule, XmppStanzaFilter, Resetable {
    
    /// Namespace used by stream management
    static let SM_XMLNS = "urn:xmpp:sm:3";
    
    /// ID of module for lookup in `XmppModulesManager`
    public static let ID = SM_XMLNS;
    public static let IDENTIFIER = XmppModuleIdentifier<StreamManagementModule>();
    
    private let logger = Logger(subsystem: "TigaseSwift", category: "StreamManagementModule")
    
    public let criteria = Criteria.xmlns(SM_XMLNS);
    
    public let features = [String]();
        
    /// Holds queue with stanzas sent but not acked
    fileprivate var outgoingQueue = Queue<Stanza>();

    /// Each stanza the server confirmed it received, in the order sent.
    public let ackedStanzas = PassthroughSubject<Stanza, Never>();
    
    // TODO: should this stay here or be moved to sessionObject as in Jaxmpp?
    private let queue = DispatchQueue(label: "StreamManagementQueue");
    private var ackH = AckHolder();

    fileprivate var _ackEnabled: Bool = false;
    /// Set once `<enable>` went out. The server counts what follows it, so
    /// the counting can't wait for `<enabled>`.
    private var enableWritten: Bool = false;
    /// Is ACK enabled?
    open var ackEnabled: Bool {
        return _ackEnabled;
    }
    
    fileprivate var lastRequestTimestamp = Date();
    fileprivate var lastSentH = UInt32(0);
    
    /// Is stream resumption enabled?
    open var resumptionEnabled: Bool {
        return resumptionId != nil
    }
    
    fileprivate var resumptionId: String? = nil;
    
    fileprivate var _resumptionLocation: ConnectorEndpoint? = nil;
    /// Address to use when resuming stream
    open var resumptionLocation: ConnectorEndpoint? {
        return _resumptionLocation;
    }
    /// Maximal resumption timeout to use
    open var maxResumptionTimeout: Int?;
    
    fileprivate var _resumptionTime: TimeInterval?;
    /// Negotiated resumption timeout
    open var resumptionTime: TimeInterval? {
        return _resumptionTime;
    }
    
    private var enablingHandler: ((Result<String?,XMPPError>)->Void)?;
    private var resumptionHandler: ((Result<Void,XMPPError>)->Void)?;
    
    open private(set) var isAvailable: Bool = false;
    
    open var ackDelay: TimeInterval = 0.1;
    private var scheduledAck: Bool = false;
    /// Counts the streams so far. A delayed ack belongs to the stream it was
    /// scheduled on, and a new stream, not yet authenticated, answers one
    /// with a stream error. Only touched on the internal queue.
    private var streamGeneration: UInt = 0;
    
    open override var context: Context? {
        didSet {
            store(context?.module(.streamFeatures).$streamFeatures.map({ $0.contains(.sm) }).assign(to: \.isAvailable, on: self));
        }
    }
    
    public override init() {
    }
    
    /**
     Method tries to enable Stream Management
     - parameter resumption: should resumption be enabled
     - parameter maxResumptionTimeout: maximal resumption timeout to use
     */
    open func enable(resumption: Bool = true, maxResumptionTimeout: Int? = nil, completionHandler: ( (Result<String?,XMPPError>)->Void)?) {
        guard !(ackEnabled || resumptionEnabled) else {
            completionHandler?(.failure(.unexpected_request()));
            return;
        }
        
        logger.debug("enabling StreamManagament with resume=\(resumption)");
        self.enablingHandler = completionHandler;
        let enable = Stanza(name: "enable", xmlns: StreamManagementModule.SM_XMLNS);
        if resumption {
            enable.setAttribute("resume", value: "true");
            let timeout = maxResumptionTimeout ?? self.maxResumptionTimeout;
            if timeout != nil {
                enable.setAttribute("max", value: String(timeout!));
            }
        }
        
        write(enable);
    }
    
    open func reset(scopes: Set<ResetableScope>) {
        queue.sync {
            self.scheduledAck = false;
            if scopes.contains(.stream) {
                streamGeneration &+= 1;
            }
        }
        if scopes.contains(.stream) {
            _ackEnabled = false;
            queue.sync {
                enableWritten = false;
            }
        }
        if scopes.contains(.session) {
            reset();
        }
    }
        
    open func process(stanza: Stanza) throws {
        // all requests should be processed already
        throw ErrorCondition.undefined_condition;
    }
    
    /**
     Method filters incoming stanza to process StreamManagement stanzas.
     - parameter stanza: stanza to process
     */
    open func processIncoming(stanza: Stanza) -> Bool {
        guard ackEnabled else {
            guard stanza.xmlns == StreamManagementModule.SM_XMLNS else {
                return false;
            }
            
            switch stanza.name {
            case "resumed":
                processResumed(stanza);
            case "failed":
                processFailed(stanza);
            case "enabled":
                processEnabled(stanza);
            default:
                break;
            }
            return true;
        }
        
        guard stanza.xmlns == StreamManagementModule.SM_XMLNS else {
            guard isStanza(stanza) else {
                return false;
            }
            queue.sync {
                ackH.incrementIncoming();
                guard !self.scheduledAck else {
                    return;
                }
                self.scheduledAck = true;
                let generation = streamGeneration;
                queue.asyncAfter(deadline: .now() + ackDelay) {
                    guard self.scheduledAck, generation == self.streamGeneration else {
                        return;
                    }
                    self.scheduledAck = false;
                    self._sendAck(force: true);
                }
            }
            return false;
        }
        
        switch stanza.name {
        case "a":
            processAckAnswer(stanza);
            return true;
        case "r":
            processAckRequest(stanza);
            return true;
        default:
            return false;
        }
        //return false;
    }
    
    /**
     Method processes every outgoing stanza to queue sent
     stanza until they will be acked.
     - parameter stanza: stanza to process
     */
    open func processOutgoing(stanza: Stanza) {
        // Seen here, in step with the socket writes, rather than when
        // `enable()` is called: stanzas already on their way to the socket
        // precede `<enable>` and aren't counted by the server.
        if stanza.name == "enable" && stanza.xmlns == StreamManagementModule.SM_XMLNS {
            queue.sync {
                enableWritten = true;
            }
            return;
        }
        
        guard ackEnabled || queue.sync(execute: { enableWritten }) else {
            return;
        }
        
        guard isStanza(stanza) else {
            return;
        }
        
        // The counter and the queue change together, so an ack arriving
        // in between can't see one without the other.
        let pending: Int = queue.sync {
            ackH.incrementOutgoing();
            outgoingQueue.offer(stanza);
            return outgoingQueue.count;
        }
        if (pending > 3) {
            request();
        }
    }
    
    /// The oldest stanza written that the server hasn't acknowledged. When the server closes the
    /// stream on a stanza it read, this is the one it stopped at, provided it acknowledged
    /// everything before. It is still there after a disconnect: only a new session clears the queue.
    public var oldestUnacknowledged: Stanza? {
        return queue.sync { outgoingQueue.peek() };
    }

    /// Every stanza written that the server hasn't acknowledged, oldest first.
    public var unacknowledgedStanzas: [Stanza] {
        return queue.sync { outgoingQueue.values };
    }
    
    open func isStanza(_ stanza: Stanza) -> Bool {
        switch stanza.name {
        case "iq", "message", "presence":
            return true;
        default:
            return false;
        }
    }

    /// Send ACK request to server
    open func request() {
        guard lastRequestTimestamp.timeIntervalSinceNow < 1 else {
            return;
        }
        
        let r = Stanza(name: "r", xmlns: StreamManagementModule.SM_XMLNS);
        write(r);
        lastRequestTimestamp = Date();
    }
    
    /// Reset all internal variables
    open func reset() {
        enablingHandler = nil;
        resumptionHandler = nil;
        _ackEnabled = false;
        resumptionId = nil
        _resumptionTime = nil;
        _resumptionLocation = nil;
        queue.sync {
            enableWritten = false;
            ackH.reset();
        }
        outgoingQueue.clear();
    }
    
    /// Start stream resumption
    open func resume(completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        logger.debug("starting stream resumption");
        self.resumptionHandler = completionHandler;
        let resume = Stanza(name: "resume", xmlns: StreamManagementModule.SM_XMLNS);
        queue.sync {
            resume.setAttribute("h", value: String(ackH.incomingCounter));
        }
        resume.setAttribute("previd", value: resumptionId);
        
        write(resume);
    }
    
    /// The `<resume>` to put in a SASL2 `<authenticate>`, if there's a
    /// stream to resume.
    func sasl2ResumeRequest() -> Element? {
        guard let resumptionId = resumptionId else {
            return nil;
        }
        let resume = Element(name: "resume", xmlns: StreamManagementModule.SM_XMLNS);
        queue.sync {
            resume.setAttribute("h", value: String(ackH.incomingCounter));
        }
        resume.setAttribute("previd", value: resumptionId);
        return resume;
    }

    /// The `<enable>` to put in a Bind 2 request.
    func sasl2EnableRequest() -> Element {
        let enable = Element(name: "enable", xmlns: StreamManagementModule.SM_XMLNS);
        enable.setAttribute("resume", value: "true");
        if let timeout = maxResumptionTimeout {
            enable.setAttribute("max", value: String(timeout));
        }
        return enable;
    }

    /// Send ACK to server
    open func sendAck() {
        return queue.sync {
            _sendAck(force: false);
        }
    }
    
    private func _sendAck(force: Bool) {
        guard let a = prepareAck(force: false) else {
            return;
        }
        write(a);
    }
    
    // call only from internal queue
    private func prepareAck(force: Bool) -> Stanza? {
        guard force || lastSentH != ackH.incomingCounter else {
            return nil;
        }
        
        let value = ackH.incomingCounter;
        lastSentH = value;
        
        let a = Stanza(name: "a", xmlns: StreamManagementModule.SM_XMLNS);
        a.setAttribute("h", value: String(value));
        return a;
    }
    
    /// Process ACK from server
    func processAckAnswer(_ stanza: Stanza) {
        guard let attr = stanza.getAttribute("h") else {
            return;
        }
        let newH = UInt32(attr) ?? 0;
        let acked: [Stanza] = queue.sync {
            _ackEnabled = true;
            // `outgoingCounter` counts every stanza written, so it stays as it
            // is: setting it to the server's count made later acks mistake
            // stanzas the server hadn't handled yet for acknowledged ones.
            let left = unacknowledged(newH: newH);
            var acked: [Stanza] = [];
            while left < outgoingQueue.count, let stanza = outgoingQueue.poll() {
                acked.append(stanza);
            }
            return acked;
        }
        for stanza in acked {
            ackedStanzas.send(stanza);
        }
    }
    
    /// How many of the stanzas written the server hasn't handled, by its
    /// count. Call only from the internal queue.
    ///
    /// The counters wrap, so the difference is read as signed. A server
    /// claiming more than was written means we miscounted; as an unsigned
    /// difference that would wrap to a huge number and acknowledge nothing
    /// for the rest of the stream, so the queue counts as handled instead.
    private func unacknowledged(newH: UInt32) -> Int {
        let left = Int(Int32(bitPattern: ackH.outgoingCounter &- newH));
        guard left < 0 else {
            return left;
        }
        logger.error("server handled \(-left) more stanzas than were written, counting them as acknowledged");
        ackH.outgoingCounter = newH;
        return 0;
    }
    
    /// Process ACK request from server
    func processAckRequest(_ stanza: Stanza) {
        let generation = queue.sync { streamGeneration };
        queue.asyncAfter(deadline: .now() + 0.1) {
            guard generation == self.streamGeneration, let a = self.prepareAck(force: true) else {
                return;
            }
            self.write(a);
        }
    }
    
    func processFailed(_ stanza: Stanza) {
        let resumptionHandler = self.resumptionHandler;
        let enablingHandler = self.enablingHandler;
        reset();
        
        logger.debug("stream resumption failed");
        
        resumptionHandler?(.failure(stanza.error ?? .unexpected_request()));
        enablingHandler?(.failure(stanza.error ?? .unexpected_request()));
        if let context = context {
            fire(FailedEvent(context: context, errorCondition: stanza.errorCondition ?? .unexpected_request));
        }
    }
    
    func processResumed(_ stanza: Stanza) {
        let newH = stanza.getAttribute("h").flatMap { UInt32($0) } ?? 0;
        _ackEnabled = true;
        let acked: [Stanza] = queue.sync {
            let left = unacknowledged(newH: newH);
            var acked: [Stanza] = [];
            while left < outgoingQueue.count, let stanza = outgoingQueue.poll() {
                acked.append(stanza);
            }
            // The stanzas still queued are written again below, and each
            // write counts itself, so start from what the server handled.
            ackH.outgoingCounter = newH;
            return acked;
        }
        for stanza in acked {
            ackedStanzas.send(stanza);
        }
        let oldOutgoingQueue = outgoingQueue;
        outgoingQueue = Queue<Stanza>();
        var resent = false;
        while let s = oldOutgoingQueue.poll() {
            write(s);
            resent = true;
        }
        // Nothing else asks the server about these: the request is otherwise
        // sent after a send of ours or when over three are waiting, so they
        // would stay unacknowledged until the next message.
        if resent {
            request();
        }
        
        logger.debug("stream resumed");
        if let completionHandler = resumptionHandler {
            resumptionHandler = nil;
            completionHandler(.success(Void()));
        }
        if let context = context {
            fire(ResumedEvent(context: context, newH: newH, resumeId: stanza.getAttribute("previd")));
        }
    }
    
    func processEnabled(_ stanza: Stanza) {
        let id = stanza.getAttribute("id");
        let r = stanza.getAttribute("resume");
        let mx = stanza.getAttribute("max");
        let resume = (r == "true" || r == "1") && id != nil;
        _resumptionLocation = (self.context as? XMPPClient)?.connector?.prepareEndpoint(withResumptionLocation: stanza.getAttribute("location"))
        
        resumptionId = id;
        _ackEnabled = true;
        if mx != nil {
            _resumptionTime = Double(mx!);
        }
        
        logger.debug("stream management enabled");
        if let completionHandler = enablingHandler {
            enablingHandler = nil;
            completionHandler(.success(resumptionId));
        }
        if let context = context {
            context.eventBus.fire(EnabledEvent(context: context, resume: resume, resumeId: id));
        }
    }
    
    func setOutgoingCounterForTesting(_ value: UInt32) {
        queue.sync {
            ackH.outgoingCounter = value;
        }
    }

    /// Internal class for holding incoming and outgoing counters
    class AckHolder {
        
        var incomingCounter:UInt32 = 0;
        var outgoingCounter:UInt32 = 0;
        
        func reset() {
            incomingCounter = 0;
            outgoingCounter = 0;
        }
        
        func incrementOutgoing() {
            outgoingCounter &+= 1;
        }
        
        func incrementIncoming() {
            incomingCounter &+= 1;
        }
        
    }
    
    /// Event fired when Stream Management is enabled
    @available(* , deprecated, message: "Should not be needed")
    open class EnabledEvent: AbstractEvent {
        /// Identifier of event which should be used during registration of `EventHandler`
        public static let TYPE = EnabledEvent();

        /// Is resumption enabled?
        public let resume: Bool;
        /// ID of stream for resumption
        public let resumeId:String?;

        init() {
            resume = false;
            resumeId = nil
            super.init(type: "StreamManagementEnabledEvent")
        }

        init(context: Context, resume: Bool, resumeId: String?) {
            self.resume = resume;
            self.resumeId = resumeId;
            super.init(type: "StreamManagementEnabledEvent", context: context);
        }

    }

    /// Event fired when Stream Management fails
    @available(* , deprecated, message: "Should not be needed, if required use Resetable protocol for XMPPModule")
    open class FailedEvent: AbstractEvent {
        /// Identifier of event which should be used during registration of `EventHandler`
        public static let TYPE = FailedEvent();

        /// Received error condition
        public let errorCondition:ErrorCondition!;

        init() {
            errorCondition = nil
            super.init(type: "StreamManagementFailedEvent");
        }

        init(context: Context, errorCondition: ErrorCondition) {
            self.errorCondition = errorCondition;
            super.init(type: "StreamManagementFailedEvent", context: context);
        }

    }

    @available(* , deprecated, message: "Should not be needed")
    open class ResumedEvent: AbstractEvent {
        /// Identifier of event which should be used during registration of `EventHandler`
        public static let TYPE = ResumedEvent();

        /// Value of H attribute
        public let newH: UInt32?;
        /// ID of resumed stream
        public let resumeId:String?;

        init() {
            newH = nil;
            resumeId = nil
            super.init(type: "StreamManagementResumedEvent")
        }

        init(context: Context, newH: UInt32, resumeId: String?) {
            self.newH = newH;
            self.resumeId = resumeId;
            super.init(type: "StreamManagementResumedEvent", context: context);
        }

    }

}


/// Internal implementation of queue for holding items
public class Queue<T> {

    private class Node<T> {
        
        let value: T;
        weak var prev: Node<T>? = nil;
        var next: Node<T>? = nil;
        
        init(value: T) {
            self.value = value;
        }
        
    }
    
    private var _count: Int = 0;
    private var head: Node<T>? = nil;
    private var tail: Node<T>? = nil;
    
    public var isEmpty: Bool {
        return head == nil;
    }
    
    open var count: Int {
        return _count;
    }
    
    public init() {
    }
    
    open func clear() {
        head = nil;
        tail = nil;
        _count = 0;
    }
    
    open func offer(_ value: T) {
        let newNode = Node<T>(value: value);
        if let tailNode = tail {
            newNode.prev = tailNode;
            tailNode.next = newNode;
        } else {
            head = newNode;
        }
        
        tail = newNode;
        self._count += 1;
    }
    
    open var values: [T] {
        var result: [T] = [];
        var node = head;
        while let current = node {
            result.append(current.value);
            node = current.next;
        }
        return result;
    }
    
    open func peek() -> T? {
        return head?.value;
    }
    
    open func poll() -> T? {
        defer {
            head = head?.next;
            if head == nil {
                tail = nil;
            }
            _count -= 1;
        }
        
        return head?.value;
    }
}

// async-await support
extension StreamManagementModule {
    
    open func enable(resumption: Bool = true, maxResumptionTimeout: Int? = nil) async throws {
        _ = try await withUnsafeThrowingContinuation { continuation in
            enable(resumption: resumption, maxResumptionTimeout: maxResumptionTimeout, completionHandler: { result in
                continuation.resume(with: result);
            })
        }
    }
    
    open func resume() async throws {
        _ = try await withUnsafeThrowingContinuation { continuation in
            resume(completionHandler: { result in
                continuation.resume(with: result);
            })
        }
    }
}
