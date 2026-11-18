# NXManager — état de l'implémentation (0.1.0)

Date : 18 novembre 2026

## Native SwiftUI edition

The native SwiftUI app is in `NativeApp/`. It includes a horizontal poster carousel, click-or-drop package zones, compiled NXNative `.app` import and launch, custom cover art, a System / Light / Dark theme selector, `prod.keys` settings, NXNative install/update, JSON build progress, and a Finder shortcut to each game's save folder. `./build_macos.sh` creates `dist/NXManager.app` on Apple Silicon.

This edition uses its own JSON library in `~/Library/Application Support/NXManager/`. It does not automatically migrate the earlier Python interface's SQLite catalogue. It includes HID controller calibration and retains each game's latest build status and log, but it does not yet provide the Python edition's multi-build history view. NUP Title IDs are read from the generated app after a successful build; before then, save-folder access and automatic Title-ID artwork lookup are unavailable. A real game build still requires NXNative's dependencies; compiling the native interface does not validate a game build.

## Implémenté dans cette livraison

- Application Python / PySide6 avec les trois rubriques principales Games, Controllers et Import.
- Thèmes clair et sombre.
- Persistance SQLite des jeux, packages, paramètres, profils de manettes et historiques de build.
- Import XCI / NSP / NSZ / XCZ, extensions insensibles à la casse.
- Liens symboliques vers les packages originaux : aucun déplacement ni copie automatique des packages.
- Le lien de package est remplacé lors de la réimportation d'un package homonyme depuis un autre emplacement.
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
- Tests Swift des helpers HID, des profils de manette, de l'état de bibliothèque et de la validation des Title IDs.

## Limites connues — ne pas masquer

1. **Artefact macOS préexistant** : `dist/NXManager-macOS.zip` contient un build de l'app native daté du 18 novembre, antérieur aux modifications présentement décrites. Il ne valide donc pas ces changements; il faut reconstruire et vérifier l'app depuis le code actuel.
2. **Identification des packages Switch 1** : le Title ID et la version sont lus depuis des motifs courants de noms de fichiers. Ce n'est pas une lecture des métadonnées internes. Le moteur NX Native reste l'autorité d'analyse. Pour NUP, le Title ID devient disponible dans NXManager après un build réussi et la lecture du `Info.plist` généré.
3. **Jaquettes automatiques** : l'icône est récupérée quand le moteur fournit son chemin dans l'événement `game`; avant ce premier build, l'utilisateur peut choisir une image manuellement.
4. **Manettes** : la calibration GameController enregistre les éléments standardisés transmis par macOS. Elle ne récupère pas les usages HID bruts.
5. **DM_HID_MAP** : la documentation NX Native l'expose pour les manettes HID brutes non reconnues par GameController, avec les valeurs de boutons relevées par `DM_HID_LOG`. L'interface fournit la configuration documentée A/B/X/Y par jeu. Elle ne remappe pas les manettes déjà prises en charge par GameController.
6. **Sticks** : la calibration directionnelle est enregistrée dans les profils NXManager, mais aucun format de remapping des axes de sticks n'est documenté dans l'interface NX Native utilisée ici. Aucun remapping de sticks en jeu n'est donc annoncé.
7. **Annulation des builds natifs** : NXManager envoie SIGTERM puis SIGKILL au processus après cinq secondes s'il ne s'arrête pas. Les éventuels processus enfants du moteur ne sont pas explicitement gérés comme un groupe de processus.
8. **Validation matérielle** : la détection USB/Bluetooth, la calibration et les événements de périphériques doivent être testés avec les manettes réellement utilisées sur macOS 27.x.
9. **Dépendances NX Native** : l'application affiche un diagnostic, mais n'installe pas silencieusement Xcode, Metal Toolchain, Homebrew ou les outils système.
10. **Packaging** : signature Developer ID, notarisation et tests Finder restent à effectuer sur le Mac cible.

## Vérifications exécutées dans l'environnement de développement

- `python3 -m compileall -q nxmanager tests` : réussi.
- `./tests/run_native_unit_tests.sh` : réussi, y compris la validation du Title ID.
- Vérification ciblée du remplacement de lien symbolique : réussie.
- `python3 -m pytest -q` n'a pas pu être lancé : `pytest` n'est pas installé dans l'environnement courant.
- Le build Xcode a été tenté, mais la compilation de `ContentView.swift` échoue lorsque le plug-in de macro `SwiftUIMacros` renvoie une réponse mal formée. Le build complet reste à revalider dans un environnement Xcode fonctionnel.

## Points d'intégration upstream

- Build JSON et options du script : `docs/frontends.md` et `scripts/build_ipa_from_nsp.py`.
- `env.txt` par jeu et `DM_HID_MAP` / `DM_HID_LOG` : `docs/playing.md`.
- Exigences macOS / Xcode / Python : `README.md` upstream.
