# Nova (ehemals NicePlay / NiceYT)

Werbefreier YouTube-Client, Deezer-Musikplayer, **vollwertiger Browser** und **Download-Assistent** für iOS 26+ im
**Liquid-Glass-Design** – komplett in SwiftUI.

<p align="center"><img src="NiceYT/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="160"></p>

## Features

| | |
|---|---|
| 🎬 **Native Wiedergabe** | HLS-Streams direkt in AVKit (Liquid-Glass-Player von iOS 26), bis 4K, Geschwindigkeit, AirPlay |
| 🚫 **Werbefrei** | Werbe-Renderer und Werbeblöcke werden gar nicht erst geladen |
| 🔐 **Google-Login** | Anmeldung mit deinem Google-Konto (oder Cookie-Import als Alternative) |
| 📺 **Dein YouTube** | Startseite/Empfehlungen, Abo-Feed, abonnierte Kanäle, Verlauf, Später ansehen, Likes, Playlists |
| ⚡ **Shorts** | Vertikaler Shorts-Feed mit Glas-Buttons |
| ⏭ **SponsorBlock & Dislikes** | Überspringt Sponsoren, zeigt Dislikes (Return YouTube Dislike) |
| 🗣 **Originalton** | Immer die echte Tonspur – keine KI-Synchronisation (umschaltbar pro Video) |
| 🎵 **Deezer & YouTube Music** | Deezer-Login, Alben, Playlists, Charts, Flow; YouTube Music ganz ohne Konto |
| 🌐 **Browser** | Tabs (normal & privat), Lesezeichen & Favoriten, Verlauf wie in Safari, Vorschläge, Suchmaschine wählbar, Auf-der-Seite-suchen, Textgröße, Desktop-Modus, Pop-up-Logins, Tabs werden wiederhergestellt |
| 🛡 **Werbeblocker** | Blockt Werbung & Tracker von über 100 Werbenetzwerken, pro Seite abschaltbar |
| 🍪 **Cookies & Website-Daten** | Alle Seiten mit ihren Cookies ansehen, einzelne Cookies oder Seiten löschen |
| 🔒 **Face ID** | Browser und Mediathek optional mit Face ID / Touch ID sperren |
| 🪄 **Download-Assistent** | Link einfügen oder teilen → TikTok (ohne Wasserzeichen, Diashows, Ton), Instagram (Reels, Beiträge, Karussells), Facebook (HD), X, Reddit (mit Ton), Vimeo, Dailymotion und jede Seite mit Video – ohne den Browser zu öffnen |
| 📤 **Teilen-Menü** | „Nova“ erscheint im iOS-Teilen-Menü (TikTok → Teilen → Nova) und startet den Download sofort |
| ⬇️ **Download-Knopf an jedem Player** | Im Browser hat jedes Video und jeder Audio-Player einen ⬇︎-Knopf; laufende Medien („Wird abgespielt“) lassen sich mit einem Tipp sichern |
| ▶️ **Nativer Media-Player** | Videos & Songs von Webseiten im AVKit-Player (PiP, AirPlay, Vollbild) mit Download-Knopf |
| 🗂 **Mediathek** | Alle Downloads mit Vorschaubildern, Filter, Suche, Raster/Liste, Mehrfachauswahl, Umbenennen; wahlweise zusätzlich in Fotos oder Dateien sichern |
| 🔄 **Updates mit einem Tipp** | Die App findet neue Builds selbst und installiert sie über AltStore, SideStore oder TrollStore |
| 🪟 **Liquid Glass** | Glas-Tabbar mit Mini-Player, Glas-Chips, -Buttons und -Karten |

## IPA bauen (GitHub Actions)

Jeder Push auf `main` baut automatisch eine unsignierte `NiceYT.ipa` (App-Name: Nova) und veröffentlicht sie unter **Releases**.
Manuell: **Actions → Build NiceYT IPA → Run workflow**. Die Build-Nummer ist die Nummer des Workflow-Laufs –
daran erkennt die App unter **Einstellungen → Nach Updates suchen** neue Versionen.

