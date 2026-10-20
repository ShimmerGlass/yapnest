import Testing
import UIKit
import YapnestKit
@testable import Yapnest

/// The composer's text, as the model keeps it: the stored draft, what an edit
/// displaces, and what only the user's typing may change.
@MainActor
struct ConversationDraftTests {
    private func attach(_ f: ConversationFixture) -> ConversationInputBar {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        // As the composer view wires it.
        bar.onTextChanged = { [weak model = f.model] text in model?.textChanged(text) }
        f.model.composer.bar = bar
        f.model.composerAttached()
        return bar
    }

    private func storedDraft(_ f: ConversationFixture) async throws -> String? {
        await DraftWriter.shared.settled()
        return try f.database.draft(peer: f.peer)
    }

    @Test func aStoredDraftIsOfferedOnceAndNotWrittenBack() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("see you at 8", peer: f.peer)
        try f.addMany(2)
        let bar = attach(f)
        await f.start()

        #expect(bar.text == "see you at 8")
        // It's already stored, and putting it there wasn't typing.
        #expect(DraftWriter.shared.pending(for: f.peer) == nil)

        // The user clears it; a composer made again later doesn't bring it back.
        bar.setText("", notify: true)
        let again = attach(f)
        #expect(again.text.isEmpty)
    }

    @Test func aStoredDraftNeverReplacesWhatTheUserAlreadyTyped() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("old draft", peer: f.peer)
        let bar = attach(f)
        bar.setText("typed first", notify: true)
        await f.start()
        #expect(bar.text == "typed first")
    }

    @Test func aDraftStillBeingWrittenBeatsTheStoredOne() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("stale", peer: f.peer)
        DraftWriter.shared.note("typed a moment ago", for: f.peer)
        let bar = attach(f)
        await f.start()
        #expect(bar.text == "typed a moment ago")
    }

    @Test func aDraftArrivesIfTheComposerAppearsAfterTheChatLoaded() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("later", peer: f.peer)
        await f.start()
        #expect(attach(f).text == "later")
    }

    @Test func clearingARestoredDraftRemovesItFromTheDatabase() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("to be cleared", peer: f.peer)
        let bar = attach(f)
        await f.start()
        f.model.setOnScreen(true)

        bar.setText("", notify: true)
        f.model.setOnScreen(false)
        #expect(try await storedDraft(f)?.isEmpty != false)
    }

    @Test func typingIsSavedAsTheDraftWhenTheUserLeaves() async throws {
        let f = try ConversationFixture()
        let bar = attach(f)
        await f.start()
        bar.setText("half a thought", notify: true)
        f.model.setOnScreen(false)
        #expect(try await storedDraft(f) == "half a thought")
    }

    @Test func aComposerMadeAgainIsGivenBackWhatWasTyped() async throws {
        let f = try ConversationFixture()
        let first = attach(f)
        await f.start()
        first.setText("still typing", notify: true)
        #expect(attach(f).text == "still typing")
    }

    @Test func editingKeepsTheDraftAndCancellingBringsItBack() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo here", .outgoing)
        let bar = attach(f)
        await f.start()
        f.model.setOnScreen(true)
        bar.setText("half typed", notify: true)

        f.model.startEditing(mine.id!)
        #expect(bar.text == "typo here")
        #expect(f.model.editingItem?.id == mine.id)

        // Typing into the edit is not a draft.
        bar.setText("typo fixed", notify: true)
        f.model.setOnScreen(false)
        #expect(try await storedDraft(f) != "typo fixed")

        f.model.cancelReplyOrEdit()
        #expect(f.model.editingItem == nil)
        #expect(bar.text == "half typed")
        #expect(try await storedDraft(f) == "half typed")
    }

    @Test func cancellingAnEditWithNothingTypedBeforeLeavesTheComposerEmpty() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo here", .outgoing)
        let bar = attach(f)
        await f.start()
        f.model.startEditing(mine.id!)
        f.model.cancelReplyOrEdit()
        #expect(bar.text.isEmpty)
    }

    @Test func cancellingAnEditBegunBeforeTheComposerExistedOffersTheStoredDraft() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo here", .outgoing)
        try f.database.setDraft("stored", peer: f.peer)
        await f.start()
        f.model.startEditing(mine.id!)
        let bar = attach(f)
        #expect(bar.text == "typo here")
        f.model.cancelReplyOrEdit()
        #expect(bar.text == "stored")
    }

    @Test func aComposerMadeAgainDuringAnEditShowsTheEditedText() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo here", .outgoing)
        _ = attach(f)
        await f.start()
        f.model.startEditing(mine.id!)
        #expect(attach(f).text == "typo here")
    }

    @Test func aStoredDraftIsNotOfferedOverAnEdit() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo here", .outgoing)
        try f.database.setDraft("stored", peer: f.peer)
        await f.start()
        f.model.startEditing(mine.id!)
        #expect(attach(f).text == "typo here")
    }

    @Test func sendingClearsTheComposerAndTheStoredDraft() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("hello", peer: f.peer)
        let bar = attach(f)
        await f.start()
        #expect(bar.text == "hello")

        f.model.send(bar.text)
        #expect(bar.text.isEmpty)
        #expect(try await storedDraft(f)?.isEmpty != false)
        await eventually("the message never showed") { f.model.rows.last?.message.body == "hello" }
    }
}

