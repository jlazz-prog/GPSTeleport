import SwiftUI

struct RefreshScreen: View {
    @EnvironmentObject private var spoof: SpoofController
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var refresher: AppRefresher
    @AppStorage(AppRefresher.emailKey) private var email = ""
    @State private var password = ""
    @State private var refreshesAutomatically = SavedPassword.exists
    @State private var code = ""
    @State private var notificationsAllowed = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let timeLeft = AppExpiry.timeLeftDescription, let date = AppExpiry.date {
                        LabeledContent("Stops opening", value: timeLeft)
                        LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Couldn't read this install's expiry date.")
                            .foregroundStyle(.secondary)
                    }
                    if !notificationsAllowed {
                        Text("Reminders are off. Turn on notifications for GPS Teleport in Settings to get one before this runs out.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("You'll get a reminder 2 days, 1 day and 4 hours before this date. Refresh before then: once it runs out, the app won't open and you'll need a PC to reinstall it.")
                }

                Section {
                    TextField("Apple ID", text: $email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Toggle("Refresh automatically", isOn: $refreshesAutomatically)
                        .onChange(of: refreshesAutomatically) {
                            if !refreshesAutomatically { SavedPassword.delete() }
                        }
                } header: {
                    Text("Apple ID")
                } footer: {
                    Text("Use the Apple ID you installed GPS Teleport with. Your password is used only to sign in to Apple, and sign-in also uses the anisette server ani.iloader.app, the one iloader uses by default.\n\nAutomatic refresh saves your password in this iPhone's Keychain. Once you've refreshed here with it on, opening the app with less than 3 days left refreshes it if LocalDevVPN is on and you aren't spoofing. The app closes when it finishes.")
                }

                Section {
                    Button(action: start) {
                        Label("Refresh now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canStart)

                    if spoof.isActive {
                        Text("Stop spoofing first. Refreshing closes the app, which would end it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    statusView
                } footer: {
                    Text("Turn on LocalDevVPN first. GPS Teleport closes when it finishes, so just open it again.")
                }
            }
            .navigationTitle("Refresh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(refresher.isRunning)
                }
            }
            .interactiveDismissDisabled(refresher.isRunning)
            .alert(codeTitle, isPresented: showCodePrompt) {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                Button("Submit") { answer(code) }
                Button("Text me instead") {
                    code = ""
                    refresher.requestSMS()
                }
                Button("Cancel", role: .cancel) { answer(nil) }
            } message: {
                Text(codeMessage)
            }
            .task {
                if password.isEmpty, let saved = SavedPassword.load() { password = saved }
                notificationsAllowed = await AppExpiry.notificationsAllowed()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch refresher.state {
        case .idle, .needsCode:
            EmptyView()
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView()
                Text(message).font(.caption)
            }
        case .finished:
            Label("Refreshed. If GPS Teleport doesn't close by itself, close and reopen it.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private var canStart: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !refresher.isRunning
            && !spoof.isActive
            && !spoof.isBusy
    }

    private var showCodePrompt: Binding<Bool> {
        Binding(
            get: {
                if case .needsCode = refresher.state { return true }
                return false
            },
            // The alert's buttons answer the prompt, which is what dismisses it.
            set: { _ in }
        )
    }

    private var codeTitle: String {
        if case .needsCode(_, let lastError) = refresher.state, lastError != nil {
            return "That didn't work"
        }
        return "Enter your Apple code"
    }

    private var codeMessage: String {
        guard case .needsCode(let sentBySMS, let lastError) = refresher.state else { return "" }
        let source = sentBySMS ? "Apple texted you a code." : "Apple sent a code to your devices."
        if let lastError { return "\(lastError)\n\n\(source)" }
        return source
    }

    private func start() {
        if refreshesAutomatically {
            SavedPassword.save(password)
        } else {
            SavedPassword.delete()
        }
        refresher.refresh(email: email.trimmingCharacters(in: .whitespaces), password: password)
    }

    private func answer(_ answer: String?) {
        refresher.submitCode(answer)
        code = ""
    }
}
