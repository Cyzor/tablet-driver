[about]

## Grafiktabletts

Ein Grafiktablett ist ein Eingabegerät mit Stift, das absolute Position, Druck, Neigung und Rotation überträgt.

## MockTab

MockTab ist ein nativer macOS-Treiber für Wacom-Tabletts. USB- und Bluetooth-Unterstützung für Intuos, Cintiq, Bamboo und Intuos Pro — Hardware, die Wacoms Treiber nicht mehr unterstützt.

[tabletArea]

## Aktiver Bereich

Der aktive Bereich ist der Teil der Oberfläche, der auf deinen Bildschirm abgebildet wird. Eingaben außerhalb werden ignoriert.

**Größe ändern** — Ziehe einen Anfasser zum Verschieben oder Ändern. **Shift** + Eckenziehen sperrt Verhältnis. Gib genaue Werte in Breite und Höhe ein.

**Seitenverhältnis sperren** — Hält Tablett-zu-Bildschirm-Seitenverhältnis proportional.

**Vollständig zurücksetzen** — Stellt auf gesamte Oberfläche zurück. ⌘Z macht rückgängig.

## Kalibrierung (Pen-Displays)

**Calibrate** öffnet eine Vollbild-Überlagerung zum Antipp von Fadenkreuz-Zielen. Korrigiert Parallaxen-Versatz vom Display-Glas.

Nach Kalibrierung **Manuelle Feinkorrektur** nutzen, falls Versatz verbleibt.

[penFeel]

## Druckkurve

Die Kurve steuert, wie Stiftdruck abgebildet wird. Konkav (oben) macht leichte Striche stärker; konvex (unten) braucht mehr Kraft.

**Tip Feel-Voreinstellungen** — Linear, Soft, Firm. Wähle eine zum Setzen; anpassen wechselt zu custom.

## Glättung

Reduziert hochfrequentes Zittern. Höhere Werte = saubere Striche mit Verzug; niedrig = direkt. Null für Präzision.

## Doppelklick-Abstand

Legt fest, wie nah zwei Antipper sein müssen. Erhöhe, wenn nicht erkannt; senke, wenn zufällige auftreten.

[buttons]

## Stift-Diagramm

Das Diagramm zeigt die Tasten. Drücke eine zum Sehen der Hervorhebung — identifiziert physische Taste zu Zuordnung.

**Hover Drag** — Taste 1 (untere Barrel) + Schwebeflug = Zeiger ohne Spitzenkontakt.

## Zuordnungstypen

- **Maustasten** — Linksklick, Rechtsklick, Mittelklick oder Doppelklick
- **Tastaturkürzel** — Klicke in das Kürzelfeld und drücke eine beliebige Tastenkombination
- **Modifikator-Halten** — ⌘ ⌥ ⇧ ⌃ werden so lange gehalten, wie die Taste gedrückt ist
- **Sonderaktionen** — Bildschirm umschalten, Eraser, Touch-Ring-Modusauswahl

## Touch-Ring

Der Ring unterstützt mehrere Slots. Jeder hat Uhrzeiger- und gegen-Uhrzeiger-Aktionen — Scroll, Tastenkürzel, oder Aus.

## Radiergummi

Radiergummispitze hat eigene Belegung (Stift-Bereich). Manche Apps wechseln automatisch.

## App-spezifische Overrides

Die Override-Leiste oben erlaubt es dir, für eine bestimmte App andere Tasten zuzuweisen. Overrides aktivieren sich automatisch, wenn diese App in den Vordergrund kommt. Globale Einstellungen gelten überall sonst.

[touch]

## Fingerberührung

Tablets mit kapazitiver Berührungsfläche melden Fingerkontakte zusätzlich zur Stifteingabe. MockTab lässt diese Funktion standardmäßig deaktiviert — schalte **Fingerberührung aktivieren** ein, um sie zu nutzen.

**Tippen für Klick** – Eine kurze Berührung ohne nennenswerte Bewegung sendet einen Linksklick. Lass dies deaktiviert, wenn du beim Zeichnen Finger auf dem Tablet abstützt; sonst entstehen Geisterklicks.