/// A link's body going into the composer of the chat that is already open.
@MainActor
struct ConversationPrefillTests {
    private func attach(_ f: ConversationFixture) -> ConversationInputBar {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        bar.onTextChanged = { [weak model = f.model] text in model?.textChanged(text) }
        f.model.composer.bar = bar
        f.model.composerAttached()
        return bar
    }

    @Test func theBodyGoesBelowWhatIsAlreadyThere() {
        #expect(ConversationModel.composerText(adding: "hi", to: "") == "hi")
        #expect(ConversationModel.composerText(adding: "hi", to: "typed") == "typed\nhi")
    }

    @Test func anEmptyComposerShowsTheBodyAndSavesItAsTheDraft() async throws {
        let f = try ConversationFixture()
        let bar = attach(f)
        await f.start()
        f.model.prefill("hello there")
        #expect(bar.text == "hello there")
        // Noted as the draft, so leaving the chat writes the body and not the old text.
        #expect(DraftWriter.shared.pending(for: f.peer) == "hello there")
        await eventually("the draft is saved") { (try? f.database.draft(peer: f.peer)) == "hello there" }
    }

    @Test func aBodyArrivingBeforeTheStoredDraftGoesBelowIt() async throws {
        let f = try ConversationFixture()
        try f.database.setDraft("first", peer: f.peer)
        let bar = attach(f)
        f.model.prefill("second")
        await f.start()
        #expect(bar.text == "first\nsecond")
    }

    @Test func aChatThatIsAliveIsFoundWhetherOrNotItIsOnScreen() async throws {
        let f = try ConversationFixture()
        let live = LiveConversations()
        live.register(f.model)
        f.model.setOnScreen(false)
        #expect(live.model(for: f.peer) === f.model)
    }

    @Test func aChatThatWasReleasedTakesNothing() async throws {
        let live = LiveConversations()
        var peer: JID?
        do {
            let f = try ConversationFixture()
            peer = f.peer
            live.register(f.model)
        }
        // The fixture's model is released with it.
        #expect(live.model(for: try #require(peer)) == nil)
    }

    @Test func textAlreadyTypedStaysAboveTheBody() async throws {
        let f = try ConversationFixture()
        let bar = attach(f)
        await f.start()
        bar.setText("see you", notify: true)
        f.model.prefill("at 8")
        #expect(bar.text == "see you\nat 8")
    }
}

@MainActor
struct JoinGroupLinkTests {
    @Test func aRoomFromALinkMustAlreadyExist() throws {
        let room = try #require(JID("room@conference.example.org"))
        let other = try #require(JID("other@conference.example.org"))
        #expect(!JoinGroupView.mayCreate(room, linkRoom: room))
        #expect(JoinGroupView.mayCreate(other, linkRoom: room))
        #expect(JoinGroupView.mayCreate(room, linkRoom: nil))
    }
}

/// The composer's emoji order loads after it appears.
@MainActor
struct ComposerEmojiOrderTests {
    @Test func aPickMadeBeforeTheOrderLoadedStaysAtTheFront() {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        bar.recordRecent("🪺")
        bar.setEmojiOrder(["😀", "🪺", "👍"])
        #expect(bar.emojiOrder == ["🪺", "😀", "👍"])
        bar.recordRecent("👍")
        #expect(bar.emojiOrder == ["👍", "🪺", "😀"])
    }
}
