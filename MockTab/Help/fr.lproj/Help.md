[about]

## Tablettes graphiques

Une tablette graphique est un périphérique d’entrée dont le stylet transmet la position absolue, la pression, l’inclinaison et la rotation.

## MockTab

MockTab est un pilote macOS pour les tablettes graphiques Wacom et Xencelabs. Il vise les tablettes USB et Bluetooth des gammes Wacom Intuos, Intuos Pro, Cintiq, Bamboo et Graphire, ainsi que certains modèles Xencelabs. Il se concentre sur le matériel que le pilote de Wacom ne prend plus en charge sur les versions récentes de macOS.

## Supprimer MockTab

Quittez MockTab et placez-le dans la corbeille. Pour supprimer aussi ses réglages, ouvrez chaque élément ci-dessous dans le Finder avec **Aller au dossier** (⇧⌘G) et placez-le dans la corbeille :

- `~/Library/Preferences/com.cyzor.mocktab.plist` – réglages  
- `~/Library/Application Support/com.cyzor.mocktab` – anciens réglages, enregistrés à chaque démarrage d’une version différente  

[tabletArea]

## Zone active

La zone active est la partie de la surface de la tablette qui correspond à l’écran. Le stylet n’a aucun effet en dehors de ce rectangle.

**Redimensionner** – Faites glisser la zone ou ses poignées ; elle s’aligne sur la forme de la zone d’écran lorsqu’elle s’en approche (maintenez **⌘** pour l’éviter, **⇧** pour garder sa forme, **⌥** pour redimensionner depuis le centre). Cliquez sur la largeur ou la hauteur en dessous pour saisir une taille exacte.

**Clavier** – Sous macOS 14 ou ultérieur, cliquez sur la zone et déplacez-la avec les touches fléchées, ou maintenez **⌥** pour la redimensionner. Avec **⇧**, les pas sont plus grands.

**Correspondance proportionnelle** – Garde des déplacements horizontaux et verticaux égaux pour le curseur. Désactivez-la pour étirer ou comprimer la correspondance.

**Rétablir la zone complète** – Rétablit toute la surface de la tablette. ⌘Z annule l’opération.

## Orientation

Choisissez l’orientation qui correspond à la position actuelle de la tablette (⌘⌥1 à ⌘⌥4 dans la sous-fenêtre Zone de la tablette). Le stylet, le toucher et l’inclinaison suivent ce choix, et la sous-fenêtre Boutons dessine la tablette en conséquence.

Tourner la tablette déplace chaque affectation vers la touche qui occupe désormais sa place, dans tous les profils et toutes les exceptions d’app. Annuler rétablit les deux ensemble.

**Retourner les affectations** – Cliquez avec le bouton droit sur le dessin de la tablette dans la sous-fenêtre Boutons pour échanger chaque affectation avec la touche opposée sans changer l’orientation. Choisissez-la de nouveau pour les rétablir.

## Calibrage (écrans à stylet)

**Calibrer…** affiche des cibles en plein écran à toucher avec la pointe du stylet. Il corrige l’écart que la vitre de l’écran crée entre la pointe et le curseur.

**Décalage du pointeur** corrige le petit écart qui subsiste, par exemple un écart qui varie avec l’angle de vue.

[penFeel]

## Courbe de pression

Montez la courbe pour que les tracés légers comptent davantage, ou descendez-la pour exiger plus de force. Linéaire, Souple et Ferme sont des préréglages.

Sous macOS 14 ou ultérieur, cliquez sur la courbe et déplacez avec les touches fléchées la poignée côté pression légère, ou maintenez **⌥** pour déplacer l’autre. Avec **⇧**, les pas sont plus grands.

## Lissage de la pression

Égalise l’épaisseur du trait sur les tracés lents et légers.

## Stabilisation

Réduit le tremblement du curseur dû à la main, au prix d’un léger retard.

## Distance de double-clic

Distance maximale entre deux touchers pour compter comme un double-clic.

## Mouvement

**Inverser le sens de rotation** – Choisissez si la rotation du corps du stylet produit un mouvement horaire ou antihoraire.

**Mouvement relatif du curseur** – Déplace le curseur comme une souris au lieu de faire correspondre la tablette à l’écran.

## Déplacer la vue

