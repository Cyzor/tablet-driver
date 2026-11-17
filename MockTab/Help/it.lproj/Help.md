[about]

## Tavolette grafiche

Una tavoletta grafica è un dispositivo di input con una penna che comunica posizione assoluta, pressione, inclinazione e rotazione.

## MockTab

MockTab è un driver per macOS per le tavolette grafiche Wacom e Xencelabs. È pensato per le tavolette USB e Bluetooth delle famiglie Wacom Intuos, Intuos Pro, Cintiq, Bamboo e Graphire, oltre ad alcuni modelli Xencelabs. Si concentra sull’hardware che il driver di Wacom non supporta più nelle versioni recenti di macOS.

## Rimuovere MockTab

Esci da MockTab e spostalo nel Cestino. Per rimuovere anche le impostazioni, apri ogni elemento qui sotto nel Finder con **Vai alla cartella** (⇧⌘G) e spostalo nel Cestino:

- `~/Library/Preferences/com.cyzor.mocktab.plist` – impostazioni  
- `~/Library/Application Support/com.cyzor.mocktab` – impostazioni precedenti, salvate ogni volta che si avvia una versione diversa  

[tabletArea]

## Area attiva

L’area attiva è la parte della superficie della tavoletta mappata sullo schermo. La penna non ha effetto fuori da questo rettangolo.

**Ridimensionare** – Trascina l’area o le sue maniglie; quando è vicina si aggancia alla forma dell’area dello schermo (tieni premuto **⌘** per evitarlo, **⇧** per mantenerne la forma). Fai clic sulla larghezza o sull’altezza qui sotto per inserire una misura esatta.

**Mappatura proporzionale** – Mantiene uguali gli spostamenti orizzontali e verticali del cursore. Disattivala per allungare o comprimere la mappatura.

**Ripristina area completa** – Ripristina l’intera superficie della tavoletta. ⌘Z annulla l’operazione.

## Orientamento

Scegli l’orientamento che corrisponde alla posizione attuale della tavoletta (da ⌘⌥1 a ⌘⌥4 nel pannello Area della tavoletta). Penna, tocco e inclinazione seguono la scelta, e il pannello Pulsanti disegna la tavoletta di conseguenza.

Ruotando la tavoletta, ogni assegnazione passa al tasto che ora ne occupa il posto, in tutti i profili e in tutte le eccezioni per app. Annulla ripristina entrambe le cose insieme.

**Capovolgi assegnazioni** – Fai clic con il pulsante destro sul disegno della tavoletta nel pannello Pulsanti per scambiare ogni assegnazione con il tasto opposto senza cambiare l’orientamento. Sceglilo di nuovo per ripristinarle.

## Calibrazione (display interattivi)

**Calibra…** apre una schermata a tutto schermo con mirini da toccare con la punta della penna. Corregge lo scarto di parallasse che il vetro del display crea tra la punta della penna e il cursore.

**Scostamento del puntatore** regola il piccolo scarto che può restare, come una parallasse che cambia con l’angolo di visione.

[penFeel]

## Curva di pressione

La curva fa corrispondere la pressione della penna alla pressione in uscita. Tirandola verso l’alto i tratti leggeri risultano più marcati; spingendola verso il basso serve più forza per lo stesso effetto.

**Preimpostazioni** – Lineare, Morbida e Rigida. Modificando un punto della curva si passa a una forma personalizzata.

## Smussatura della pressione

Attenua il rumore di pressione nella parte bassa dell’intervallo, visibile come spessore irregolare nei tratti lenti e leggeri. La pressione decisa resta invariata.

## Stabilizzazione

Riduce il tremolio del cursore dovuto alla mano. I valori alti smussano di più, ma possono aggiungere ritardo.

## Distanza del doppio clic

Stabilisce quanto devono essere vicini due tocchi per valere come doppio clic. Aumentala se i doppi clic non riescono; riducila se disegnando ne partono di involontari. Su Disattivato, il secondo tocco deve cadere più o meno dove è caduto il primo.

## Movimento

**Inverti direzione di rotazione** – Inverte il verso di rotazione di una penna che ruota sul proprio asse, come la Art Pen. Attivalo per app in quelle che leggono la rotazione al contrario, come Krita.

**Movimento relativo del cursore** – passa dalla modalità assoluta (ogni punto della tavoletta corrisponde a un punto fisso dello schermo) alla modalità relativa (il cursore si sposta della distanza percorsa dalla penna, come un mouse).

## Sposta vista

**Velocità** – Stabilisce la velocità con cui scorre il contenuto mentre tieni premuto un pulsante Sposta vista. Assegna l’azione Sposta vista a un pulsante della penna, a un ExpressKey o a un pulsante del Quick Keys nel pannello Pulsanti.

