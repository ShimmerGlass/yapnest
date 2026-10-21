import XCTest

/// What a group's owner is offered for its members and their messages, and
/// that a plain member is offered none of it. The fixture has four groups: one
/// where we own the room, one where we're an administrator, one where we're an
/// ordinary member and one without a name, and a session
/// that never connects, so acting on the server fails with "You're offline."
@MainActor
final class GroupModerationUITests: XCTestCase {
    private let owned = "owned@groups.fixture.test"
    private let joined = "joined@groups.fixture.test"
    private let administered = "admin@groups.fixture.test"

    private var driver: ConversationDriver!

    private func open(_ room: String) -> XCUIApplication {
        continueAfterFailure = false
        driver = ConversationDriver(fixture: "moderation", open: room, context: "group moderation")
        driver.waitForOpenChat()
        driver.settle()
        return driver.app
    }

    private func openMembers(of room: String) -> XCUIApplication {
        let app = open(room)
        driver.openChatSettings(title: "Group Settings")
        XCTAssertTrue(app.collectionViews.staticTexts["anna"].firstMatch.waitForExistence(timeout: 10), "the members didn't show")
        return app
    }

    private func button(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[name].firstMatch
    }

    private func openMenu(of member: String, in app: XCUIApplication) {
        let row = app.collectionViews.staticTexts[member].firstMatch
        // The settings' header pushes the later members below the fold, where
        // the list hasn't drawn them yet.
        var swipes = 0
        while !row.exists, swipes < 3 {
            app.collectionViews.firstMatch.swipeUp()
            swipes += 1
        }
        row.press(forDuration: 1.0)
    }

    // MARK: Members

    func testAnOwnerCanModerateAMember() {
        let app = openMembers(of: owned)
        openMenu(of: "anna", in: app)
        XCTAssertTrue(button("Remove from Group", in: app).waitForExistence(timeout: 5), "no way to remove a member")
        XCTAssertTrue(button("Ban from Group", in: app).exists, "no way to ban a member")
        XCTAssertTrue(button("Make Admin", in: app).exists, "an owner can't make an admin")
        XCTAssertFalse(button("Remove Admin", in: app).exists, "anna isn't an admin")
    }

    func testAnOwnerCanUnmakeAnAdminButNotMakeOneAgain() {
        let app = openMembers(of: owned)
        openMenu(of: "ben", in: app)
        XCTAssertTrue(button("Remove Admin", in: app).waitForExistence(timeout: 5), "no way to unmake an admin")
        XCTAssertFalse(button("Make Admin", in: app).exists, "ben is an admin already")
        XCTAssertTrue(button("Remove from Group", in: app).exists)
    }

    func testNobodyOffersToActOnThemselves() {
        let app = openMembers(of: owned)
        openMenu(of: "You", in: app)
        XCTAssertFalse(button("Remove from Group", in: app).waitForExistence(timeout: 2), "the menu offers removing yourself")
        XCTAssertFalse(button("Ban from Group", in: app).exists)
    }

    func testAPlainMemberIsOfferedNothing() {
        let app = openMembers(of: joined)
        openMenu(of: "anna", in: app)
        XCTAssertFalse(button("Remove from Group", in: app).waitForExistence(timeout: 2), "a plain member is offered removing someone")
        XCTAssertFalse(button("Ban from Group", in: app).exists, "a plain member is offered banning someone")
        XCTAssertFalse(button("Make Admin", in: app).exists, "a plain member is offered making an admin")
    }

    func testRemovingAsksFirstAndReportsAFailure() {
        let app = openMembers(of: owned)
        openMenu(of: "anna", in: app)
        button("Remove from Group", in: app).tap()

        let confirm = app.alerts["Remove anna?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "removing wasn't confirmed first")
        confirm.buttons["Remove"].tap()

        let failure = app.alerts["Couldn't change the group"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), "a refused removal wasn't reported")
        XCTAssertTrue(failure.staticTexts["You're offline."].exists, "the reason is missing")
        failure.buttons["OK"].tap()
        XCTAssertTrue(app.collectionViews.staticTexts["anna"].firstMatch.exists, "anna left the list though the room never accepted")
    }