## Installieren

Die IPA ist unsigniert und wird beim Sideloaden mit deiner Apple-ID signiert:

- **AltStore / SideStore** – IPA in der App öffnen
- **Sideloadly** – IPA auf den Mac/PC ziehen, iPhone anschließen
- **TrollStore** – direkt installierbar (fake-signiert)

Voraussetzung: **iOS 26 oder neuer**. Die IPA enthält eine Teilen-Erweiterung (kostenlose Apple-IDs: zählt bei
AltStore/SideStore als zusätzliche App-ID). Mit TrollStore bekommt der Browser zusätzlich die Passkey-Berechtigung.

## Download-Assistent & Teilen-Menü

- In TikTok, Instagram, Facebook … auf **Teilen** tippen und **Nova** wählen (einmalig unter „Mehr“ einblenden).
  Nova öffnet sich und lädt die beste Qualität – oder du wählst Video, Ton, Bilder.
- Oder Link kopieren: Nova erkennt ihn beim Öffnen und bietet **Laden** an.
- Private Beiträge: im Nova-Browser bei der Plattform anmelden – der Assistent nutzt dieselbe Sitzung.
- Speicherort: **Mediathek** (auch in der Dateien-App unter *Nova › Downloads*), zusätzlich **Fotos** oder **Dateien**.

## Deezer verbinden

Tab **Musik → Bei Deezer anmelden** und ganz normal einloggen – die App übernimmt den `arl`-Cookie automatisch.
Alternativ den `arl`-Cookie von deezer.com (Entwicklertools → Cookies) einfügen. Für 320 kbit/s bzw. FLAC
wird ein entsprechendes Deezer-Abo benötigt. Downloads liegen unter *Dateien → Auf meinem iPhone → Nova → Musik*.

## Anmeldung

Tippe auf **Mit Google anmelden** und melde dich ganz normal an. Die App speichert die YouTube-Sitzung im Schlüsselbund.
Falls Google die Anmeldung im eingebetteten Browser blockiert: **Einstellungen → Cookies importieren** und die Cookies von
`youtube.com` aus einem angemeldeten Browser einfügen (Cookie-Header oder `cookies.txt`).

## Alternative: Offizielle YouTube-App + YTLite

Der Workflow **Build YouTube Plus** baut die *offizielle* YouTube-App mit [YTLite](https://github.com/dayanch96/YTLite)
(werbefrei, Downloads, SponsorBlock, PiP, 4K, Dislikes) und schaltet das Liquid-Glass-Design frei.
Dafür brauchst du eine **entschlüsselte YouTube-IPA** (Direktlink), die du selbst besorgen musst.
Standard ist YTLite **5.2b4**, die letzte kostenlose Version. Das Ergebnis landet als Entwurf unter Releases.

## Technik

- `NiceYT/Core` – InnerTube-Client (WEB-Client für Feeds/Konto mit SAPISIDHASH, iOS-Client für HLS-Streams), robuster Renderer-Parser
- `NiceYT/Player` – AVKit-Player, Mini-Player, Shorts-Player, SponsorBlock, Untertitel, Now Playing
- `NiceYT/Browser` – Tabs & Web-Views, Werbeblocker, Lesezeichen/Verlauf, Medien-Erkennung, Extraktoren (`MediaExtractor`),
  Download-Assistent, Mediathek, nativer Media-Player
- `ShareExtension` – Teilen-Erweiterung, übergibt Links per `nova://download?url=…` an die App
- `NiceYT/Views` – SwiftUI-Oberfläche mit iOS-26-Liquid-Glass-APIs (`glassEffect`, `GlassEffectContainer`, `tabViewBottomAccessory`, …)
- Projekt wird mit [XcodeGen](https://github.com/yonaskolb/XcodeGen) aus `project.yml` erzeugt

> Nova ist ein inoffizielles Projekt und steht in keiner Verbindung zu Google, YouTube, Deezer, TikTok, Meta oder X.
