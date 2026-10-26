import SwiftUI

/// A settings row that acts rather than opens a page: a plain button or link
/// draws its whole label in the tint, and a destructive one in red. Every row
/// keeps a mauve icon instead, with black or white text, or red for one that
/// removes something.
struct RowLabelStyle: LabelStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title.foregroundStyle(isDestructive ? Color.red : Color.primary)
        } icon: {
            configuration.icon.foregroundStyle(Color.accentColor)
        }
        // The list's own layout, and not this style again.
        .labelStyle(.automatic)
    }
}

extension LabelStyle where Self == RowLabelStyle {
    static var row: Self { RowLabelStyle() }
    static var destructiveRow: Self { RowLabelStyle(isDestructive: true) }
}
