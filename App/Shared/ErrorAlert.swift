import SwiftUI

extension Binding where Value == Bool {
    /// True while `value` is set. Dismissing clears it.
    init<Wrapped>(isPresent value: Binding<Wrapped?>) {
        self.init(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

extension View {
    /// An OK-only alert shown while `message` is set, and clearing it on dismiss.
    func errorAlert(_ title: LocalizedStringKey, _ message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(isPresent: message)) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
