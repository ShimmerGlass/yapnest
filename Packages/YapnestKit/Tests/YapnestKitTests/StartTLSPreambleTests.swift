import Foundation
import Testing
@testable import Martin

/// What the STARTTLS framer reads from the server before TLS: the features,
/// then the answer to STARTTLS. The framer itself needs a socket; this is its
/// logic.
struct StartTLSPreambleTests {
    private let header = "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0' from='localhost' id='x1'>"
    private let withStartTLS = "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>"
    private let withoutStartTLS = "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>"
    private let proceed = "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"

    private func feed(_ preamble: inout StartTLSPreamble, _ text: String) -> StartTLSPreamble.Step {
        preamble.receive(Data(text.utf8))
    }

    /// A preamble that has seen the features and asked.
    private func asked() -> StartTLSPreamble {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + withStartTLS) == .sendStartTLS)
        return preamble
    }

    // MARK: What we send

    @Test func theHeaderNamesTheDomain() {
        let header = String(decoding: StartTLSPreamble.streamHeader(to: "example.org"), as: UTF8.self)
        #expect(header.contains("to='example.org'"))
        #expect(header.contains("xmlns:stream='http://etherx.jabber.org/streams'"))
        #expect(header.contains("version='1.0'"))
    }

    @Test func theHeaderEscapesTheDomain() {
        let header = String(decoding: StartTLSPreamble.streamHeader(to: "a'b&c<d"), as: UTF8.self)
        #expect(header.contains("to='a&apos;b&amp;c&lt;d'"))
    }

    @Test func theRequestIsStartTLS() {
        #expect(String(decoding: StartTLSPreamble.request, as: UTF8.self) == "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
    }

    // MARK: Features

    @Test func featuresWithStartTLSAskForIt() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + withStartTLS) == .sendStartTLS)
    }

    @Test func featuresWithoutStartTLSFail() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + withoutStartTLS) == .fail(.notOffered))
    }

    @Test func emptyFeaturesFail() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + "<stream:features/>") == .fail(.notOffered))
    }

    @Test func startTLSInAnotherNamespaceIsNotStartTLS() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + "<stream:features><starttls xmlns='urn:example:other'/></stream:features>") == .fail(.notOffered))
    }

    @Test func startTLSWithDoubleQuotesIsStartTLS() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + "<stream:features><starttls xmlns=\"urn:ietf:params:xml:ns:xmpp-tls\"/></stream:features>") == .sendStartTLS)
    }

    @Test func aPrefixedFeaturesElementWorks() {
        var preamble = StartTLSPreamble()
        let features = "<s:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></s:features>"
        #expect(feed(&preamble, header + features) == .sendStartTLS)
    }

    @Test func waitsForTheEndOfTheFeatures() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header) == .needMore)
        #expect(feed(&preamble, "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'>") == .needMore)
        #expect(feed(&preamble, "<required/></starttls></stream:features>") == .sendStartTLS)
    }

    @Test func featuresSplitAtEveryByteStillAreRead() {
        for (text, expected) in [(header + withStartTLS, StartTLSPreamble.Step.sendStartTLS), (header + withoutStartTLS, .fail(.notOffered))] {
            var preamble = StartTLSPreamble()
            var last = StartTLSPreamble.Step.needMore
            for byte in Data(text.utf8) {
                last = preamble.receive(Data([byte]))
                if last != .needMore { break }
            }
            #expect(last == expected)
        }
    }

    @Test func aMultiByteCharacterSplitBetweenReadsIsRead() {
        var preamble = StartTLSPreamble()
        let bytes = Array((header + "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/><x>é</x></stream:features>").utf8)
        let cut = bytes.firstIndex(of: 0xC3)! + 1
        #expect(preamble.receive(Data(bytes[..<cut])) == .needMore)
        #expect(preamble.receive(Data(bytes[cut...])) == .sendStartTLS)
    }

    @Test func aStreamErrorBeforeTheFeaturesFails() {
        var preamble = StartTLSPreamble()
        let error = "<stream:error><host-unknown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error></stream:stream>"
        #expect(feed(&preamble, header + error) == .fail(.streamError))
    }

    @Test func anythingAfterTheFeaturesFails() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + withStartTLS + "<message/>") == .fail(.unexpected))
    }

    @Test func whitespaceAfterTheFeaturesIsFine() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + withStartTLS + "\n ") == .sendStartTLS)
    }

    @Test func aServerThatSaysTooMuchFails() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header) == .needMore)
        #expect(feed(&preamble, String(repeating: "x", count: 100_000)) == .fail(.tooLarge))
    }

    // MARK: The answer

    @Test func proceedStartsTLS() {
        var preamble = asked()
        #expect(feed(&preamble, proceed) == .proceed)
    }

    @Test func proceedWithAnEndTagStartsTLS() {
        var preamble = asked()
        #expect(feed(&preamble, "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'></proceed>") == .proceed)
    }

    @Test func proceedSplitAtEveryByteStartsTLS() {
        var preamble = asked()
        var last = StartTLSPreamble.Step.needMore
        for byte in Data(proceed.utf8) {
            #expect(last == .needMore)
            last = preamble.receive(Data([byte]))
        }
        #expect(last == .proceed)
    }

    @Test func failureRefuses() {
        var preamble = asked()
        #expect(feed(&preamble, "<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>") == .fail(.refused))
    }

    @Test func failureSplitAcrossReadsRefuses() {
        var preamble = asked()
        #expect(feed(&preamble, "<fail") == .needMore)
        #expect(feed(&preamble, "ure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>") == .fail(.refused))
    }

    @Test func aStreamErrorInsteadOfProceedFails() {
        var preamble = asked()
        #expect(feed(&preamble, "<stream:error><policy-violation xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error>") == .fail(.streamError))
    }

    @Test func somethingElseInsteadOfProceedFails() {
        var preamble = asked()
        #expect(feed(&preamble, "<message/>") == .fail(.unexpected))
    }

    @Test func proceedInAnotherNamespaceFails() {
        var preamble = asked()
        #expect(feed(&preamble, "<proceed xmlns='urn:example:other'/>") == .fail(.unexpected))
    }

    @Test func textInsteadOfProceedFails() {
        var preamble = asked()
        #expect(feed(&preamble, "hello") == .fail(.unexpected))
    }

    // MARK: Bytes that don't belong

    @Test func bytesAfterProceedInTheSameReadFail() {
        var preamble = asked()
        let extra = "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms></stream:features>"
        #expect(feed(&preamble, proceed + extra) == .fail(.dataAfterProceed))
    }

    @Test func aSingleByteAfterProceedFails() {
        var preamble = asked()
        #expect(feed(&preamble, proceed + " ") == .fail(.dataAfterProceed))
    }

    @Test func bytesAfterProceedWithAnEndTagFail() {
        var preamble = asked()
        #expect(feed(&preamble, "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'></proceed><success/>") == .fail(.dataAfterProceed))
    }

    @Test func bytesAfterTheFeaturesInTheSameReadAsProceedCantHappen() {
        // The server can't know we asked before we did, so a proceed that came with the features is not an answer.
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header + withStartTLS + proceed) == .fail(.unexpected))
    }

    @Test func theAnswerStaysTheSameOnceGiven() {
        var proceeded = asked()
        #expect(feed(&proceeded, proceed) == .proceed)
        #expect(feed(&proceeded, "more") == .proceed)

        var failed = StartTLSPreamble()
        #expect(feed(&failed, header + withoutStartTLS) == .fail(.notOffered))
        #expect(feed(&failed, proceed) == .fail(.notOffered))
    }

    // MARK: The end

    @Test func theConnectionEndingBeforeFeaturesFails() {
        var preamble = StartTLSPreamble()
        #expect(feed(&preamble, header) == .needMore)
        #expect(preamble.receiveEnd() == .fail(.closed))
    }

    @Test func theConnectionEndingBeforeProceedFails() {
        var preamble = asked()
        #expect(preamble.receiveEnd() == .fail(.closed))
    }

    @Test func theConnectionEndingAfterProceedChangesNothing() {
        var preamble = asked()
        #expect(feed(&preamble, proceed) == .proceed)
        #expect(preamble.receiveEnd() == .proceed)
    }
}
