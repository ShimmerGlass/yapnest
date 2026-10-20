import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// XEP-0004 forms as the kit reads, edits, checks and sends them.
struct XDataFormTests {
    private func parse(_ xml: String) throws -> XDataForm {
        let element = try #require(Element.from(string: xml))
        return try #require(XDataForm(element))
    }

    private let everyType = """
    <x xmlns='jabber:x:data' type='form'>
      <title>Add a user</title>
      <instructions>Fill it in.</instructions>
      <instructions>Carefully.</instructions>
      <field type='hidden' var='FORM_TYPE'><value>http://jabber.org/protocol/admin</value></field>
      <field type='fixed'><value>Section one</value></field>
      <field type='text-single' var='name' label='Name'><desc>Their name</desc><required/><value>Ann</value></field>
      <field type='text-private' var='secret' label='Secret'/>
      <field type='text-multi' var='bio'><value>one</value><value>two</value></field>
      <field type='boolean' var='admin' label='Admin'><value>true</value></field>
      <field type='jid-single' var='owner'><value>a@b.c/r</value></field>
      <field type='jid-multi' var='others'><value>a@b.c</value><value>d@e.f</value></field>
      <field type='list-single' var='role'><value>mod</value><option label='Moderator'><value>mod</value></option><option><value>user</value></option></field>
      <field type='list-multi' var='tags'><value>b</value><option><value>a</value></option><option><value>b</value></option><option><value>c</value></option></field>
      <field var='untyped'><value>x</value></field>
      <field type='nonsense' var='odd'/>
      <field type='text-single'><value>no name, not fixed</value></field>
    </x>
    """

