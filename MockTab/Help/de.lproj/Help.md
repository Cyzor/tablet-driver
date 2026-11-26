[about]

## Grafiktabletts

Ein Grafiktablett ist ein Eingabegerät mit Stift, das absolute Position, Druck, Neigung und Rotation meldet.

## MockTab

MockTab ist ein macOS-Treiber für Wacom- und Xencelabs-Grafiktabletts. Unterstützt werden USB- und Bluetooth-Grafiktabletts aus den Wacom-Familien Intuos, Intuos Pro, Cintiq, Bamboo und Graphire sowie einige Xencelabs-Modelle. Der Fokus liegt auf Hardware, die Wacoms eigener Treiber auf aktuellen macOS-Versionen nicht mehr unterstützt.

## MockTab entfernen

Beende MockTab und lege es in den Papierkorb. Um auch die Einstellungen zu entfernen, öffne die folgenden Objekte im Finder mit **Gehe zum Ordner** (⇧⌘G) und lege sie in den Papierkorb:

- `~/Library/Preferences/com.cyzor.mocktab.plist` – Einstellungen  
- `~/Library/Application Support/com.cyzor.mocktab` – frühere Einstellungen, gesichert bei jedem Start einer anderen Version  

[tabletArea]

## Aktiver Bereich

Der aktive Bereich ist der Teil der Grafiktablett-Oberfläche, der auf den Bildschirm abgebildet wird. Stifteingaben außerhalb dieses Rechtecks haben keine Wirkung.

**Größe ändern** – Ziehe den Bereich oder seine Griffe; nahe der Form des Bildschirmbereichs rastet er ein (**⌘** verhindert das, **⇧** behält seine Form bei, **⌥** ändert die Größe von der Mitte aus). Für eine genaue Größe klicke auf Breite oder Höhe darunter.

**Tastatur** – Ab macOS 14 klickst du auf den Bereich und verschiebst ihn mit den Pfeiltasten; mit **⌥** änderst du seine Größe. Mit **⇧** werden die Schritte größer.

**Proportionale Zuordnung** – Hält die Cursorwege horizontal und vertikal gleich lang. Schalte sie aus, um die Abbildung zu strecken oder zu stauchen.

**Auf Vollbereich zurücksetzen** – Stellt die gesamte Grafiktablett-Oberfläche wieder her. ⌘Z macht es rückgängig.

## Ausrichtung

Wähle die Ausrichtung, die zur aktuellen Lage des Grafiktabletts passt (⌘⌥1 bis ⌘⌥4 im Grafiktablett-Bereich). Stift, Berührung und Neigung folgen der Wahl, und der Tasten-Bereich zeichnet das Grafiktablett entsprechend.

Beim Drehen wandert jede Belegung zu der Taste, die jetzt an ihrer Stelle sitzt, in jedem Profil und jeder App-Ausnahme. Mit Rückgängig stellst du beides gemeinsam wieder her.

**Belegung umdrehen** – Klicke mit der rechten Maustaste auf das Grafiktablett im Tasten-Bereich, um jede Belegung auf die gegenüberliegende Taste zu tauschen, ohne die Ausrichtung zu ändern. Ein zweites Mal stellt alles wieder her.

## Kalibrierung (Stiftdisplays)

**Kalibrieren…** zeigt bildschirmfüllende Ziele, die du mit der Stiftspitze antippst. Es korrigiert den Versatz zwischen Stiftspitze und Cursor, den das Displayglas verursacht.

Mit **Zeiger-Versatz** gleichst du einen kleinen verbleibenden Versatz aus, etwa einen, der sich mit dem Blickwinkel ändert.

[penFeel]

## Druckkurve

Ziehst du die Kurve nach oben, wirken leichte Striche kräftiger; nach unten brauchst du mehr Kraft. Linear, Weich und Fest sind Voreinstellungen.

Ab macOS 14 klickst du auf die Kurve und verschiebst mit den Pfeiltasten den Griff am leichten Ende, mit **⌥** den anderen. Mit **⇧** werden die Schritte größer.