    func testBanningAsksFirstAndCanBeCancelled() {
        let app = openMembers(of: owned)
        openMenu(of: "anna", in: app)
        button("Ban from Group", in: app).tap()

        let confirm = app.alerts["Ban anna?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "banning wasn't confirmed first")
        confirm.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts["Couldn't change the group"].waitForExistence(timeout: 2), "cancelling still went to the server")
    }

    func testAnOwnerCanKickAndMakeOwnersAndKickingAsksFirst() {
        let app = openMembers(of: owned)
        openMenu(of: "anna", in: app)
        XCTAssertTrue(button("Make Owner", in: app).waitForExistence(timeout: 5), "an owner can't make an owner")
        XCTAssertTrue(button("Kick from Group", in: app).exists, "no way to kick someone who is here")
        button("Kick from Group", in: app).tap()
        let confirm = app.alerts["Kick anna?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "kicking wasn't confirmed first")
        confirm.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts["Couldn't change the group"].waitForExistence(timeout: 2), "cancelling still went to the server")
    }

    func testAnOwnerCanRemoveAnotherOwnersOwnership() {
        let app = openMembers(of: owned)
        openMenu(of: "cara", in: app)
        XCTAssertTrue(button("Remove Ownership", in: app).waitForExistence(timeout: 5), "no way to take ownership away")
        XCTAssertFalse(button("Make Owner", in: app).exists, "cara is an owner already")
    }

    func testAnAdminCannotMakeOwnersButCanKickAndSeeBans() {
        let app = openMembers(of: administered)
        openMenu(of: "anna", in: app)
        XCTAssertTrue(button("Remove from Group", in: app).waitForExistence(timeout: 5), "the admin's menu didn't open")
        XCTAssertFalse(button("Make Owner", in: app).exists, "an admin can make owners")
        XCTAssertFalse(button("Make Admin", in: app).exists, "an admin can make admins")
        XCTAssertTrue(button("Kick from Group", in: app).exists, "an admin can't kick a member")
    }

    // MARK: Group management