**Vitesse**, **Inverser le sens** et **Défilement avec inertie** règlent le déplacement du contenu tant que vous maintenez un bouton Déplacer la vue. Attribuez Déplacer la vue dans la sous-fenêtre Boutons.

## Comportement du clic

**Exiger le contact** – Les actions cochées des boutons latéraux attendent que la pointe se pose. Les actions de clic non cochées fonctionnent aussi en survol, glissements compris.

**Aide au lever** – Évite que les tracés rapides se coupent quand la pointe se lève un instant.

**Seuil de glissement** – Évite qu’un toucher se transforme en petit glissement.

[buttons]

## Schéma du stylet

Appuyez sur un bouton lorsque la fenêtre est ouverte pour mettre sa position en évidence ; cela aide à repérer quel bouton physique correspond à quelle affectation. Cliquez sur la pointe, la gomme ou un bouton latéral dans le schéma pour lui enregistrer une nouvelle affectation.

## Souris

Une souris Wacom reçoit son propre schéma et ses propres lignes de boutons. Ses trois premiers boutons sont d’abord Clic gauche, Clic droit et Clic du milieu.

## Schéma de la tablette

Le schéma montre la position des touches, des anneaux et des molettes d’une tablette. Cliquez sur un élément pour lui attribuer une action.

## Types d’affectation

- **Boutons de la souris** – Clic gauche, Clic droit, Clic du milieu, Double-clic et Verrouillage du clic, qui maintient le bouton gauche enfoncé jusqu’au prochain appui  
- **Raccourcis clavier** – cliquez sur le champ de raccourci et appuyez sur une combinaison de touches  
- **Touches de modification** – ⌘ ⌥ ⇧ ⌃ maintenues tant que le bouton reste enfoncé  
- **Actions spéciales** – Déplacer la vue, Gomme, Barre d’espace, Échap, F13 à F19, Changer d’écran, Étendre sur les écrans, Activer ou désactiver le mode relatif, Afficher les réglages de MockTab, et les modes des anneaux, molettes et bandes  
- **Ouvrir** – faites glisser une app, un fichier, un lien ou une macro Keyboard Maestro sur la ligne d’un bouton. Un point d’interrogation signale que la cible a disparu. Pour saisir ou corriger une URL, cliquez avec le bouton droit sur la ligne et choisissez Modifier l’URL  

Pour lancer un script, un processus Automator ou un raccourci, enregistrez-le comme app et faites glisser celle-ci, ou donnez-lui un raccourci clavier dans Réglages Système ou Raccourcis et attribuez ce raccourci.

## Touch Ring et molette

Les anneaux, les molettes et les bandes tactiles ont chacun leurs propres modes. Cliquez sur un mode, ou sur son secteur dans le schéma, pour modifier ses réglages. Pour changer de mode depuis un bouton, attribuez **Parcourir** ou **Passer en mode**.

**Défilement** – Fonctionne comme une molette de défilement. À 1×, chaque cran fait défiler d’une ligne.

**Zoom** et **Pivoter** – Agrandissent ou font tourner le canevas, comme un pincement ou une rotation sur un trackpad. La vitesse va de Désactivé à Max. ; à Max., un tour d’anneau fait faire un tour complet au canevas. La prise en charge varie selon l’app.

**Touche** – Envoie un raccourci clavier pour chaque sens.

## Écrans des touches

Une Intuos4 dotée d’écrans de touches affiche l’action de chaque touche à côté d’elle en USB, et ces écrans s’atténuent au repos.

## Éclairage

Sur les appareils avec une bague de molette lumineuse ou des boutons rétroéclairés, vous pouvez régler la couleur et la luminosité. Le matériel garde sa dernière couleur jusqu’à ce que vous la changiez.

## Gomme

L’extrémité gomme a sa propre affectation dans la section du stylet. Sur un stylet qui n’en a pas, attribuez Gomme à un bouton latéral et maintenez-le pour gommer avec la pointe.

## Exceptions par app

La barre d’exceptions d’app en haut attribue des boutons différents à une application donnée. Les exceptions s’activent automatiquement lorsque cette app passe au premier plan. Les réglages globaux s’appliquent dans tous les autres cas.

**Réinitialiser** supprime les exceptions de l’app actuelle. Maintenez **⌥** pour le changer en **Tout supprimer**, qui supprime les exceptions de toutes les apps pour cette tablette.

