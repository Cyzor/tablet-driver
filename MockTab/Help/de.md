[about]

## Grafiktabletts

Ein Grafiktablett ist ein Eingabegerät mit Stift, das absolute Position, Druck, Neigung und Rotation meldet.

## MockTab

MockTab ist ein macOS-Treiber für Wacom- und Xencelabs-Grafiktabletts. Unterstützt werden USB- und Bluetooth-Grafiktabletts aus den Wacom-Familien Intuos, Cintiq, Bamboo und Intuos Pro — mit besonderem Fokus auf Hardware, die Wacoms eigener Treiber auf aktuellen macOS-Versionen nicht mehr unterstützt — sowie Xencelabs-Stifttabletts und Pen-Displays.

[tabletArea]

## Aktiver Bereich

Der aktive Bereich ist der Teil der Grafiktablett-Oberfläche, der auf den Bildschirm abgebildet wird. Stifteingaben außerhalb dieses Rechtecks haben keine Wirkung.

**Größe ändern** – Ziehe einen beliebigen Griff in der Vorschau, um den aktiven Bereich zu verschieben oder zu skalieren. Halte beim Ziehen einer Ecke **Shift** gedrückt, um das Seitenverhältnis an die Display-Proportionen zu binden. Genaue Werte kannst du auch in die Felder Width und Height eingeben.

**Proportionale Projektion** – Hält das Verhältnis zwischen Grafiktablett und Bildschirm proportional, sodass der Cursor horizontal und vertikal gleich weit zurücklegt. Deaktiviere diese Option, wenn du das Mapping absichtlich strecken oder stauchen willst.

**Auf Vollbereich zurücksetzen** – Stellt den aktiven Bereich auf die gesamte Grafiktablett-Oberfläche zurück. Diese Aktion lässt sich mit ⌘Z rückgängig machen.

## Kalibrierung (Pen-Displays)

Die Schaltfläche **Kalibrieren…** öffnet ein Vollbild-Overlay mit Fadenkreuzen, die du mit der Stiftspitze antippst. Dieser Vorgang korrigiert den Parallaxenversatz zwischen Stiftspitze und Bildschirmcursor, der durch das Displayglas entsteht.

Nach der Kalibrierung kannst du mit **Zeiger-Versatz** einen kleinen konstanten Versatz nachjustieren, zum Beispiel wenn sich die Parallaxe je nach Blickwinkel leicht verändert.

[penFeel]

## Druckkurve

Die Druckkurve steuert, wie Stiftdruck auf Ausgabedruck abgebildet wird. Eine konkave Kurve (nach oben gezogen) lässt leichte Striche kräftiger wirken; eine konvexe Kurve (nach unten gedrückt) verlangt mehr Kraft für denselben Effekt.

**Voreinstellungen** – Linear, Weich und Fest. Wenn du eine Voreinstellung auswählst, wird die Kurve gesetzt; sobald du einen Kurvenpunkt verschiebst, wechselt sie automatisch zu einer benutzerdefinierten Form.

## Druckglättung

Dämpft Druckrauschen im unteren Bereich des Sensorbereichs, das sich sonst bei langsamen, leichten Strichen als ungleichmäßige Linienbreite zeigt. Kräftiger Druck bleibt unverändert.

## Stabilisierung

Reduziert Cursorzittern durch Handunruhe. Höhere Werte glätten stärker, erhöhen aber die Eingabelatenz.

## Doppelklick-Abstand

Diese Einstellung legt fest, wie nah zwei Tippbewegungen beieinanderliegen müssen, um als Doppelklick zu zählen. Erhöhe den Wert, wenn Doppelklicks nicht erkannt werden; senke ihn, wenn beim normalen Zeichnen versehentlich Doppelklicks entstehen. Ziehe den Regler auf Off, um das Positions-Snapping zu deaktivieren.

## Bewegung

**Drehrichtung umkehren** – Kehrt die Drehrichtung des Stifts um. Aktiviere das pro App für Anwendungen, die Rotation verkehrt interpretieren, zum Beispiel Krita.