## Druckglättung

Gleicht die Strichbreite bei langsamen, leichten Strichen aus.

## Stabilisierung

Dämpft das Zittern des Cursors durch unruhige Hände, kostet aber etwas Verzögerung.

## Doppelklick-Abstand

Wie nah zwei Tipper beieinander landen müssen, um als Doppelklick zu zählen.

## Bewegung

**Drehrichtung umkehren** – Legt fest, ob das Drehen des Schafts eine Bewegung im oder gegen den Uhrzeigersinn ergibt.

**Relative Cursorbewegung** – Bewegt den Cursor wie eine Maus, statt das Grafiktablett auf den Bildschirm abzubilden.

## Ansicht schwenken

**Geschwindigkeit**, **Richtung umkehren** und **Scrollen mit Nachlauf** legen fest, wie sich der Inhalt bewegt, solange du eine Taste für „Ansicht schwenken“ hältst. Weise „Ansicht schwenken“ im Tasten-Bereich zu.

## Klickverhalten

**Nur bei Kontakt** – Markierte Aktionen der Seitentasten warten, bis die Spitze aufsetzt. Nicht markierte Klickaktionen wirken auch beim Schweben, auch zum Ziehen.

**Abhebehilfe** – Verhindert, dass schnelle Striche abreißen, wenn die Spitze kurz abhebt.

**Ziehschwelle** – Verhindert, dass ein Tippen zu einem kleinen Ziehen wird.

[buttons]

## Stiftdiagramm

Drücke bei geöffnetem Fenster eine beliebige Taste, um ihre Position hervorzuheben; so erkennst du, welcher physische Knopf welchem Zuordnungsslot entspricht. Klicke im Diagramm auf die Spitze, den Radierer oder eine Barrel-Taste, um eine neue Zuordnung dafür aufzuzeichnen.

## Mäuse

Eine Wacom-Maus bekommt ein eigenes Diagramm und eigene Tastenzeilen. Die ersten drei Tasten starten als Links-, Rechts- und Mittelklick.

## Grafiktablett-Diagramm

Das Diagramm zeigt, wo Tasten, Ringe und Einstellräder eines Grafiktabletts sitzen. Klicke auf ein Element, um ihm eine Aktion zuzuweisen.

## Zuordnungstypen

- **Maustasten** – Links-, Rechts- und Mittelklick, Doppelklick und Klick-Verriegelung, die die linke Taste bis zum nächsten Druck gedrückt hält  
- **Tastaturkurzbefehle** – Klicke ins Kurzbefehlsfeld und drücke eine beliebige Tastenkombination  
- **Gehaltene Modifikatortasten** – ⌘ ⌥ ⇧ ⌃ bleiben gedrückt, solange die Taste gehalten wird  
- **Spezialaktionen** – Ansicht schwenken, Radierer, Leertaste, Escape, F13 bis F19, Display umschalten, Auf Displays verteilen, Relativen Modus umschalten, MockTab-Einstellungen anzeigen sowie Modi für Ringe, Einstellräder und Leisten  
- **Öffnen** – Ziehe eine App, eine Datei, einen Link oder ein Keyboard-Maestro-Makro auf die Zeile einer Taste. Ein Fragezeichen bedeutet, dass das Ziel fehlt. Um eine URL einzugeben oder zu korrigieren, klicke mit der rechten Maustaste auf die Zeile und wähle „URL bearbeiten“  

Um ein Skript, einen Automator-Arbeitsablauf oder einen Kurzbefehl auszuführen, sichere ihn als App und ziehe diese auf die Zeile, oder gib ihm in den Systemeinstellungen oder in Kurzbefehle einen Tastaturkurzbefehl und weise diesen zu.

## Touch Ring und Einstellrad

Touch Rings, Einstellräder und Berührungsleisten haben jeweils eigene Modi. Klicke auf einen Modus oder seinen Keil im Diagramm, um seine Einstellungen zu ändern. Um Modi per Taste zu wechseln, weise **Wechseln** oder **Zu Modus springen** zu.

