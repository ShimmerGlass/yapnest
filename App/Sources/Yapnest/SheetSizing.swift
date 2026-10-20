import SwiftUI

extension View {
    /// Gives a sheet room on the Mac. Catalyst sizes a sheet to its content,
    /// and a form in a navigation stack reports almost none, so it opens as
    /// a narrow strip. iOS ignores this: its sheets already fill the screen
    /// or the iPad's form sheet. The minimum rather than a fixed size lets
    /// the sheet grow with its content, which `presentationSizing` doesn't.
    @ViewBuilder
    func sheetSizedForMac(width: CGFloat = 480, height: CGFloat = 600) -> some View {
        if Platform.isMac {
            frame(minWidth: width, minHeight: height)
        } else {
            self
        }
    }
}