**Art Pen: Neigung mit Rotation tauschen** – Leitet die Barrel-Rotation in Photoshops Pen-Tilt-Steuerung um, indem simulierte Neigungsdaten gesendet werden; echte Neigung wird dabei unterdrückt. Verwende es unter Brush Dynamics → Shape Dynamics → Angle → Pen Tilt. Nach dem Aktivieren erscheinen die Regler Tilt Offset und Tilt Magnitude, um das simulierte Signal fein abzustimmen.

**Relative Cursorbewegung** – Wechselt vom absoluten Modus (jeder Punkt auf dem Grafiktablett entspricht einem festen Punkt auf dem Bildschirm, wie bei einem Stift) in den relativen Modus (der Cursor bewegt sich um die Strecke, die du den Stift bewegst, wie bei einer Maus).

## Pan View

Legt fest, wie schnell sich Inhalte verschieben, während eine Pan-View-Taste gedrückt gehalten wird. Weise die Aktion Pan View in Button Mapping einer Stifttaste, Express-Taste oder Puck-Taste zu, um sie zu nutzen.

Pan View läuft nach dem Loslassen kurz nach, wenn die zugehörige Trägheitseinstellung (in Stiftgefühl) aktiv ist. Die Reaktion hängt von der App ab.

## Klickverhalten

**Aufhebehilfe** – Hält den Stiftklick nach dem Abheben der Spitze noch kurz offen, wenn du dich weiterhin schnell bewegst, damit schnelle Zeichenzüge nicht unbeabsichtigt unterbrochen werden. Ziehe den Regler auf Off, um die Funktion auszuschalten.

**Ziehschwelle** – Verlangt, dass sich der Stift erst eine Mindeststrecke bewegt, bevor aus einem Tippen ein Ziehen wird. Das fängt Zittern beim Aufsetzen ab, damit leichte Tipper nicht versehentlich zu Drag-Aktionen werden. Ziehe den Regler auf Off, um die Funktion auszuschalten.

[buttons]

## Stiftdiagramm

Drücke bei geöffnetem Fenster eine beliebige Taste, um ihre Position hervorzuheben; so erkennst du, welcher physische Knopf welchem Zuordnungsslot entspricht. Wenn du auf einen Teil des Diagramms klickst — die Spitze, den Radierer oder eine Barrel-Taste — startet die Aufzeichnung einer neuen Zuordnung dafür.

**Hover drag** – Halte Button 1 (die untere Barrel-Taste) gedrückt, während der Stift über der Oberfläche schwebt, um den Cursor ohne Spitzenkontakt zu bewegen und Drag-Gesten in der Luft auszuführen.

## Zuordnungstypen

- **Maustasten** – Links-, Rechts-, Mittelklick oder Doppelklick  
- **Tastaturkürzel** – Klicke ins Shortcut-Feld und drücke eine beliebige Tastenkombination  
- **Gehaltene Modifikatortasten** – ⌘ ⌥ ⇧ ⌃ bleiben gedrückt, solange die Taste gehalten wird  
- **Spezialaktionen** – Anzeige umschalten, Radierer, Auswahl des Touch-Ring-Modus  

## Berührungsring und Dial

Ringe, Dials und Touch-Strips unterstützen mehrere Modusslots. Jeder Modus erscheint als kurze Ein-Zeilen-Zusammenfassung; ein Klick auf eine Moduszeile — oder auf ihren Keil im Diagramm neben der Liste — öffnet die Einstellungen direkt an Ort und Stelle: Aktion, Geschwindigkeit und die Shortcuts für jede Richtung. Weise Touch-Ring-Modus → **Wechseln** einer Taste zu, um durch die Modi zu schalten, oder **Zu Modus springen**, um direkt zu einem bestimmten Modus zu springen.

## Beleuchtung

