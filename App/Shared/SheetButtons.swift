import SwiftUI

// Shared with the share extension, so its sheet buttons look as the app's do.

/// A toolbar button drawn as its icon, with the title for VoiceOver and, on
/// the Mac, as a tooltip.
struct SheetIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        let button = Button(action: action) { Label(title, systemImage: systemImage) }
            .labelStyle(.iconOnly)
        if Platform.isMac { button.help(title) } else { button }
    }
}

/// A sheet's Cancel button. On the Mac Esc closes the sheet through it. On
/// iOS 26 and the Mac it is a close icon, as in iOS 26's own sheets: a long
/// translated title between two text buttons gets cut short, and the words
/// looked heavy beside a Mac sheet's title. The word stays as the label
/// VoiceOver reads, and the Mac's tooltip.
struct SheetCancelButton: View {
    let action: () -> Void

    private static var iconToolbar: Bool {
        if #available(iOS 26, *) { true } else { Platform.isMac }
    }

    var body: some View {
        if Self.iconToolbar {
            SheetIconButton(title: "Cancel", systemImage: "xmark", action: action)
                .keyboardShortcut(.cancelAction)
        } else {
            Button("Cancel", action: action)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// A sheet's confirmation button. iOS 18 draws plain tinted text, which must
/// stay that way. iOS 26 shows the system's prominent checkmark and the Mac a
/// checkmark, for the same reasons as `SheetCancelButton`, keeping the word
/// for VoiceOver.
struct SheetConfirmButton: View {
    let title: LocalizedStringKey
    let isBusy: Bool
    let action: () -> Void

    init(_ title: LocalizedStringKey, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isBusy = isBusy
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if isBusy {
            ProgressView()
        } else if Platform.isMac {
            SheetIconButton(title: title, systemImage: "checkmark", action: action)
        } else if #available(iOS 26, *) {
            Button(action: action) { Label(title, systemImage: "checkmark") }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
        } else {
            Button(title, action: action)
        }
    }
}
