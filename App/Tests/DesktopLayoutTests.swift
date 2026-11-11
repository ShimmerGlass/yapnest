import SwiftUI
import Testing
import YapnestKit
@testable import Yapnest

struct DesktopLayoutTests {
    @Test func theMacAlwaysUsesIt() {
        for sizeClass in [UserInterfaceSizeClass.regular, .compact, nil] {
            #expect(Platform.usesDesktopLayout(isMac: true, isPad: false, sizeClass: sizeClass))
        }
    }

    @Test func anIPadUsesItInAWideWindowOnly() {
        #expect(Platform.usesDesktopLayout(isMac: false, isPad: true, sizeClass: .regular))
        #expect(!Platform.usesDesktopLayout(isMac: false, isPad: true, sizeClass: .compact))
        #expect(!Platform.usesDesktopLayout(isMac: false, isPad: true, sizeClass: nil))
    }

    @Test func aPhoneNeverUsesIt() {
        for sizeClass in [UserInterfaceSizeClass.regular, .compact, nil] {
            #expect(!Platform.usesDesktopLayout(isMac: false, isPad: false, sizeClass: sizeClass))
        }
    }
}

/// An iPad window that turns narrow or wide opens on the chat the other
/// layout showed, and in Archived Chats if that's where it was.
struct ChatNavigationTests {
    private let lea = JID("lea@example.org")!
    private let sam = JID("sam@example.org")!

    @Test func theStackPushesTheChatBesideTheList() {
        var navigation = ChatNavigation(path: [.conversation(sam)], sidebarPath: [], selection: lea, selectedMessage: 7)
        navigation.followSplit()
        #expect(navigation.path == [.conversation(lea, at: 7)])
    }

    @Test func theStackIsEmptyWithNoChatBesideTheList() {
        var navigation = ChatNavigation(path: [.conversation(sam)], sidebarPath: [], selection: nil)
        navigation.followSplit()
        #expect(navigation.path.isEmpty)
    }

    @Test func theStackKeepsArchivedChatsUnderTheChat() {
        var navigation = ChatNavigation(path: [], sidebarPath: [.archive], selection: lea)
        navigation.followSplit()
        #expect(navigation.path == [.archive, .conversation(lea)])
    }

    @Test func theSplitShowsTheChatOnTopOfTheStack() {
        var navigation = ChatNavigation(path: [.archive, .conversation(sam, at: 3)], sidebarPath: [], selection: lea)
        navigation.followStack()
        #expect(navigation.selection == sam)
        #expect(navigation.selectedMessage == 3)
        #expect(navigation.sidebarPath == [.archive])
    }

    @Test func theSplitHasNoChatWhenTheStackShowsTheList() {
        var navigation = ChatNavigation(path: [], sidebarPath: [.archive], selection: lea, selectedMessage: 3)
        navigation.followStack()
        #expect(navigation.selection == nil)
        #expect(navigation.selectedMessage == nil)
        #expect(navigation.sidebarPath.isEmpty)
    }

    @Test func archivedChatsWithNoChatOpenStayInTheSidebar() {
        var navigation = ChatNavigation(path: [.archive], sidebarPath: [], selection: lea)
        navigation.followStack()
        #expect(navigation.selection == nil)
        #expect(navigation.sidebarPath == [.archive])
    }
}