Einige Geräte haben konfigurierbare Beleuchtung. Bei Hardware mit beleuchtetem Dial-Ring enthalten die Einstellungen jedes Modus die Farbe und Helligkeit, die angezeigt werden, solange dieser Modus aktiv ist. Pen-Displays mit hinterleuchteten Rahmentasten haben eine Zeile **Tastenbeleuchtung**. Die Hardware behält ihre letzte Farbe, bis du sie änderst.

## Radierer

Die Radiererspitze hat eine eigene Belegung, die im Stiftbereich konfiguriert wird. Manche Zeichenprogramme wechseln automatisch zum Radiergummi-Werkzeug, wenn sie Radierer-Proximity-Ereignisse empfangen.

## App-spezifische Overrides

Über die Override-Leiste oben kannst du für eine bestimmte Anwendung andere Tastenbelegungen festlegen. Die Overrides werden automatisch aktiv, sobald diese App in den Vordergrund kommt. In allen anderen Fällen gelten die globalen Einstellungen.

[touch]

## Berührung

Grafiktabletts mit kapazitiver Touch-Oberfläche melden Fingerkontakte zusätzlich zur Stifteingabe. MockTab lässt das standardmäßig ausgeschaltet; aktiviere **Fingereingabe aktivieren**, um es zu verwenden. Die Reaktion hängt von der App ab.

**Tippen zum Klicken** – Eine kurze Berührung ohne nennenswerte Bewegung sendet einen Linksklick.

**Zeigergeschwindigkeit** – Skaliert die Zeigerbewegung bei einer Ein-Finger-Drag-Geste. Niedrigere Werte erlauben feinere Kontrolle, höhere decken mit weniger Bewegung mehr Strecke ab.

## Gesten

**Scrollen mit zwei Fingern** – Mit zwei Fingern in eine Richtung streichen. Apps behandeln dies in der Regel wie Scrollen mit einem Trackpad.

**Zum Zoomen zusammenziehen** – Zwei Finger spreizen oder zusammenziehen, um zu zoomen.

**Drehen** – Zwei Finger auf das Tablett legen und im oder gegen den Uhrzeigersinn drehen, um die Ansicht zu rotieren.

**Richtung umkehren** – Der Inhalt bewegt sich entgegengesetzt zur Fingerbewegung, wie bei einem klassischen Mausrad.

**Scrollen mit Nachlauf** – Nach dem Abheben der Finger läuft der Scrollvorgang kurz nach, ähnlich wie beim Trackpad. Schalte die Option für Apps aus, die mit diesem Effekt nicht gut zurechtkommen. Die Reaktion hängt von der App ab.

## Berührungsbereich

Der Berührungsbereich arbeitet unabhängig vom aktiven Stiftbereich. Ziehe die Griffe in der Vorschau, um die verfügbare Touch-Fläche zuzuschneiden. Fingereingaben außerhalb des Rechtecks haben keine Wirkung.

**Auf volle Fläche zurücksetzen** – Stellt den Touch-Bereich auf die gesamte touchfähige Fläche zurück.

## Einschränkungen

MockTab unterstützt aktuell kein Mission Control, Spaces, Launchpad oder App Exposé per Touch.

[display]

## Anzeigezuordnung

Die Anzeigezuordnung legt fest, welcher Bildschirm dem Grafiktablett zugeordnet ist.

**Alle Displays** – Shift-Klick auf ein beliebiges Display im Diagramm spannt proportional über den gesamten Desktop. Eignet sich für Arbeitsabläufe über mehrere Monitore hinweg.

**Einzelnes Display** – Klicke im Diagramm auf ein Display, um den aktiven Bereich genau darauf abzubilden.

**Anzeige umschalten** – Weise die Aktion Anzeige umschalten einer Express-Taste oder Barrel-Taste zu, um zwischen angeschlossenen Displays zu wechseln, ohne die Einstellungen zu öffnen.

[devices]

## Verbundene Geräte

Unter Devices siehst du alle Grafiktabletts und Stiftwerkzeuge, die MockTab erkannt hat. Neben dem Namen stehen Verbindungsart (USB oder Bluetooth) und Status.