[touch]

## Toucher

Certaines tablettes détectent aussi les doigts. MockTab laisse le toucher désactivé par défaut. Cochez **Activer le toucher** pour vous en servir. La réponse varie selon l’app.

**Toucher pour cliquer** – Un bref toucher sans déplacement notable produit un clic gauche.

**Clic droit à deux doigts** – Un contact bref avec deux doigts, à une largeur de doigt d’écart, produit un clic droit.

**Glissement à trois doigts** – Trois doigts posés ensemble maintiennent le bouton de la souris enfoncé. Déplacez-les pour faire glisser, levez-les pour relâcher.

**Vitesse du curseur** – Ajuste le déplacement du pointeur pour un glissement à un doigt. Les valeurs faibles donnent plus de finesse, les valeurs élevées couvrent plus de distance avec moins de mouvement.

## Gestes

**Défilement à deux doigts** – Balayez avec deux doigts dans une direction. Les apps le traitent en général comme le défilement d’un trackpad.

**Pincer pour zoomer** – Écartez ou rapprochez deux doigts pour zoomer.

**Pivoter** – Posez deux doigts bien écartés sur la tablette et faites-les pivoter autour de leur centre. Le défilement, le pincement et la rotation lisent le même geste à deux doigts de façons différentes.

**Inverser le sens** – Activé : le contenu se déplace à l’opposé des doigts, comme avec une molette de souris classique.

**Défilement avec inertie** – Le défilement à deux doigts continue brièvement après le lever des doigts, comme l’inertie d’un trackpad.

## Zone tactile

La zone tactile est indépendante de la zone active du stylet. Faites glisser les poignées de l’aperçu pour rogner la surface tactile disponible. Les doigts n’ont aucun effet en dehors du rectangle. Les touches de modification et fléchées fonctionnent comme pour la zone active.

**Rétablir la surface complète** – Rétablit la zone tactile sur toute la région tactile.

## Limites

MockTab ne prend pas en charge Mission Control, Spaces, Launchpad ni App Exposé au toucher.

[display]

## Correspondance d’écran

La correspondance d’écran détermine quel écran la tablette considère comme actif.

**Écran principal** – Associe la tablette à votre écran principal.

**Un seul écran** – Choisissez un écran par son nom pour y associer la tablette uniquement.

**Basculer entre les écrans** – Un bouton fait passer la tablette d’un écran sélectionné à l’autre. ⌘-cliquez sur les écrans du schéma pour les choisir, ou Maj-cliquez pour sélectionner une plage.

**Étendre sur les écrans sélectionnés** – Associe la tablette aux écrans sélectionnés comme une seule surface.

**Tous** – Associe la tablette à tous les écrans comme une seule surface.

**Étendre sur les écrans** – Appuyez sur un bouton réglé sur Étendre sur les écrans pour étendre le stylet sur les écrans sélectionnés sous Écrans actifs, et appuyez de nouveau pour revenir à votre réglage habituel. Si aucun n’est sélectionné, il couvre tous les écrans.

## Zone d’écran

Comme la zone active, mais côté écran : rogne la partie de l’écran que le stylet peut atteindre.

**Sélectionner à l’écran…** – Tracez la zone directement sur votre Bureau, comme avec l’outil de capture d’écran de macOS.

**Utiliser tout l’écran** – Rétablit l’écran entier.

[devices]

## Appareils connectés

La sous-fenêtre Appareils liste toutes les tablettes et tous les stylets que MockTab a détectés. Chaque ligne indique le nom de l’appareil, le type de connexion (USB ou Bluetooth) et l’état actuel.

Sélectionner une ligne affiche les réglages propres au modèle et les stylets dans la sous-fenêtre de détails à droite.

Les appareils déconnectés restent dans la liste : leurs profils restent consultables et modifiables même débranchés. Lorsqu’un appareil de la liste se reconnecte, MockTab applique automatiquement ses réglages enregistrés.

Sur une Intuos5 ou une Intuos Pro (2013) utilisée avec le kit sans fil Wacom, la ligne **Batterie** de la sous-fenêtre Infos définit la durée d’inactivité avant la mise en veille de la tablette.

## Détection des conflits

Si un autre pilote de tablette (comme le pilote officiel de Wacom) est ouvert en même temps, MockTab tente de détecter le conflit et d’afficher un avertissement.