**Scrollen** – Funktioniert wie ein Scrollrad. Bei 1× scrollt jeder Schritt eine Zeile.

**Zoomen** und **Drehen** – Vergrößern oder drehen die Arbeitsfläche wie eine Trackpad-Geste. Die Geschwindigkeit reicht von Aus bis Maximum; bei Maximum dreht eine Ringumdrehung die Arbeitsfläche einmal komplett herum. Die Unterstützung hängt von der App ab.

**Taste** – Sendet für jede Richtung einen Tastaturkurzbefehl.

## Tastendisplays

Ein Intuos4 mit Tastendisplays zeigt per USB neben jeder Taste ihre Aktion an, und die Displays dimmen sich bei Inaktivität.

## Beleuchtung

Bei Geräten mit beleuchtetem Einstellradring oder hinterleuchteten Tasten lassen sich Farbe und Helligkeit einstellen. Die Hardware behält ihre letzte Farbe, bis du sie änderst.

## Radierer

Das Radiererende hat eine eigene Zuweisung im Stiftabschnitt. Hat ein Stift keins, weise einer Seitentaste „Radierer“ zu und halte sie, um mit der Spitze zu radieren.

## App-Ausnahmen

Über die Ausnahmen-Leiste oben kannst du für eine bestimmte Anwendung andere Tastenbelegungen festlegen. Die Ausnahmen werden automatisch aktiv, sobald diese App in den Vordergrund kommt. In allen anderen Fällen gelten die globalen Einstellungen.

**Zurücksetzen** entfernt die Ausnahmen der aktuellen App. Mit gedrückter **⌥**-Taste wird daraus **Alle entfernen**, das die Ausnahmen aller Apps für dieses Grafiktablett entfernt.

[touch]

## Berührung

Manche Grafiktabletts erkennen auch deine Finger. MockTab lässt Touch standardmäßig ausgeschaltet; aktiviere **Fingereingabe aktivieren**, um es zu verwenden. Die Reaktion hängt von der App ab.

**Tippen zum Klicken** – Eine kurze Berührung ohne nennenswerte Bewegung sendet einen Linksklick.

**Rechtsklick mit zwei Fingern** – Eine kurze Berührung mit zwei Fingern, etwa eine Fingerkuppe breit auseinander, sendet einen Rechtsklick.

**Mit drei Fingern ziehen** – Setzt du drei Finger gleichzeitig auf, bleibt die Maustaste gedrückt. Bewege sie zum Ziehen und heb sie zum Loslassen ab.

**Zeigergeschwindigkeit** – Skaliert die Zeigerbewegung bei einer Ein-Finger-Drag-Geste. Niedrigere Werte erlauben feinere Kontrolle, höhere decken mit weniger Bewegung mehr Strecke ab.

## Gesten

**Zwei-Finger-Scrollen** – Mit zwei Fingern in eine Richtung streichen. Apps behandeln dies in der Regel wie Scrollen mit einem Trackpad.

**Zum Zoomen zusammenziehen** – Zwei Finger spreizen oder zusammenziehen, um zu zoomen.

**Drehen** – Zwei Finger weit auseinander auf das Grafiktablett legen und um ihre Mitte schwenken. Scrollen, Zoomen und Drehen sind unterschiedliche Deutungen derselben Zwei-Finger-Geste und lassen sich einzeln ein- oder ausschalten.

**Richtung umkehren** – Der Inhalt bewegt sich entgegengesetzt zur Fingerbewegung, wie bei einem klassischen Mausrad.

**Scrollen mit Nachlauf** – Nach dem Abheben der Finger läuft der Scrollvorgang kurz nach, ähnlich wie beim Trackpad.

## Berührungsbereich

Der Berührungsbereich arbeitet unabhängig vom aktiven Stiftbereich. Ziehe die Griffe in der Vorschau, um den verfügbaren Berührungsbereich zuzuschneiden. Fingereingaben außerhalb des Rechtecks haben keine Wirkung. Modifikator- und Pfeiltasten funktionieren wie beim aktiven Bereich.