Wählst du ein Gerät aus, erscheinen rechts die passenden Einstellungen und Werkzeuge.

Auch nicht verbundene Geräte bleiben in der Liste, damit du ihre Profile prüfen oder anpassen kannst. Sobald ein Gerät wieder verbunden wird, übernimmt MockTab automatisch die gespeicherten Einstellungen.

## Konflikterkennung

Wenn gleichzeitig ein anderer Grafiktablett-Treiber läuft, etwa der offizielle Wacom-Treiber, versucht MockTab den Konflikt zu erkennen und eine Warnung anzuzeigen.

[profiles]

## Profile

Ein Profil ist eine Momentaufnahme der Grafiktablett-Einstellungen: aktiver Bereich, Druckkurve, Tastenbelegungen und Display-Mapping. Beim Wechseln eines Profils werden all diese Einstellungen sofort angewendet.

**Automatisches Umschalten** – Wechselt automatisch zum passenden Profil, sobald dessen Grafiktablett verbunden wird.

## Erstellen und Umbenennen

Klicke auf **Profil erstellen**, um die aktuellen Einstellungen als neues Profil zu speichern. Mit einem Doppelklick auf einen Profilnamen kannst du ihn umbenennen.

## App-spezifische Overrides in Profilen

Profile speichern ihre eigenen app-spezifischen Overrides. Wenn du das Profil wechselst, wechseln auch die Overrides, die zum aktiven Profil gehören.

## Importieren / Exportieren

Ziehe eine Profilkarte in den Finder, um sie als JSON-Datei zu exportieren. Ziehe eine JSON-Datei auf die Profilliste, um sie zu importieren. Exportierte Dateien eignen sich als Backup und zum Teilen von Profilen zwischen Rechnern.

[scratchpad]

## Testbereich

Der Testbereich ist eine druckempfindliche Testfläche. Damit lässt sich schnell prüfen, ob der Stift Druck, Neigung und Bewegung korrekt meldet.

Sowohl Deckkraft als auch Breite des Strichs reagieren auf den Spitzendruck. Die Neigung beeinflusst den Strichwinkel, wenn der Stift Neigungsdaten unterstützt. Das Panel speichert keine Striche; beim Schließen oder Leeren wird der Inhalt verworfen.

**Löschen** – Entfernt alle Striche von der Zeichenfläche.

[info]

## Live-Eingabe

Der Info-Bereich zeigt Echtzeitwerte des Stifts an: X/Y-Position, Druck, Neigung, Rotation, Hover-Abstand und Tastenstatus. Diese Werte werden laufend aktualisiert, solange sich der Stift im Erkennungsbereich befindet.

Diese Ansicht hilft bei der Diagnose unerwarteten Verhaltens, zum Beispiel um zu prüfen, ob der Druck seinen Maximalwert erreicht oder ob das Grafiktablett überhaupt Neigung meldet.

## Gerätedaten erfassen

**Gerätedaten erfassen** zeichnet auf, was das Grafiktablett bei der Benutzung sendet. Das Ergebnis ist eine kompakte JSON-Datei, die sich an eine Anfrage anhängen lässt, mit der Unterstützung für ein Gerät hinzugefügt oder verbessert werden soll.

[website]

## mocktab.org

Die Website [mocktab.org](https://mocktab.org) bietet Dokumentation, Release Notes und die vollständige Liste unterstützter Hardware.

## GitHub

Bugmeldungen und Fragen gehören nach [github.com/Cyzor/tablet-driver/issues](https://github.com/Cyzor/tablet-driver/issues).

## Danksagung

MockTabs Gerätedaten und Protokollrecherche bauen auf der Arbeit von zwei Open-Source-Projekten auf: [OpenTabletDriver](https://opentabletdriver.net/), dessen Gerätekonfigurationen Modelle vieler Hersteller abdecken, und dem [Linux Wacom Project](https://linuxwacom.github.io/), der maßgeblichen Quelle für Wacom-Geräteabmessungen über die libwacom-Bibliothek.