[profiles]

## Profils

Un profil est un instantané des réglages de la tablette : zone active, courbe de pression, affectations des boutons et correspondance d’écran. Changer de profil applique immédiatement tous ces réglages.

## Créer et renommer

Cliquez sur **Créer un profil** pour capturer les réglages actuels. Double-cliquez sur le nom d’un profil pour le renommer, ou cliquez sur un profil avec le bouton droit pour d’autres options. Maintenez **⌥** en ouvrant ce menu pour supprimer tous les profils de cette tablette ; **⌘Z** les rétablit.

## Exceptions par app dans les profils

Les profils conservent leurs propres exceptions par app. Changer de profil fait aussi passer aux exceptions associées au profil actif.

## Sauvegarde et importation

Faites glisser la vignette JSON vers le Finder pour enregistrer tous les réglages, y compris les numéros de série et les noms d’apps. Faites glisser un fichier sur la vignette pour l’importer et choisir les tablettes à reprendre. Le menu Profils fait de même. ⌥-cliquez sur la case d’une tablette pour tout cocher ou tout décocher.

[scratchpad]

## Zone de test

Une zone de dessin pour vérifier que le stylet transmet la pression et le mouvement. MockTab ne conserve pas les tracés.

[info]

## En direct

La sous-fenêtre Infos montre ce que transmet la tablette. Des jauges représentent la position, la pression, l’inclinaison, la rotation, la hauteur de survol et l’activité tactile.

## Collecter les données de l’appareil

**Collecter les données de l’appareil** enregistre ce que la tablette envoie pendant que vous l’utilisez. Le résultat est un seul fichier zip que vous pouvez joindre à un ticket GitHub ou envoyer par e-mail, pour ajouter ou améliorer la prise en charge d’un appareil.

## Mises à jour

**Rechercher maintenant** demande à mocktab.org s’il existe une version plus récente, et **Rechercher automatiquement** le demande chaque semaine. Rien d’autre ne passe par Internet.

Une pastille sur les icônes de la barre des menus et du Dock signale qu’une mise à jour est disponible. **Installer à la fermeture** l’installe à la fermeture de MockTab, et **Installer et rouvrir** l’installe tout de suite.

Maintenez **⌥** pour changer **Rechercher maintenant** en **Rechercher une préversion**, qui cherche une version de test plus récente. Les préversions peuvent être incomplètes. La commande **Rechercher les mises à jour…** du menu change de la même façon.

## Dock et ouverture de session

**Icône du Dock** – Retire MockTab du Dock. L’icône de la barre des menus reste.

**Ouvrir à la connexion** – Ouvre MockTab à l’ouverture de session.

**Autoriser…** ouvre Réglages Système pour une autorisation manquante.

[website]

## mocktab.org

Le site web de MockTab, [mocktab.org](https://mocktab.org), propose la documentation, les notes de version et la liste complète du matériel pris en charge.

## GitHub

Les rapports de bogue et les questions vont sur [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues).

## Remerciements

MockTab s’appuie sur des travaux open source. [OpenTabletDriver](https://opentabletdriver.net/) fournit des configurations pour des tablettes de nombreuses marques. Le [Linux Wacom Project](https://linuxwacom.github.io/) fournit les dimensions et la disposition des commandes des tablettes Wacom via libwacom, et documente les formats de données de Wacom via son pilote input-wacom, également intégré au noyau Linux, et sa collection wacom-hid-descriptors.

## Licence

MockTab est un logiciel libre sous [licence publique générale GNU, version 3 ou ultérieure](https://www.gnu.org/licenses/gpl-3.0.html). Son code source se trouve sur [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver). TabletKit, la bibliothèque que MockTab utilise pour lire les tablettes, est sous [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).

Les dessins des tablettes utilisent des dispositions de commandes issues de libwacom :

Copyright © 2011 Red Hat, Inc.

Permission to use, copy, modify, distribute, and sell this software and its documentation for any purpose is hereby granted without fee, provided that the above copyright notice appear in all copies and that both that copyright notice and this permission notice appear in supporting documentation, and that the name of Red Hat not be used in advertising or publicity pertaining to distribution of the software without specific, written prior permission.  Red Hat makes no representations about the suitability of this software for any purpose.  It is provided "as is" without express or implied warranty.

THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