**Inverti direzione** – Attivo: il contenuto si muove in senso opposto alla penna, come con una classica rotella del mouse. Disattivo: il contenuto segue la penna.

**Scorrimento con inerzia** – Il contenuto prosegue brevemente per inerzia dopo il rilascio del pulsante. Alcune app lo fanno comunque per conto loro.

## Comportamento del clic

**Richiedi contatto** – seleziona Clic destro, Clic centrale, Doppio clic o Sposta vista perché i pulsanti laterali con quell’azione agiscano solo mentre la penna tocca la superficie. Le azioni non selezionate funzionano anche con la punta sollevata.

Tenendo premuto un pulsante impostato su Clic sinistro, Clic destro o Clic centrale mentre la penna è in prossimità, trascini senza toccare la superficie. Selezionando Richiedi contatto per Clic destro o Clic centrale, questo comportamento si disattiva per quei pulsanti.

**Assistenza al sollevamento** – mantiene brevemente il clic dopo aver sollevato la punta mentre la penna si muove ancora velocemente, evitando interruzioni del tratto nel disegno rapido. Trascina su Disattivato per disattivarla.

**Soglia di trascinamento** – richiede un movimento minimo della penna prima che un tocco diventi un trascinamento, così un tremito all’appoggio della punta non trasforma i tocchi leggeri in trascinamenti. Trascina su Disattivato per disattivarla.

[buttons]

## Schema della penna

Premi un pulsante qualsiasi a finestra aperta per evidenziarne la posizione; aiuta a capire quale pulsante fisico corrisponde a quale assegnazione. Fai clic sulla punta, sulla gomma o su un pulsante laterale nello schema per registrarne una nuova assegnazione.

## Mouse

Un mouse Wacom ha il proprio schema e le proprie righe di pulsanti. I primi tre pulsanti partono come Clic sinistro, Clic destro e Clic centrale.

## Schema della tavoletta

Lo schema mostra la posizione di tasti, anelli e ghiere di una tavoletta. Fai clic su un elemento per assegnargli un’azione.

## Tipi di assegnazione

- **Pulsanti del mouse** – Clic sinistro, Clic destro, Clic centrale, Doppio clic e Blocco del clic, che tiene premuto il pulsante sinistro fino alla pressione successiva  
- **Abbreviazioni da tastiera** – fai clic sul campo dell’abbreviazione e premi una combinazione di tasti  
- **Tasti modificatori** – ⌘ ⌥ ⇧ ⌃ tenuti premuti finché il pulsante resta premuto  
- **Azioni speciali** – Sposta vista, Gomma, Barra spaziatrice, Esc, da F13 a F19, Cambia monitor, Estendi sui monitor, Attiva o disattiva modalità relativa, Mostra impostazioni di MockTab e le modalità di anelli, ghiere e strisce  
- **Apri** – trascina un’app, un file, un link o una macro di Keyboard Maestro sulla riga di un pulsante. Un punto interrogativo indica che la destinazione non c’è più. Per digitare o correggere un URL, fai clic con il pulsante destro sulla riga e scegli Modifica URL  

Per eseguire uno script, un flusso di lavoro di Automator o un comando rapido, salvalo come app e trascina quella, oppure assegnagli un’abbreviazione da tastiera in Impostazioni di Sistema o in Comandi Rapidi e assegna l’abbreviazione.

## Touch Ring e ghiera

Anelli, ghiere e strisce touch hanno ciascuno le proprie modalità. Fai clic su una modalità, o sul suo spicchio nello schema, per cambiarne le impostazioni. Per cambiare modalità da un pulsante, assegna **Scorri** o **Vai alla modalità**.

**Scorrimento** – Funziona come una rotella di scorrimento. A 1×, ogni scatto scorre di una riga.

**Zoom** e **Ruota** – Ingrandiscono o ruotano l’area di lavoro, come un pizzico o una rotazione sul trackpad. La velocità va da Disattivato a Max; a Max, un giro dell’anello fa compiere un giro completo all’area di lavoro. Il supporto varia a seconda dell’app.

**Tasto** – Invia un’abbreviazione da tastiera per ciascuna direzione.

## Display dei tasti

Una Intuos4 con display dei tasti mostra via USB l’azione di ogni tasto accanto al tasto stesso, e i display si attenuano quando è inattiva.

## Illuminazione