**Zeigergeschwindigkeit** – Skaliert die Cursorbewegung bei einer einzelnen Fingerbewegung. 1,00× bildet die Berührungsfläche direkt auf den Bildschirm ab; höhere Werte legen mit weniger Bewegung mehr Strecke zurück, niedrigere ermöglichen feinere Kontrolle.

## Scrollen

**Zwei-Finger-Scrollen** – Zwei sich gemeinsam bewegende Finger senden weiche Scrollereignisse. Apps behandeln diese als Trackpad-Scrollen, einschließlich Rubber-Banding in Safari und Vorschau.

**Natürliches Scrollen** – Ein: Der Inhalt folgt der Fingerbewegung, passend zur macOS-Systemeinstellung. Aus: Der Inhalt bewegt sich in die entgegengesetzte Richtung, wie bei einem klassischen Mausrad.

## Berührungsbereich

Der Berührungsbereich ist unabhängig vom aktiven Stiftbereich. Ziehe die Griffe in der Vorschau, um die Berührungsfläche zuzuschneiden; Fingereingaben außerhalb des Rechtecks haben keine Wirkung. Die meisten Nutzer lassen die volle Fläche für Berührung aktiviert und schneiden nur den Stiftbereich zu.

**Auf volle Fläche zurücksetzen** – Stellt den Berührungsbereich auf die gesamte berührungsfähige Fläche zurück.

## Was Berührung nicht kann

MockTab kann keine Mission Control-, Spaces-, Launchpad- oder andere systemweite Multi-Touch-Gesten senden. macOS reserviert diese für private Trackpad-Ereigniskanäle, die nur First-Party-Treibern zugänglich sind. Verwende ein Trackpad oder Tastenkürzel zur Systemnavigation.

[display]

## Display-Zuordnung

Steuert, auf welchen Bildschirm der aktive Bereich abgebildet wird.

**Alle Bildschirme** — Tablett spannt sich proportional über Desktop. Für mehrere Monitore.

**Einzelner Bildschirm** — Ordnet einem bestimmten Display zu. Wähle aus Liste; Vorschau aktualisiert sich.

**Bildschirm umschalten** — Weise einer Express-Taste zu zum Wechseln ohne Öffnen.

[devices]

## Verbundene Geräte

Der Bereich listet alle Tabletts und Stift-Tools. Jede Zeile zeigt Name, Verbindungstyp (USB/Bluetooth), Status.

## Konflikt-Erkennung

Wenn ein anderer Treiber läuft, zeigt MockTab Warnung. Beende konkurrierenden Treiber vor Verwendung.

[profiles]

## Profile

Ein Profil speichert alle Einstellungen — aktiver Bereich, Druckkurve, Tasten, Display. Wechsel ist sofort.

## Erstellen und Umbenennen

**Profil erstellen** zum Speichern. Doppelklick auf Name zum Umbenennen.

## App-spezifische Overrides in Profilen

Overrides werden mit dem Profil gespeichert. Wechsel ändert sie zusammen.

## Sicherung & Wiederherstellung

Ziehe Karte in Finder zum Exportieren als JSON. Ziehe JSON auf Liste zum Importieren. Teile oder nutze als Backup.

[scratchpad]

## Testbereich

Druckempfindliche Testfläche. Deckkraft und Breite reagieren auf Druck; Neigung beeinflusst Winkel (wenn unterstützt). Striche gehen beim Schließen verloren.

**Löschen** — Entfernt alle Striche.

[info]

## Live-Eingabe

Der Bereich zeigt Echtzeit-Werte: X/Y, Druck, Neigung, Rotation, Schwebeabstand, Tasten. Diagnose für unerwartetes Verhalten.

## Diagnose

Der Bereich zeigt Echtzeit-Werte: X/Y, Druck, Neigung, Rotation, Schwebeabstand, Tasten. Diagnose für unerwartetes Verhalten.

## Gerätedaten erfassen

**Gerätedaten erfassen** führt eine geleitete Aufzeichnung der rohen HID-Berichte durch. Ergebnis ist kompaktes JSON für Support-Anfragen.

[website]

## mocktab.org

[mocktab.org](https://mocktab.org) — Dokumentation, Release Notes, Hardware-Liste.

## GitHub

Fehlerberichte und Fragen zu [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues).
