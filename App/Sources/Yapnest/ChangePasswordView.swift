import SwiftUI
import YapnestKit

/// Profile > Account > Change Password. The passwords live only in this
/// view's state: they're never logged, and go with the view.
struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var change = ServerAction()
    @State private var didChange = false
    @State private var outcomeUnknown = false

    private var problem: XMPPSession.PasswordProblem? {
        XMPPSession.passwordProblem(current: current, new: new, confirmation: confirmation)
    }

    /// Only what the person has run into: a field still empty is no error yet.
    private var shownProblem: XMPPSession.PasswordProblem? {
        switch problem {
        case .mismatch where !confirmation.isEmpty: .mismatch
        case .unchanged: .unchanged
        default: nil
        }
    }

    var body: some View {
        Form {
            Section {
                SecureField("Current Password", text: $current)
                    .textContentType(.password)
                SecureField("New Password", text: $new)
                    .textContentType(.newPassword)
                SecureField("Confirm New Password", text: $confirmation)
                    .textContentType(.newPassword)
                    .submitLabel(.done)
                    .onSubmit(save)
                if let shownProblem {
                    Text(shownProblem.message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("passwordProblem")
                }
            } footer: {
                Text("Your other devices will need the new password.")
            }
            .disabled(change.isBusy)
        }
        .dismissesKeyboardOnTap()
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SheetConfirmButton("Save", isBusy: change.isBusy, action: save)
                    .disabled(problem != nil)
            }
        }
        .actionAlert("Couldn't change the password", change)
        .alert("Password may have changed", isPresented: $outcomeUnknown) {
            Button("OK") { dismiss() }
        } message: {
            Text(XMPPSession.PasswordError.outcomeUnknown.errorDescription ?? "")
        }
        .alert("Password changed", isPresented: $didChange) {
            Button("OK") { dismiss() }
        } message: {
            Text("Use the new password on your other devices.")
        }
    }

    private func save() {
        guard problem == nil else { return }
        let (current, new) = (current, new)
        change.run { [model] in
            do {
                try await model.changePassword(current: current, new: new)
                didChange = true
            } catch XMPPSession.PasswordError.outcomeUnknown {
                // Not a failure: it is told apart so it isn't called one.
                outcomeUnknown = true
            }
        }
    }
}