    @Test func everyFieldTypeIsRead() throws {
        let form = try parse(everyType)
        #expect(form.type == .form)
        #expect(form.title == "Add a user")
        #expect(form.instructions == ["Fill it in.", "Carefully."])
        // The nameless text-single field can't be answered and is dropped.
        #expect(form.fields.map(\.type) == [
            .hidden, .fixed, .textSingle, .textPrivate, .textMulti, .boolean, .jidSingle, .jidMulti, .listSingle, .listMulti, .textSingle, .textSingle,
        ])
        let name = form.fields[2]
        #expect(name.name == "name" && name.label == "Name" && name.desc == "Their name" && name.required && name.value == "Ann")
        #expect(form.fields[1].name == nil)
        #expect(form.fields[4].values == ["one", "two"] && form.fields[4].text == "one\ntwo")
        #expect(form.fields[5].boolValue)
        #expect(form.fields[9].options.map(\.value) == ["a", "b", "c"])
        #expect(form.fields[8].options.map(\.title) == ["Moderator", "user"])
        // An unknown or missing type is text-single.
        #expect(form.fields[10].type == .textSingle && form.fields[11].type == .textSingle)
        #expect(form.fields[0].isEditable == false && form.fields[1].isEditable == false && name.isEditable)
    }

    @Test func aFormThatIsNotADataFormIsNil() throws {
        #expect(XDataForm(try #require(Element.from(string: "<x xmlns='other'/>"))) == nil)
        #expect(XDataForm(try #require(Element.from(string: "<y xmlns='jabber:x:data'/>"))) == nil)
    }

    @Test func aMediaElementIsIgnored() throws {
        let form = try parse("""
        <x xmlns='jabber:x:data' type='form'><field type='text-single' var='captcha'>
          <media xmlns='urn:xmpp:media-element'><uri type='image/png'>https://example.org/c.png</uri></media>
        </field></x>
        """)
        #expect(form.fields.count == 1)
        #expect(form.fields[0].values.isEmpty && form.fields[0].options.isEmpty)
    }

    @Test func aResultTableHasColumnsAndRows() throws {
        let form = try parse("""
        <x xmlns='jabber:x:data' type='result'>
          <reported><field var='jid' label='Address' type='jid-single'/><field var='n' label='Count'/></reported>
          <item><field var='jid'><value>a@b.c</value></field><field var='n'><value>3</value></field></item>
          <item><field var='jid'><value>d@e.f</value></field></item>
        </x>
        """)
        #expect(form.type == .result)
        #expect(form.reported?.map(\.name) == ["jid", "n"])
        #expect(form.reported?.first?.label == "Address")
        #expect(form.items.count == 2)
        #expect(form.items[0].map(\.value) == ["a@b.c", "3"])
        #expect(form.items[1].count == 1)
        #expect(try parse("<x xmlns='jabber:x:data' type='result'/>").reported == nil)
    }

    @Test func theSubmissionAnswersEveryNamedFieldButFixedOnes() throws {
        var form = try parse(everyType)
        form.fields[3].value = "hunter2"
        form.fields[5].boolValue = false
        form.fields[9].setSelected("a", true)
        let sent = form.submission()
        #expect(sent.getAttribute("type") == "submit")
        #expect(sent.xmlns == "jabber:x:data")
        let fields = sent.filterChildren(name: "field", xmlns: nil)
        func values(_ name: String) -> [String]? {
            fields.first { $0.getAttribute("var") == name }?.filterChildren(name: "value", xmlns: nil).map { $0.value ?? "" }
        }
        // The fixed field and the one without a name are not sent.
        #expect(fields.count == 11)
        #expect(values("FORM_TYPE") == ["http://jabber.org/protocol/admin"])
        #expect(values("name") == ["Ann"])
        #expect(values("secret") == ["hunter2"])
        #expect(values("bio") == ["one", "two"])
        #expect(values("admin") == ["0"])
        #expect(values("owner") == ["a@b.c/r"])
        #expect(values("others") == ["a@b.c", "d@e.f"])
        #expect(values("role") == ["mod"])
        #expect(values("tags") == ["a", "b"])
    }

    @Test func anEmptyFieldSendsNoValueAndAnUnsetBooleanSendsNo() throws {
        let form = XDataForm(fields: [
            .init(name: "a", type: .textSingle, values: [""]), .init(name: "b", type: .boolean), .init(name: "c", type: .listMulti),
        ])
        let fields = form.submission().filterChildren(name: "field", xmlns: nil)
        #expect(fields[0].firstChild(name: "value") == nil)
        #expect(fields[1].firstChild(name: "value")?.value == "0")
        #expect(fields[2].firstChild(name: "value") == nil)
    }

    @Test func valueHelpersConvert() {
        var field = XDataForm.Field(name: "x", type: .boolean)
        #expect(!field.boolValue)
        field.values = ["TRUE"]
        #expect(field.boolValue)
        field.values = ["1"]
        #expect(field.boolValue)
        field.boolValue = true
        #expect(field.values == ["1"])
        field.boolValue = false
        #expect(field.values == ["0"] && !field.boolValue)
        field.values = ["yes"]
        #expect(!field.boolValue)

        var text = XDataForm.Field(name: "t", type: .textMulti)
        text.text = "a\n\nb"
        #expect(text.values == ["a", "", "b"])
        text.text = ""
        #expect(text.values.isEmpty)

        var single = XDataForm.Field(name: "s")
        single.value = "v"
        #expect(single.values == ["v"])
        single.value = ""
        #expect(single.values.isEmpty && single.value == "")

        var multi = XDataForm.Field(name: "m", type: .listMulti, options: ["a", "b", "c"].map { .init(value: $0) })
        multi.setSelected("c", true)
        multi.setSelected("a", true)
        #expect(multi.values == ["a", "c"] && multi.isSelected("a") && !multi.isSelected("b"))
        multi.setSelected("a", false)
        #expect(multi.values == ["c"])
    }

    // MARK: Validation

    @Test func requiredFieldsMustHaveAValue() {
        let form = XDataForm(fields: [
            .init(name: "a", required: true), .init(name: "b", required: true, values: ["  "]), .init(name: "c", required: true, values: ["x"]),
            .init(name: "d"), .init(name: "e", type: .boolean, required: true), .init(name: "f", type: .hidden, required: true),
            .init(name: nil, type: .fixed, required: true), .init(name: "g", type: .listMulti, required: true),
        ])
        #expect(form.validationProblems().map(\.index) == [0, 1, 7])
        #expect(form.validationProblems().allSatisfy { $0.reason == .required })
        #expect(form.validationProblems().first?.field == "a")
    }

    @Test func jidFieldsTakeBareAndFullAddresses() {
        for good in ["a@b.c", "a@b.c/res", "b.c", "b.c/res", "a@b.c/with/slash"] {
            #expect(XDataForm(fields: [.init(name: "j", type: .jidSingle, values: [good])]).validationProblems().isEmpty, "\(good)")
        }
        for bad in ["a b@c", "a@", "@b.c", "a@b@c", "a@b.c/", "a@b c/res"] {
            let problems = XDataForm(fields: [.init(name: "j", type: .jidSingle, values: [bad])]).validationProblems()
            #expect(problems.map(\.reason) == [.invalidJID(bad)], "\(bad)")
        }
        let multi = XDataForm(fields: [.init(name: "j", type: .jidMulti, values: ["a@b.c", "nope nope"])])
        #expect(multi.validationProblems().map(\.reason) == [.invalidJID("nope nope")])
        // Not required and empty is fine.
        #expect(XDataForm(fields: [.init(name: "j", type: .jidSingle)]).validationProblems().isEmpty)
    }

    @Test func listValuesMustBeOptions() {
        let options: [XDataForm.Field.Option] = [.init(value: "a"), .init(value: "b")]
        let good = XDataForm(fields: [.init(name: "l", type: .listSingle, values: ["a"], options: options)])
        #expect(good.validationProblems().isEmpty)
        let bad = XDataForm(fields: [.init(name: "l", type: .listSingle, values: ["z"], options: options)])
        #expect(bad.validationProblems().map(\.reason) == [.notAnOption("z")])
        let multi = XDataForm(fields: [.init(name: "l", type: .listMulti, values: ["a", "z"], options: options)])
        #expect(multi.validationProblems().map(\.reason) == [.notAnOption("z")])
        // A list that offers nothing can't be held to it.
        #expect(XDataForm(fields: [.init(name: "l", type: .listSingle, values: ["z"])]).validationProblems().isEmpty)
        for problem in bad.validationProblems() { #expect(!problem.message.isEmpty) }
    }
}
