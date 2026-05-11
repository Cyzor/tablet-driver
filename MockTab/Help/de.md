[about]

## Grafiktabletts

Ein Grafiktablett ist ein Eingabegerät mit einem akkufreien Stift, der absolute Position, Druck, Neigung und manchmal Rotation überträgt. Anders als eine Maus landet der Stift genau dort, wo du ihn aufsetzt, und Zeichen-Apps können auf den Druckgrad reagieren — digitales Arbeiten fühlt sich damit näher am Papier an.

## MockTab

MockTab ist ein nativer macOS-Treiber für Wacom-Grafiktabletts. Er unterstützt USB- und Bluetooth-Tabletts der Familien Intuos, Cintiq, Bamboo und Intuos Pro — Hardware, die Wacoms eigener Treiber auf modernen macOS-Versionen nicht mehr unterstützt.

MockTab läuft vollständig im User Space, ohne Kernel-Erweiterung und ohne Hintergrunddienst. Einmal eingerichtet, hält er sich aus dem Weg.

[tabletArea]

## Aktiver Bereich

Der aktive Bereich ist der Teil der Tablett-Oberfläche, der auf deinen Bildschirm abgebildet wird. Stifteingaben außerhalb dieses Rechtecks werden ignoriert.

**Größe ändern** — Ziehe einen Anfasser in der Vorschau, um den aktiven Bereich zu verschieben oder zu vergrößern/verkleinern. Halte **Shift** beim Ziehen einer Ecke, um das Seitenverhältnis an deinen Bildschirm anzupassen. Du kannst auch genaue Werte in die Felder Width und Height eingeben.

**Lock Aspect Ratio** — Hält das Tablette-zu-Bildschirm-Verhältnis proportional, sodass der Zeiger horizontal und vertikal gleiche Strecken zurücklegt. Deaktiviere die Option, wenn du die Zuordnung bewusst strecken oder stauchen möchtest.

**Reset to Full** — Stellt den aktiven Bereich auf die gesamte Tablett-Oberfläche zurück. Diese Aktion ist rückgängig machbar (⌘Z).

## Kalibrierung (Pen-Displays)

Der **Calibrate**-Button öffnet eine Vollbild-Überlagerung, in der du Fadenkreuz-Ziele mit deiner Stiftspitze antippst. Das korrigiert den Parallaxen-Versatz zwischen Stiftspitze und Bildschirmzeiger, der durch das Display-Glas entsteht.

Nach der Kalibrierung nutze **Manual Fine-Tune**, falls ein kleiner konstanter Versatz verbleibt — zum Beispiel wenn sich die Parallaxe je nach Blickwinkel leicht verschiebt.

[penFeel]

## Druckkurve

Die Druckkurve steuert, wie der Stiftdruck auf den Ausgabedruck abgebildet wird. Eine konkave Kurve (nach oben gezogen) lässt leichte Striche stärker erscheinen; eine konvexe Kurve (nach unten gedrückt) erfordert mehr Kraft für denselben Effekt.

**Tip Feel-Voreinstellungen** — Soft, Medium, Firm und Custom. Eine Voreinstellung wählen setzt die Kurve; das manuelle Anpassen eines Kurvenpunkts wechselt automatisch zu Custom.

## Glättung

Die Glättung reduziert hochfrequentes Zittern im Eingabesignal. Höhere Werte erzeugen sauberere Striche, aber mit einem kleinen Verzug am Anfang und Ende jedes Strichs. Für schnelles, gestisches Arbeiten fühlen sich niedrigere Werte direkter an.

## Doppelklick-Abstand

Legt fest, wie nah zwei Antipper beieinander sein müssen, um als Doppelklick zu gelten. Erhöhe den Wert, wenn Doppelklicks nicht erkannt werden; verringere ihn, wenn beim normalen Zeichnen versehentliche Doppelklicks auftreten.

[buttons]

## Stift-Diagramm

Das Diagramm oben zeigt die Tasten deines Stifts. Drücke eine Taste, während das Fenster geöffnet ist, um sie hervorgehoben zu sehen — nützlich, um herauszufinden, welche physische Taste welchem Zuordnungsslot entspricht.

## Zuordnungstypen

- **Maustasten** — Linksklick, Rechtsklick, Mittelklick oder Doppelklick
- **Tastaturkürzel** — Klicke in das Kürzelfeld und drücke eine beliebige Tastenkombination
- **Modifikator-Halten** — ⌘ ⌥ ⇧ ⌃ werden so lange gehalten, wie die Taste gedrückt ist
- **Sonderaktionen** — Display Toggle, Eraser, Touch-Ring-Modusauswahl

## Touch-Ring

Der Ring unterstützt mehrere Modusslots. Jeder Slot hat seine eigene Aktion im und gegen den Uhrzeigersinn (Scrollen, Zoomen oder Tastenwiederholen). Weise **Ring Cycle** einer Taste zu, um die Modi durchzuschalten, oder **Ring: Slot N**, um direkt zu einem bestimmten Slot zu springen. Der **Geschwindigkeitsmultiplikator** steuert, wie schnell Aktionen pro Grad Drehung ausgelöst werden.

## Radiergummi

Die Radiergummispitze hat ihre eigene Belegung, die im Stift-Bereich konfiguriert wird. Die meisten Zeichen-Apps wechseln automatisch zum Radierwerkzeug, wenn sie Radiergummi-Näherungsereignisse empfangen — eine spezielle Belegung ist nur nötig, wenn du dieses Verhalten überschreiben möchtest.

