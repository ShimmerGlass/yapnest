#if DEBUG
import Foundation
import GRDB
import YapnestKit

/// Right-to-left chats for checking alignment and bidi ordering by eye:
/// `YAPNEST_DEV_FIXTURE=rtl`. Times are relative to the launch, and the
/// Arabic chat is pinned, so the list always reads in the same order.
enum RTLFixture {
    static let layla = JID("layla@fixture.test")!
    static let noa = JID("noa@fixture.test")!
    static let english = JID("english@fixture.test")!
    static let group = JID("rtlgroup@groups.fixture.test")!
    /// The group's two members, with nicknames in Arabic and Hebrew.
    static let rana = JID("rana@fixture.test")!
    static let dan = JID("dan@fixture.test")!

    private static let nickname = "أنا"
    private static let nicks = [rana: "رنا", dan: "דן"]

    static func configure(_ session: XMPPSession) {
        session.joinForFixture(group, occupants: [
            RoomOccupant(nick: nickname, jid: DevFixture.account, affiliation: .member),
            RoomOccupant(nick: "رنا", jid: rana, affiliation: .member),
            RoomOccupant(nick: "דן", jid: dan, affiliation: .member),
        ])
    }

    private typealias Line = DevFixture.Line

    static func fill(_ database: AppDatabase) throws {
        for (jid, name) in [(layla, "ليلى"), (noa, "נועה"), (english, "Emma Clarke"), (rana, "رنا"), (dan, "דן")] {
            try database.updateRosterItem(jid: jid, name: name, subscription: .both, isPending: false)
        }
        try fillLayla(database)
        try fillNoa(database)
        try fillGroup(database)
        try fillEnglish(database)
    }

    private static func chat(_ database: AppDatabase, _ peer: JID) throws -> Conversation {
        try DevFixture.completeChat(database, peer)
    }

    private static func write(_ database: AppDatabase, _ conversation: Conversation, _ lines: [Line]) throws {
        try DevFixture.write(database, conversation, nickname: nickname, nicks: nicks, lines)
    }

    private static func fillLayla(_ database: AppDatabase) throws {
        let conversation = try chat(database, layla)
        try database.setPinned(true, conversationId: conversation.id!)
        try write(database, conversation, [
            // A question ending in "?".
            Line(minutesAgo: 60, from: layla, body: "كيف حالك اليوم؟", id: "l-how"),
            Line(minutesAgo: 58, body: "الحمد لله، بخير. وأنت؟"),
            // Two lines.
            Line(minutesAgo: 55, from: layla, body: "وصلت إلى البيت الآن\nسأنام مبكرا الليلة"),
            // Arabic around a time, and around a number with a noun.
            Line(minutesAgo: 50, body: "سنلتقي في المقهى الساعة 10:30 صباحا"),
            Line(minutesAgo: 48, from: layla, body: "اشتريت 3 كتب من المكتبة اليوم"),
            // Arabic with an English word.
            Line(minutesAgo: 45, body: "هل أرسلت لك الـ email أمس؟"),
            // A URL inside Arabic text.
            Line(minutesAgo: 42, from: layla, body: "هذا هو الموقع https://example.com/ar/books الذي حدثتك عنه"),
            // An English reply quoting Arabic.
            Line(minutesAgo: 38, body: "Sorry, I missed this one. Dinner tonight?",
                 replyTo: (id: "l-how", sender: layla, text: "كيف حالك اليوم؟")),
            // Reactions, from us and from her.
            Line(minutesAgo: 34, from: layla, body: "طبعا، سأحجز طاولة", id: "l-book",
                 reactions: [(DevFixture.account, "👍"), (layla, "❤️")]),
            // An English reply quoting an Arabic message that has reactions.
            Line(minutesAgo: 30, body: "Perfect, see you at eight",
                 replyTo: (id: "l-book", sender: layla, text: "طبعا، سأحجز طاولة")),
            // First strong character LTR, then Arabic.
            Line(minutesAgo: 20, from: layla, body: "WhatsApp أفضل من البريد للرسائل السريعة"),
            // First strong character RTL, then English.
            Line(minutesAgo: 15, body: "أنا أحب Yapnest كثيرا"),
            // The newest, which the chat list previews.
            Line(minutesAgo: 10, from: layla, body: "تصبح على خير، أراك غدا"),
        ])
    }

    private static func fillNoa(_ database: AppDatabase) throws {
        let conversation = try chat(database, noa)
        try write(database, conversation, [
            Line(minutesAgo: 90, from: noa, body: "שלום, מה שלומך?"),
            Line(minutesAgo: 88, body: "הכול טוב, תודה. ומה איתך?"),
            Line(minutesAgo: 85, from: noa, body: "אני *מאוד* שמחה לראות אותך"),
            Line(minutesAgo: 80, body: "הנה הקוד שביקשת:\n```\nfunc add(a: Int, b: Int) -> Int {\n    return a + b\n}\n```"),
            Line(minutesAgo: 75, from: noa, body: "תודה רבה, זה עובד מצוין!"),
            Line(minutesAgo: 5, from: noa, body: "נתראה מחר בבוקר!"),
        ])
    }

    private static func fillGroup(_ database: AppDatabase) throws {
        _ = try database.joinGroupChat(group, nickname: nickname, name: "חברים בבית", isBookmarked: true)
        try database.updateGroupChat(group) { $0.isMembersOnly = true; $0.isNonAnonymous = true }
        let conversation = try chat(database, group)
        try write(database, conversation, [
            Line(minutesAgo: 130, from: rana, body: "مرحبا بالجميع، من سيأتي غدا؟"),
            Line(minutesAgo: 128, from: dan, body: "אני אבוא, מה השעה?"),
            // Mentions a member.
            Line(minutesAgo: 126, body: "@رنا الساعة 6 مساء"),
            Line(minutesAgo: 124, from: rana, body: "ممتاز، أراكم هناك", reactions: [(dan, "👍")]),
            Line(minutesAgo: 120, from: dan, body: "מצוין, נתראה שם"),
        ])
    }

    private static func fillEnglish(_ database: AppDatabase) throws {
        let conversation = try chat(database, english)
        try write(database, conversation, [
            Line(minutesAgo: 200, from: english, body: "Hi! Are we still on for the weekend?"),
            Line(minutesAgo: 198, body: "Yes, see you on Saturday."),
            Line(minutesAgo: 190, from: english, body: "Great. I looked at the schedule again and the first train leaves a little after nine, which gets us there well before lunch, so we can walk around the old town, find somewhere quiet for coffee, and still be back at the station in good time for the evening connection."),
        ])
    }
}
#endif
