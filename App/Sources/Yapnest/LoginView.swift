import SwiftUI
import YapnestKit

struct LoginView: View {
    @Environment(AppModel.self) private var model

    @State private var address = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = ""
    @State private var disableTLS = false
    @State private var showsAdvanced = false
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var width: CGFloat = 0

    private var jid: JID? {
        JID(userAddress: address.trimmingCharacters(in: .whitespaces))
    }

    private var canSignIn: Bool { jid != nil && !password.isEmpty && isPortValid && !isSigningIn }

    private var portNumber: Int? { Int(port) }
    // A bad port that's hidden must not block Sign In, as it isn't applied either.
    private var isPortValid: Bool { !showsAdvanced || port.isEmpty || portNumber.map { (1...65535).contains($0) } ?? false }

    /// Explains a disabled Sign In button.
    private var inputProblem: String? {
        if !address.isEmpty && jid == nil { return "Enter a full address, like you@example.org." }
        if !isPortValid { return "Port must be a number between 1 and 65535." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image("LoginIcon")
                            .resizable()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 88 * 0.22, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            .accessibilityHidden(true)
                        Text("Yapnest")
                            .font(.largeTitle.bold())
                        Text("Sign in with your XMPP account.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if model.pendingLink != nil {
                    Section {
                        Label("Sign in to open the link you tapped.", systemImage: "link")
                    }
                }
                Section {
                    TextField("you@example.org", text: $address)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                } footer: {
                    if let message = error ?? inputProblem {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Advanced Options", isOn: $showsAdvanced.animation(.easeInOut(duration: 0.2)))
                    if showsAdvanced {
                        TextField("Host (optional)", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                        #if DEBUG
                        Toggle("Disable TLS (dev servers only)", isOn: $disableTLS)
                        #endif
                    }
                } footer: {
                    Text("Only needed if your server isn't found from your address.")
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        // The text stays in place, hidden, so the button keeps its size.
                        Text("Sign In")
                            .opacity(isSigningIn ? 0 : 1)
                            .overlay { if isSigningIn { ProgressView().tint(.white) } }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    // The Mac draws a disabled prominent button as a solid accent pill, so grey it out ourselves.
                    .tint(!canSignIn && !isSigningIn ? Color(.systemGray3) : .accentColor)
                    .disabled(!canSignIn)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            // Margins rather than a max width, so the background and scroll bar still span the window.
            // Nil below the cap keeps the system's own margins, which any number would replace.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentMargins(.horizontal, width > 480 ? (width - 440) / 2 : nil, for: .scrollContent)
            .dismissesKeyboardOnTap()
            .onSubmit {
                if canSignIn { Task { await signIn() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let url = AppLinks.privacyPolicy {
                    Link("Privacy Policy", destination: url)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func signIn() async {
        guard let jid else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        // Hidden values are kept for when the options come back, but aren't applied.
        let trimmedHost = showsAdvanced ? host.trimmingCharacters(in: .whitespaces) : ""
        let credentials = XMPPSession.Credentials(
            jid: jid,
            password: password,
            host: trimmedHost.isEmpty ? nil : trimmedHost,
            port: showsAdvanced ? portNumber : nil,
            disableTLS: showsAdvanced && disableTLS,
        )
        do {
            try await model.signIn(credentials)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    LoginView().environment(AppModel())
}
