# NXManager — état de l'implémentation (0.1.0)

Date : 12 novembre 2026

## Native SwiftUI edition

The native SwiftUI app is in `NativeApp/`. It includes a horizontal poster carousel, click-or-drop package zones, compiled NXNative `.app` import and launch, custom cover art, a System / Light / Dark theme selector, `prod.keys` settings, NXNative install/update, JSON build progress, and a Finder shortcut to each game's save folder. `./build_macos.sh` creates `dist/NXManager.app` on Apple Silicon.

This edition uses its own JSON library in `~/Library/Application Support/NXManager/`. It does not automatically migrate the earlier Python interface's SQLite catalogue. The native edition does not yet include the earlier controller calibration and detailed build history views. A real game build still requires NXNative's dependencies; compiling the native interface does not validate a game build.

## Implémenté dans cette livraison

- Application Python / PySide6 avec les trois rubriques principales Games, Controllers et Import.
- Thèmes clair et sombre.
- Persistance SQLite des jeux, packages, paramètres, profils de manettes et historiques de build.
- Import XCI / NSP / NSZ / XCZ, extensions insensibles à la casse.
- Liens symboliques vers les packages originaux : aucun déplacement ni copie automatique des packages.
- Lecture indicative du Title ID et de la version depuis les marqueurs du nom de fichier.
- Détection des chemins de package manquants et action de relocalisation.
- Association d'un package principal et d'une update à partir du Title ID lorsque celui-ci est présent dans le nom.
- Sélection persistante du chemin `prod.keys`; l'interface ne prétend pas valider son contenu.
- Installation gérée par clonage Git, sélection d'une installation existante, mise à jour avec branche de sauvegarde et restauration du commit précédent.
- Lancement asynchrone du script officiel de NX Native, événements JSON, logs, annulation, historique et vérification du `.app` de sortie.
- Dossier de travail isolé par jeu dans Application Support.
- Jaquette manuelle et récupération de l'icône transmise par l'événement `game` du moteur lorsqu'elle est disponible.
- Accès aux captures NX Native par Title ID.
- Détection GameController (PyObjC), assistant d'entrée pour boutons / D-pad / directions des sticks, sauvegarde de profils globaux ou par jeu et périphérique.
- Écriture prudente de `DM_HID_MAP` et `DM_HID_LOG` dans le `env.txt` par jeu, avec sauvegarde du fichier précédent.
- Tests unitaires du parseur de package, de la base et du gestionnaire `env.txt`.

## Limites connues — ne pas masquer

1. **Pas de build `.app` produit dans l'environnement de développement courant** : l'archive contient le code et le script PyInstaller, mais la construction et la validation de `NXManager.app` doivent être faites sur macOS Apple Silicon.
2. **Identification des packages** : le Title ID et la version sont lus depuis des motifs courants de noms de fichiers. Ce n'est pas une lecture des métadonnées internes. Le moteur NX Native reste l'autorité d'analyse.
3. **Jaquettes automatiques** : l'icône est récupérée quand le moteur fournit son chemin dans l'événement `game`; avant ce premier build, l'utilisateur peut choisir une image manuellement.
4. **Manettes** : la calibration GameController enregistre les éléments standardisés transmis par macOS. Elle ne récupère pas les usages HID bruts.
5. **DM_HID_MAP** : la documentation NX Native l'expose pour les manettes HID brutes non reconnues par GameController, avec les valeurs de boutons relevées par `DM_HID_LOG`. L'interface fournit la configuration documentée A/B/X/Y par jeu. Elle ne remappe pas les manettes déjà prises en charge par GameController.
6. **Sticks** : la calibration directionnelle est enregistrée dans les profils NXManager, mais aucun format de remapping des axes de sticks n'est documenté dans l'interface NX Native utilisée ici. Aucun remapping de sticks en jeu n'est donc annoncé.
7. **Validation matérielle** : la détection USB/Bluetooth, la calibration et les événements de périphériques doivent être testés avec les manettes réellement utilisées sur macOS 27.x.
8. **Dépendances NX Native** : l'application affiche un diagnostic, mais n'installe pas silencieusement Xcode, Metal Toolchain, Homebrew ou les outils système.
9. **Packaging** : signature Developer ID, notarisation et tests Finder restent à effectuer sur le Mac cible.

## Vérifications exécutées dans l'environnement de développement

- `python -m compileall -q nxmanager tests` : réussi.
- `python -m pytest -q` : 11 tests réussis.
- La présence de PySide6 et des frameworks macOS n'est pas disponible dans l'environnement Linux utilisé pour cette génération; le démarrage graphique et les tests matériels n'ont donc pas été exécutés ici.

## Points d'intégration upstream

- Build JSON et options du script : `docs/frontends.md` et `scripts/build_ipa_from_nsp.py`.
- `env.txt` par jeu et `DM_HID_MAP` / `DM_HID_LOG` : `docs/playing.md`.
- Exigences macOS / Xcode / Python : `README.md` upstream.