**Auf volle Fläche zurücksetzen** – Stellt den Berührungsbereich auf die gesamte touchfähige Fläche zurück.

## Einschränkungen

MockTab unterstützt kein Mission Control, Spaces, Launchpad oder App Exposé per Touch.

[display]

## Display-Zuordnung

Die Display-Zuordnung legt fest, welcher Bildschirm dem Grafiktablett zugeordnet ist.

**Hauptdisplay** – Bildet das Grafiktablett auf dein Hauptdisplay ab.

**Ein einzelnes Display** – Wähle ein Display nach Namen, um das Grafiktablett nur darauf abzubilden.

**Zwischen Displays wechseln** – Ein Tastendruck wechselt das Grafiktablett zwischen den ausgewählten Displays. Mit ⌘-Klick auf Displays im Diagramm wählst du sie aus, mit Shift-Klick einen Bereich.

**Auf die ausgewählten Displays verteilt** – Bildet das Grafiktablett über die ausgewählten Displays als eine Fläche ab.

**Alle** – Bildet das Grafiktablett über alle Displays als eine Fläche ab.

**Auf Displays verteilen** – Drück eine Taste mit dieser Aktion, um den Stift auf die unter „Aktive Displays“ ausgewählten Displays zu verteilen, und drück sie erneut, um zur gewohnten Einstellung zurückzukehren. Ist keins ausgewählt, gilt es für alle Displays.

## Bildschirmbereich

Wie der aktive Bereich, nur auf der Bildschirmseite: legt fest, welchen Teil des Displays der Stift erreicht.

**Auf dem Bildschirm auswählen…** – Ziehe den Bereich direkt über deinen Desktop, wie beim macOS-Screenshot-Tool.

**Ganzen Bildschirm verwenden** – Setzt den Bereich auf das gesamte Display zurück.

[devices]

## Verbundene Geräte

Unter Devices siehst du alle Grafiktabletts und Stifte, die MockTab erkannt hat. Neben dem Namen stehen Verbindungsart (USB oder Bluetooth) und Status.

Wählst du ein Gerät aus, erscheinen rechts die passenden Einstellungen und Stifte.

Auch nicht verbundene Geräte bleiben in der Liste, damit du ihre Profile prüfen oder anpassen kannst. Sobald ein Gerät wieder verbunden wird, übernimmt MockTab automatisch die gespeicherten Einstellungen.

Bei einem Intuos5 oder Intuos Pro (2013) mit dem Wacom Wireless-Kit legt die Zeile **Batterie** im Info-Bereich fest, wie lange das Grafiktablett unbenutzt bleibt, bevor es in den Ruhezustand wechselt.

## Konflikterkennung

Wenn gleichzeitig ein anderer Grafiktablett-Treiber läuft, etwa der offizielle Wacom-Treiber, versucht MockTab den Konflikt zu erkennen und eine Warnung anzuzeigen.

[profiles]

## Profile

Ein Profil ist eine Momentaufnahme der Grafiktablett-Einstellungen: aktiver Bereich, Druckkurve, Tastenbelegungen und Display-Zuordnung. Beim Wechseln eines Profils werden all diese Einstellungen sofort angewendet.

## Erstellen und Umbenennen

Klicke auf **Profil erstellen**, um die aktuellen Einstellungen als neues Profil zu speichern. Mit einem Doppelklick auf einen Profilnamen kannst du ihn umbenennen, mit einem Rechtsklick auf ein Profil findest du weitere Optionen. Hältst du beim Öffnen dieses Menüs **⌥** gedrückt, kannst du alle Profile dieses Grafiktabletts löschen; **⌘Z** stellt sie wieder her.

## App-Ausnahmen in Profilen

Profile speichern ihre eigenen App-Ausnahmen. Wenn du das Profil wechselst, wechseln auch die Ausnahmen, die zum aktiven Profil gehören.

