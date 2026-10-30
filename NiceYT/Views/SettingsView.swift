import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var showCookies = false
    @State private var confirmSignOut = false
    @State private var cacheCleared = false
    @ObservedObject private var updates = UpdateChecker.shared

    /// The list plus the stored value, should it be one that isn't offered.
    private func options(_ list: [AppSettings.Option], current: String) -> [AppSettings.Option] {
        list.contains { $0.code == current } ? list : list + [.init(current, current)]
    }

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
                    Picker("Tonspur bei übersetzten Videos", selection: $settings.audioPreference) {
                        ForEach(AudioPreference.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Untertitel automatisch", isOn: $settings.captions)
                    Toggle("An letzter Stelle weiterschauen", isOn: $settings.resumePlayback)
                } header: {
                    Text("Wiedergabe")
                } footer: {
                    Text("Manche Videos haben eine automatisch erzeugte KI-Übersetzung. „Originalton“ spielt immer die echte Stimme ab. Im Player lässt sich die Tonspur pro Video über „Tonspur“ wechseln.")
                }

                Section {
                    Toggle("Doppeltippen zum Spulen", isOn: $settings.doubleTapSeek)
                    if settings.doubleTapSeek {
                        Picker("Sprungweite", selection: $settings.seekInterval) {
                            ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) Sekunden").tag($0) }
                        }
                    }
                    Toggle("Hochwischen für Querformat", isOn: $settings.swipeFullscreen)
                    Toggle("Lautstärke & Helligkeit wischen", isOn: $settings.swipeVolume)
                    Toggle("Haptisches Feedback", isOn: $settings.haptics)
                } header: {
                    Text("Bedienung & Gesten")
                } footer: {
                    Text("Im Querformat: rechts wischen ändert die Lautstärke, links die Helligkeit. In der Mitte nach unten wischen beendet das Querformat. Lange auf Videos, Shorts, Kanäle, Playlists und Songs drücken öffnet weitere Aktionen.")
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
                    Picker("Sprache", selection: $settings.language) {
                        ForEach(options(AppSettings.languages, current: settings.language)) { l in
                            Text(l.name).tag(l.code)
                        }
                    }
                    Picker("Region", selection: $settings.region) {
                        ForEach(options(AppSettings.regions, current: settings.region)) { r in
                            Text(r.name).tag(r.code)
                        }
                    }
                } header: {
                    Text("Inhalte")
                } footer: {
                    Text("Sprache und Region der Inhalte von YouTube (Empfehlungen, Datumsangaben, Aufrufe, Kommentare). Gilt für neu geladene Seiten.")
                }

                Section {
                    Picker("Streaming-Qualität", selection: $settings.musicStreamQuality) {
                        ForEach(DZQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Download-Qualität", selection: $settings.musicDownloadQuality) {
                        ForEach(DZQuality.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Musik (Deezer)")
                } footer: {
                    Text("Höhere Stufen werden nur genutzt, wenn dein Deezer-Abo sie erlaubt – sonst automatisch die nächstbeste. FLAC-Dateien sind ca. 30 MB pro Song, MP3 320 ca. 8 MB.")
                }

                Section {
                    NavigationLink {
                        BrowserSettingsView()
                    } label: {
                        Label("Browser & Downloads", systemImage: "safari")
                    }
                    NavigationLink {
                        MediaLibraryView()
                    } label: {
                        Label("Mediathek", systemImage: "square.stack.fill")
                    }
                } header: {
                    Text("Browser")
                } footer: {
                    Text("Suchmaschine, Werbeblocker, Face-ID-Sperre, Download-Ziel (Mediathek, Fotos, Dateien).")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnose & Protokoll", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Hilfe")
                } footer: {
                    Text("Zeigt, welche Stream-Quelle funktioniert oder warum ein Video nicht startet. Über „Senden“ kannst du das Protokoll weitergeben.")
                }

                Section {
                    NavigationLink {
                        DataResetView()
                    } label: {
                        Label("Daten löschen …", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Konten & Daten")
                } footer: {
                    Text("YouTube, Deezer oder den Browser einzeln zurücksetzen – oder alles löschen und neu anfangen.")
                }

                Section("Speicher") {
                    Button("Bild-Cache leeren", systemImage: "trash") {
                        URLCache.shared.removeAllCachedResponses()
                        cacheCleared = true
                    }
                    Button("Suchverlauf löschen", systemImage: "clock.badge.xmark") {
                        UserDefaults.standard.removeObject(forKey: "searchHistory")
                    }
                }

                Section {
                    LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                    if let latest = updates.latest, updates.updateAvailable {
                        Button {
                            updates.prompt = latest
                        } label: {
                            Label("Update auf Build \(latest.build) installieren", systemImage: "arrow.down.app.fill")
                        }
                    } else {
                        Button {
                            Task { await updates.check(force: true) }
                        } label: {
                            HStack {
                                Label(updates.latest == nil ? "Nach Updates suchen" : "Aktuell – erneut prüfen", systemImage: "arrow.triangle.2.circlepath")
                                if updates.isChecking { Spacer(); ProgressView() }
                            }
                        }
                    }
                    Link(destination: URL(string: "https://github.com/Robin9094707/NiceYT")!) {
                        Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } footer: {
                    Text("\(AppInfo.name) ist ein inoffizieller Client und steht in keiner Verbindung zu Google, YouTube, Deezer, TikTok, Meta oder X.\(updates.lastError.map { "\nUpdate-Prüfung: " + $0 } ?? "")")
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
                Button("Abbrechen", role: .cancel) {}
            }
            .alert("Cache geleert", isPresented: $cacheCleared) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}