## App-spezifische Overrides

Die Override-Leiste oben erlaubt es dir, für eine bestimmte App andere Tasten zuzuweisen. Overrides aktivieren sich automatisch, wenn diese App in den Vordergrund kommt. Globale Einstellungen gelten überall sonst.

[display]

## Display-Zuordnung

Die Display-Zuordnung steuert, auf welchen Bildschirm der aktive Bereich des Tabletts abgebildet wird.

**All Displays** — Das Tablett spannt sich proportional über den gesamten Desktop. Verwende diese Option, wenn du über mehrere Monitore hinweg arbeitest.

**Single Display** — Der aktive Bereich wird einem bestimmten Display zugeordnet. Wähle ein Display aus der Liste; die Vorschau aktualisiert sich entsprechend.

**Display Toggle** — Weise die Display Toggle-Aktion einer Express-Taste oder Barrel-Taste zu, um ohne Öffnen der Einstellungen durch die angeschlossenen Displays zu wechseln.

[devices]

## Verbundene Geräte

Der Geräte-Bereich listet alle Tabletts und Stift-Tools auf, die MockTab erkannt hat. Jede Zeile zeigt Gerätename, Verbindungstyp (USB oder Bluetooth) und aktuellen Status.

## Tool-Registrierung

Wenn ein Stift erkannt wird, speichert MockTab seinen Tool-Code. Wird ein Tool-Code nicht erkannt, erscheint er in der Registrierung als „Unknown tool". Du kannst unbekannten Tools manuell einen Namen und eine Spitzenbelegung zuweisen.

## Konflikt-Erkennung

Wenn ein anderer Tablett-Treiber (z. B. der offizielle Wacom-Treiber) läuft, erkennt MockTab den Konflikt und zeigt eine Warnung an. Wenn zwei Treiber um dasselbe HID-Gerät konkurrieren, kann es zu unvorhersehbarem Verhalten kommen; beende den konkurrierenden Treiber, bevor du MockTab verwendest.

[profiles]

## Profile

Ein Profil ist ein gespeicherter Schnappschuss aller Tablett-Einstellungen — aktiver Bereich, Druckkurve, Tasten-Zuordnungen und Display-Zuordnung. Das Wechseln von Profilen übernimmt alle Einstellungen sofort.

**Auto-restore** — Aktiviere den Schalter an einem Profil, damit MockTab es automatisch aktiviert, wenn dieses Tablett angeschlossen wird.

## Erstellen und Umbenennen

Klicke auf **Save as New Profile**, um die aktuellen Einstellungen zu speichern. Doppelklicke auf einen Profilnamen, um ihn umzubenennen.

## App-spezifische Overrides in Profilen

App-spezifische Overrides werden als Teil des aktiven Profils gespeichert. Wenn du Profile wechselst, wechseln die Overrides mit.

## Import / Export

Ziehe eine Profilkarte in den Finder, um sie als JSON-Datei zu exportieren. Ziehe eine JSON-Datei auf die Profilliste, um sie zu importieren. Exportierte Dateien können zwischen Geräten geteilt oder als Backup verwendet werden.

[scratchpad]

## Scratchpad

Das Scratchpad ist eine druckempfindliche Testfläche. Zeichne darauf, um zu überprüfen, dass dein Stift Druck, Neigung und Strichposition korrekt erfasst, bevor du eine Zeichen-App verwendest.

Deckkraft und Breite der Striche reagieren beide auf den Spitzendruck. Die Neigung beeinflusst den Strichwinkel, wenn der Stift dies unterstützt.

**Clear** — Entfernt alle Striche von der Fläche. Das lässt sich nicht rückgängig machen.

[info]

## Live-Eingabe

Der Info-Bereich zeigt Echtzeit-Werte deines Stifts: X/Y-Position, Druck, Neigung, Rotation, Schwebeabstand und Tastenzustand. Diese Werte aktualisieren sich laufend, solange der Stift in Reichweite ist.

Das ist hilfreich beim Diagnostizieren von unerwartetem Verhalten — zum Beispiel, um zu prüfen, ob der Druck seinen Maximalwert erreicht oder ob Neigung überhaupt gemeldet wird.

## Diagnose

Der **Copy Diagnostics**-Button erstellt einen Text-Schnappschuss des aktuellen Treiberzustands — App-Version, macOS-Version, verbundene Geräte und Eingabe-Statistiken. Füge ihn in einen Fehlerbericht oder eine Support-Anfrage ein.

## Collect Device Data

**Collect Device Data** führt eine angeleitete Aufzeichnungssitzung durch, die die rohen HID-Berichte deines Tabletts aufzeichnet. Das Ergebnis ist eine kompakte JSON-Datei, die du einer Feature-Anfrage anhängen kannst, um die Unterstützung für dein Gerät hinzuzufügen oder zu verbessern.

[website]

## mocktab.org

Die MockTab-Website unter [mocktab.org](https://mocktab.org) enthält Dokumentation, Release Notes und die vollständige Liste unterstützter Hardware.

## GitHub

Fehlerberichte und Fragen gehen an [github.com/Cyzor/mocktab-app](https://github.com/Cyzor/mocktab-app/issues). Der **Copy Diagnostics**-Button im Info-Bereich erstellt einen Text-Schnappschuss deines Treiberzustands — füge ihn Fehlerberichten bei.
