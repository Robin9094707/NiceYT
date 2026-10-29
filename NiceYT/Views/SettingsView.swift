import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var showCookies = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Konto") {
                    if account.isSignedIn {
                        HStack(spacing: 12) {
                            Avatar(url: account.info?.avatar, size: 44)
                            VStack(alignment: .leading) {
                                Text(account.info?.name ?? "Angemeldet").font(.headline)
                                if let h = account.info?.handle { Text(h).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Button("Konto aktualisieren", systemImage: "arrow.clockwise") { Task { await account.refresh() } }
                        Button("Abmelden", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmSignOut = true
                        }
                    } else {
                        Button("Mit Google anmelden", systemImage: "person.crop.circle.badge.plus") { showLogin = true }
                        Button("Cookies importieren", systemImage: "doc.on.clipboard") { showCookies = true }
                    }
                }

                Section {
                    Picker("Standardqualität", selection: $settings.quality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Hintergrundwiedergabe", isOn: $settings.backgroundPlay)
                    Toggle("Bild-in-Bild automatisch", isOn: $settings.autoPiP)
                    Toggle("Nächstes Video automatisch", isOn: $settings.autoplayNext)
                    Toggle("Untertitel automatisch", isOn: $settings.captions)
                } header: {
                    Text("Wiedergabe")
                }

                Section {
                    Toggle("SponsorBlock", isOn: $settings.sponsorBlock)
                    if settings.sponsorBlock {
                        ForEach(AppSettings.allSponsorCategories) { cat in
                            Toggle(cat.label, isOn: Binding(
                                get: { settings.sponsorCategories.contains(cat.id) },
                                set: { on in
                                    if on { settings.sponsorCategories.insert(cat.id) } else { settings.sponsorCategories.remove(cat.id) }
                                }))
                            .padding(.leading, 8)
                        }
                    }
                    Toggle("Dislikes anzeigen (Return YouTube Dislike)", isOn: $settings.dislikes)
                } header: {
                    Text("Extras")
                } footer: {
                    Text("Segmente von sponsor.ajay.app, Dislike-Zahlen von returnyoutubedislike.com.")
                }

                Section("Darstellung") {
                    Picker("Akzentfarbe", selection: $settings.accent) {
                        ForEach(AccentChoice.allCases) { a in
                            Label(a.label, systemImage: "circle.fill").foregroundStyle(a.color).tag(a)
                        }
                    }
                    Toggle("Shorts im Feed ausblenden", isOn: $settings.hideShorts)
                }

                Section {
                    TextField("Sprache (hl)", text: $settings.language)
                        .textInputAutocapitalization(.never)
                    TextField("Region (gl)", text: $settings.region)
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("Inhalte")
                } footer: {
                    Text("Bestimmt Sprache und Region der Empfehlungen, z. B. de / DE.")
                }

                Section("Speicher") {
                    Button("Bild-Cache leeren", systemImage: "trash") {
                        URLCache.shared.removeAllCachedResponses()
                    }
                    Button("Suchverlauf löschen", systemImage: "clock.badge.xmark") {
                        UserDefaults.standard.removeObject(forKey: "searchHistory")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Link(destination: URL(string: "https://github.com/Robin9094707/NiceYT")!) {
                        Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } footer: {
                    Text("NiceYT ist ein inoffizieller Client und steht in keiner Verbindung zu Google oder YouTube.")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) { GoogleLoginView() }
            .sheet(isPresented: $showCookies) { CookieImportView {} }
            .confirmationDialog("Wirklich abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { account.signOut() }
            }
        }
    }
}