Alcuni dispositivi hanno luci configurabili. Sull’hardware con un anello luminoso attorno alla ghiera, le impostazioni di ogni modalità comprendono il colore e la luminosità mostrati mentre quella modalità è attiva. I display interattivi con pulsanti della cornice retroilluminati hanno una riga **Retroilluminazione dei pulsanti**. L’hardware mantiene l’ultimo colore finché non lo cambi.

## Gomma

La gomma ha una propria assegnazione, configurata nella sezione della penna. Alcune app di disegno passano automaticamente allo strumento gomma quando la gomma della penna si avvicina alla tavoletta. Imposta un pulsante laterale su Gomma per usare la penna come gomma mentre tieni premuto il pulsante: utile per le penne senza gomma.

## Eccezioni per app

La barra delle eccezioni per app in alto assegna pulsanti diversi a un’applicazione specifica. Le eccezioni si attivano automaticamente quando quell’app passa in primo piano. In tutti gli altri casi valgono le impostazioni globali.

[touch]

## Tocco

Le tavolette con superficie touch capacitiva comunicano i contatti delle dita insieme all’input della penna. MockTab lo tiene disattivato di default. Attiva **Attiva tocco delle dita** per usarlo. La risposta varia a seconda dell’app.

**Tocca per fare clic** – Un tocco breve quasi senza muoversi produce un clic sinistro.

**Clic destro con due dita** – Un tocco breve con due dita, a un dito di distanza, produce un clic destro.

**Trascinamento con tre dita** – Tre dita appoggiate insieme tengono premuto il pulsante del mouse. Muovile per trascinare, sollevale per rilasciare.

**Velocità del cursore** – Regola lo spostamento del puntatore nel trascinamento con un dito. I valori bassi danno un controllo più fine, quelli alti coprono più distanza con meno movimento.

## Gesti

**Scorrimento con due dita** – Scorri con due dita in una direzione. In genere le app lo trattano come lo scorrimento del trackpad.

**Pizzica per ingrandire** – Allarga o avvicina due dita per ingrandire o ridurre.

**Ruota** – Appoggia due dita ben distanziate sulla tavoletta e ruotale attorno al loro centro. Scorrimento, pizzico e rotazione leggono lo stesso gesto a due dita in modi diversi.

**Inverti direzione** – Attivo: il contenuto si muove in senso opposto alle dita, come con una classica rotella del mouse.

**Scorrimento con inerzia** – Lo scorrimento con due dita prosegue brevemente dopo aver sollevato le dita, come l’inerzia del trackpad.

## Area touch

L’area touch è indipendente dall’area attiva della penna. Trascina le maniglie nell’anteprima per ritagliare la superficie touch disponibile. Le dita non hanno effetto fuori dal rettangolo.

**Ripristina superficie completa** – Riporta l’area touch all’intera zona sensibile al tocco.

## Limiti

MockTab non supporta Mission Control, Spaces, Launchpad o App Exposé con il tocco.

[display]

## Mappatura del display

La mappatura del display stabilisce quale schermo la tavoletta considera attivo.

**Tutti i monitor** – Fai clic tenendo premuto Maiuscole su un monitor nello schema per coprire in proporzione l’intera scrivania. Adatto a chi lavora su più monitor.

**Un solo monitor** – Fai clic su un monitor nello schema per mappare l’area attiva solo su quello.

**Cambia monitor** – Cambia monitor da un pulsante. Fai ⌘-clic sui monitor nello schema per scegliere quelli tra cui passa.

**Estendi sui monitor** – Premi un pulsante assegnato a Estendi sui monitor per estendere la penna sui monitor selezionati in Monitor attivi, e premilo di nuovo per tornare all’impostazione abituale. Se non ne è selezionato nessuno, li copre tutti.

## Area dello schermo

Come l’area attiva, ma dal lato dello schermo: ritaglia la parte del monitor che la penna può raggiungere.

**Seleziona sullo schermo…** – Trascina l’area direttamente sulla scrivania, come con lo strumento per le istantanee di macOS.

**Usa tutto lo schermo** – Ripristina il monitor intero.

[devices]

## Dispositivi collegati

Il pannello Dispositivi elenca ogni tavoletta e ogni penna rilevata da MockTab. Ogni riga mostra il nome del dispositivo, il tipo di connessione (USB o Bluetooth) e lo stato attuale.

Selezionando una riga, il pannello dei dettagli a destra mostra le impostazioni specifiche del modello e le penne.

I dispositivi scollegati restano nell’elenco, così i loro profili si possono consultare e modificare anche quando non sono collegati. Quando un dispositivo in elenco si ricollega, MockTab applica automaticamente le impostazioni salvate.

