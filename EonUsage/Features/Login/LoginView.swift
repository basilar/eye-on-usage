import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !model.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-mail address", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                } header: {
                    Text("E.ON online ügyfélszolgálat")
                } footer: {
                    Text("The same e-mail and password you use at e-portal.eon-hungaria.com. They are kept in this device's keychain and sent only to E.ON.")
                }

                if let message = model.statusMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if model.isWorking {
                                ProgressView()
                            } else {
                                Text("Sign in").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }

                Section {
                    Button("Explore with sample data") {
                        model.enterDemoMode()
                    }
                    .disabled(model.isWorking)
                } footer: {
                    Text("Shows a simulated household with a rooftop inverter, so you can see the charts before signing in.")
                }
            }
            .navigationTitle("Electricity")
            .safeAreaInset(edge: .top) { header }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.consumption, Palette.consumption.opacity(0.15))
            Text("Quarter-hourly consumption and feed-in from your E.ON remote-reading portal.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Stated on the first screen, not buried in Settings: this is an independent
            // client for your own account, and it should say so before you type a password
            // into it.
            Text("An independent app. Not affiliated with, or endorsed by, E.ON Hungária.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 2)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task { await model.signIn(email: email, password: password) }
    }
}

#Preview {
    LoginView().environment(AppModel())
}