## Sichern und Importieren

Ziehe die JSON-Kachel in den Finder, um alle Einstellungen zu sichern, auch Seriennummern und App-Namen. Ziehe eine Datei auf die Kachel, um sie zu importieren, und wähle die Grafiktabletts aus, die übernommen werden. Das Menü „Profile“ bietet dasselbe. Mit ⌥-Klick auf das Kästchen eines Grafiktabletts setzt oder entfernst du alle Häkchen.

[scratchpad]

## Testbereich

Eine Testfläche, um zu prüfen, ob der Stift Druck und Bewegung erkennt. MockTab speichert keine Striche.

[info]

## Live-Eingabe

Der Info-Bereich zeigt, was das Grafiktablett meldet. Anzeigen stehen für Position, Druck, Neigung, Rotation, Schwebehöhe und Touch-Eingaben.

## Gerätedaten erfassen

**Gerätedaten erfassen** zeichnet auf, was das Grafiktablett bei der Benutzung sendet. Das Ergebnis ist eine einzelne ZIP-Datei, die sich an eine GitHub-Anfrage anhängen oder per E-Mail senden lässt, um die Unterstützung für ein Gerät hinzuzufügen oder zu verbessern.

## Updates

**Jetzt suchen** fragt bei mocktab.org nach einer neueren Version, **Automatisch suchen** fragt wöchentlich. Sonst geht nichts online.

Ein Kennzeichen am Menüleisten- und Dock-Symbol zeigt ein verfügbares Update an. **Beim Beenden installieren** installiert es, wenn MockTab beendet wird, **Installieren und neu starten** sofort.

Mit gedrückter **⌥**-Taste wird aus **Jetzt suchen** **Nach Vorabversion suchen**, das nach einer neueren Testversion sucht. Vorabversionen können unvollständig sein. Der Menübefehl **Nach Updates suchen…** ändert sich ebenso.

## Dock und Anmeldung

**Dock-Symbol** – Blendet MockTab im Dock aus. Das Menüleistensymbol bleibt.

**Bei Anmeldung starten** – Öffnet MockTab, wenn du dich anmeldest.

**Erlauben…** öffnet die Systemeinstellungen für eine fehlende Berechtigung.

[website]

## mocktab.org

Die Website [mocktab.org](https://mocktab.org) bietet Dokumentation, Release Notes und die vollständige Liste unterstützter Hardware.

## GitHub

Bugmeldungen und Fragen gehören nach [github.com/Cyzor/tablet-driver/issues](https://github.com/Cyzor/tablet-driver/issues).

## Danksagung

MockTab baut auf Open-Source-Arbeit auf. [OpenTabletDriver](https://opentabletdriver.net/) liefert Konfigurationen für Grafiktabletts vieler Hersteller. Das [Linux Wacom Project](https://linuxwacom.github.io/) liefert über libwacom Abmessungen und Bedienelemente von Wacom-Geräten und dokumentiert Wacoms Datenformate in seinem Treiber input-wacom, der auch im Linux-Kernel steckt, und in der Sammlung wacom-hid-descriptors.

## Lizenz

MockTab ist freie Software unter der [GNU General Public License, Version 3 oder neuer](https://www.gnu.org/licenses/gpl-3.0.html). Der Quellcode liegt unter [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver). TabletKit, die Bibliothek, mit der MockTab Grafiktabletts ausliest, steht unter der [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).

Die Grafiktablett-Zeichnungen nutzen Bedienelement-Layouts aus libwacom:

Copyright © 2011 Red Hat, Inc.

Permission to use, copy, modify, distribute, and sell this software and its documentation for any purpose is hereby granted without fee, provided that the above copyright notice appear in all copies and that both that copyright notice and this permission notice appear in supporting documentation, and that the name of Red Hat not be used in advertising or publicity pertaining to distribution of the software without specific, written prior permission.  Red Hat makes no representations about the suitability of this software for any purpose.  It is provided "as is" without express or implied warranty.

THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