Su una Intuos5 o una Intuos Pro (2013) usata con il kit wireless Wacom, la riga **Batteria** del pannello Info stabilisce dopo quanto tempo di inattività la tavoletta va in stop.

## Rilevamento dei conflitti

Se un altro driver per tavolette (come il driver ufficiale Wacom) è in esecuzione nello stesso momento, MockTab prova a rilevare il conflitto e a mostrare un avviso.

[profiles]

## Profili

Un profilo è un’istantanea delle impostazioni della tavoletta: area attiva, curva di pressione, assegnazioni dei pulsanti e mappatura del display. Cambiando profilo, tutte queste impostazioni si applicano subito.

## Creare e rinominare

Fai clic su **Crea profilo** per catturare le impostazioni attuali. Fai doppio clic sul nome di un profilo per rinominarlo.

## Eccezioni per app nei profili

I profili conservano le proprie eccezioni per app. Cambiando profilo si passa anche alle eccezioni associate al profilo attivo.

## Backup e importazione

Trascina il riquadro JSON nel Finder per salvare tutte le impostazioni, compresi numeri di serie e nomi delle app. Trascina un file sul riquadro per importarlo e scegliere quali tavolette riprendere. Il menu Profili fa lo stesso.

[scratchpad]

## Area di prova

L’area di prova è un’area di disegno sensibile alla pressione. Offre un modo rapido per verificare che la penna comunichi correttamente pressione, inclinazione e movimento.

Opacità e spessore del tratto rispondono entrambi alla pressione della punta. L’inclinazione cambia l’angolo del tratto quando la penna la supporta. Il pannello non conserva i tratti; chiudendolo o cancellandolo il contenuto va perso.

**Cancella** – Rimuove tutti i tratti dall’area.

[info]

## In tempo reale

Il pannello Info mostra in tempo reale i valori della penna: posizione X/Y, pressione, inclinazione, rotazione, distanza in prossimità e stato dei pulsanti. I valori si aggiornano di continuo finché la penna resta a portata.

Questa vista aiuta a diagnosticare comportamenti inattesi, per esempio confermando se la pressione raggiunge il valore massimo o se la tavoletta comunica l’inclinazione.

## Raccogli dati del dispositivo

**Raccogli dati del dispositivo** registra ciò che la tavoletta invia mentre la usi. Il risultato è un unico file zip che puoi allegare a una richiesta su GitHub o inviare per email, per aggiungere o migliorare il supporto di un dispositivo.

## Aggiornamenti

**Verifica ora** chiede a mocktab.org se c’è una versione più recente, e **Verifica automaticamente** lo chiede ogni settimana. Nient’altro va online.

Un badge sulle icone nella barra dei menu e nel Dock indica che è disponibile un aggiornamento. **Installa alla chiusura** lo installa quando MockTab si chiude, e **Installa e riapri** lo installa subito.

## Dock e login

**Icona nel Dock** – Nasconde MockTab dal Dock. L’icona nella barra dei menu resta.

**Apri al login** – Apre MockTab quando esegui il login.

**Consenti…** apre Impostazioni di Sistema per un permesso mancante.

[website]

## mocktab.org

Il sito web di MockTab, [mocktab.org](https://mocktab.org), offre la documentazione, le note di versione e l’elenco completo dell’hardware supportato.

## GitHub

Segnalazioni di bug e domande vanno su [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues).

## Ringraziamenti

MockTab si basa su lavoro open source. [OpenTabletDriver](https://opentabletdriver.net/) fornisce configurazioni per tavolette di molte marche. Il [Linux Wacom Project](https://linuxwacom.github.io/) fornisce dimensioni e disposizione dei controlli delle tavolette Wacom tramite libwacom, e documenta i formati dei dati di Wacom tramite il driver input-wacom, incluso anche nel kernel Linux, e la raccolta wacom-hid-descriptors.

## Licenza

MockTab è software libero con licenza [GNU General Public License, versione 3 o successiva](https://www.gnu.org/licenses/gpl-3.0.html). Il codice sorgente si trova su [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver). TabletKit, la libreria che MockTab usa per leggere le tavolette, è distribuita con licenza [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).

I disegni delle tavolette usano disposizioni dei controlli tratte da libwacom:

Copyright © 2011 Red Hat, Inc.

Permission to use, copy, modify, distribute, and sell this software and its documentation for any purpose is hereby granted without fee, provided that the above copyright notice appear in all copies and that both that copyright notice and this permission notice appear in supporting documentation, and that the name of Red Hat not be used in advertising or publicity pertaining to distribution of the software without specific, written prior permission.  Red Hat makes no representations about the suitability of this software for any purpose.  It is provided "as is" without express or implied warranty.

THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
