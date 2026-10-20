import SwiftUI

extension View {
    /// An OK-only alert shown while `message` is set, and clearing it on dismiss.
    func errorAlert(_ title: LocalizedStringKey, _ message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
