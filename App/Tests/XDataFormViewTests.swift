import Testing
import YapnestKit
@testable import Yapnest

@MainActor
struct XDataFormViewTests {
    @Test func shortOptionsStayInAMenu() {
        let options = [XDataForm.Field.Option(label: "Europe/Paris", value: "a"), .init(value: "b")]
        #expect(!XDataFormView.hasLongOptions(options))
    }

    @Test func longOrMultilineOptionsAreListed() {
        #expect(XDataFormView.hasLongOptions([.init(label: String(repeating: "x", count: 31), value: "a")]))
        #expect(XDataFormView.hasLongOptions([.init(label: "one\ntwo", value: "a")]))
    }
}