    func testTheBannedListNamesWhoIsBanned() {
        let app = openMembers(of: owned)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Banned")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Banned row for an owner")
        row.tap()
        XCTAssertTrue(app.navigationBars["Banned"].waitForExistence(timeout: 5), "the banned list didn't open")
        XCTAssertTrue(app.staticTexts["dora@fixture.test"].waitForExistence(timeout: 5), "the banned member isn't listed")
        // Offline, the fixture can't ask the room for its list.
        let failure = app.alerts["Couldn't load the banned list"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), "a failed load wasn't reported")
        failure.buttons["OK"].tap()
        app.staticTexts["dora@fixture.test"].firstMatch.press(forDuration: 1.0)
        XCTAssertTrue(button("Unban", in: app).waitForExistence(timeout: 5), "no way to lift a ban")
    }

    func testAPlainMemberSeesNoBannedList() {
        let app = openMembers(of: joined)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Banned")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Edit"].exists, "a plain member can edit the group")
        XCTAssertFalse(app.buttons["Delete Group"].exists)
    }

    func testOnlyAnOwnerCanDeleteTheGroupAndIsAskedFirst() {
        let app = openMembers(of: owned)
        for _ in 0..<4 where !app.buttons["Delete Group"].exists { app.collectionViews.firstMatch.swipeUp() }
        let delete = app.buttons["Delete Group"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "an owner can't delete the group")
        delete.tap()
        let confirm = app.buttons["Delete Group"].firstMatch
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "for everyone")).firstMatch.waitForExistence(timeout: 5),
                      "deleting wasn't explained first")
        XCTAssertTrue(confirm.exists)
        // The dialog has no Cancel on a phone: a tap outside closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertFalse(app.alerts["Couldn't delete group"].waitForExistence(timeout: 2), "dismissing still went to the server")
    }

    func testAnAdminCannotDeleteTheGroupOrEditItsName() {
        let app = openMembers(of: administered)
        // An admin moderates, so they may set the subject, and nothing more.
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Group"].waitForExistence(timeout: 5), "the edit sheet didn't open")
        XCTAssertTrue(app.textFields["Subject"].waitForExistence(timeout: 5), "an admin can't set the subject")
        XCTAssertFalse(app.textFields["Name"].exists, "an admin can rename the group")
        app.buttons["Cancel"].tap()
        for _ in 0..<4 { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertFalse(app.buttons["Delete Group"].exists, "an admin can delete the group")
    }

    func testTheEditSheetOpensWithTheNameAndSurvivesAFailedLoad() {
        let app = openMembers(of: owned)
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Group"].waitForExistence(timeout: 5), "the edit sheet didn't open")
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no name field")
        XCTAssertEqual(name.value as? String, "Owned", "the name isn't prefilled")
        // Offline, the room's options can't be read; the sheet says so and carries on.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The group's options couldn't be read")).firstMatch
            .waitForExistence(timeout: 10), "a failed load wasn't shown")
        XCTAssertTrue(app.buttons["Try Again"].exists)
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Save is on with nothing changed")
        name.tap()
        name.typeText("er")
        XCTAssertTrue(app.buttons["Save"].isEnabled, "a changed name can't be saved")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Group Settings"].waitForExistence(timeout: 5), "Cancel didn't return to the settings")
    }

    func testAnUnnamedGroupCanBeEditedWithoutBeingRenamed() {
        let app = open("unnamed@groups.fixture.test")
        driver.openChatSettings(title: "Group Settings")
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Group"].waitForExistence(timeout: 5), "the edit sheet didn't open")
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5), "no name field")
        // The address's short name is only a placeholder, not a name to save.
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Save is on with nothing changed")
        let subject = app.textFields["Subject"]
        subject.tap()
        subject.typeText("Hi")
        XCTAssertTrue(app.buttons["Save"].isEnabled, "a changed subject can't be saved")
    }

    // MARK: Messages

    func testAModeratorCanRemoveAnotherMembersMessageForEveryone() {
        let app = open(owned)
        driver.openMenu(on: app.staticTexts["Moderate this message."].firstMatch, "Moderate this message.")
        let remove = button("Remove for Everyone", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "no Remove for Everyone in the menu")
        XCTAssertFalse(button("Delete for Everyone", in: app).exists, "someone else's message offers the author's deletion")
        remove.tap()

        // The dialog asks before the room is.
        let confirm = app.buttons["Remove for Everyone"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "removing wasn't confirmed first")
        confirm.tap()

        let failure = app.alerts["Something went wrong"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), "a refused removal wasn't reported")
        XCTAssertTrue(failure.staticTexts["You're offline."].exists, "the reason is missing")
    }

    func testOurOwnMessageIsDeletedNotModerated() {
        let app = open(owned)
        driver.openMenu(on: app.staticTexts["My own words."].firstMatch, "My own words.")
        XCTAssertTrue(button("Delete for Everyone", in: app).waitForExistence(timeout: 5), "no Delete for Everyone on our own message")
        XCTAssertFalse(button("Remove for Everyone", in: app).exists, "our own message is offered to a moderator's removal")
    }

    func testAPlainMemberCannotRemoveMessagesForEveryone() {
        let app = open(joined)
        driver.openMenu(on: app.staticTexts["Moderate this message."].firstMatch, "Moderate this message.")
        XCTAssertTrue(button("Reply", in: app).waitForExistence(timeout: 5), "the menu didn't open")
        XCTAssertFalse(button("Remove for Everyone", in: app).exists, "a plain member can remove others' messages")
    }
}
