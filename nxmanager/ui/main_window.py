import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import Qt, QSize, QUrl, Signal
from PySide6.QtGui import QPixmap, QDesktopServices, QIntValidator
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QFrame, QLabel, QPushButton, QVBoxLayout, QHBoxLayout,
    QGridLayout, QStackedWidget, QFileDialog, QMessageBox, QScrollArea, QLineEdit,
    QComboBox, QProgressBar, QTextEdit, QDialog, QFormLayout, QDialogButtonBox,
    QListWidget, QListWidgetItem, QCheckBox, QGroupBox, QSplitter, QSpacerItem,
    QSizePolicy
)

from ..core.database import Database
from ..core.paths import APP_SUPPORT, DATA_DIR, LOG_DIR
from ..core.packages import register_package, package_matches_base
from ..core.engine import EngineManager
from ..core.build import BuildRunner
from ..core.controllers import ControllerMonitor, CALIBRATION_STEPS
from ..core.env_config import env_file_for_title, read_env, update_env
from .theme import LIGHT, DARK


def button(text, primary=False):
    b = QPushButton(text)
    if primary:
        b.setObjectName("Primary")
    return b


def title_label(text):
    l = QLabel(text)
    l.setObjectName("PageTitle")
    return l


def muted(text):
    l = QLabel(text)
    l.setObjectName("Muted")
    l.setWordWrap(True)
    return l


class DropFrame(QFrame):
    file_dropped = Signal(str)
    def __init__(self):
        super().__init__()
        self.setAcceptDrops(True)
        self.setObjectName("Panel")
    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls(): event.acceptProposedAction()
        else: event.ignore()
    def dropEvent(self, event):
        urls = event.mimeData().urls()
        if urls:
            self.file_dropped.emit(urls[0].toLocalFile())
            event.acceptProposedAction()


def panel():
    f = QFrame()
    f.setObjectName("Panel")
    f.setFrameShape(QFrame.Shape.NoFrame)
    return f


class BuildDialog(QDialog):
    def __init__(self, game, db, engine, keys_path, output_dir, parent=None):
        super().__init__(parent)
        self.game = game
        self.db = db
        self.engine = engine
        self.keys_path = keys_path
        self.output_dir = output_dir
        self.runner = None
        self.setWindowTitle("Préparer la compilation")
        self.resize(700, 560)
        root = QVBoxLayout(self)
        root.addWidget(title_label("Récapitulatif du build"))
        summary = panel(); form = QFormLayout(summary); form.setContentsMargins(18, 18, 18, 18)
        status = engine.status()
        form.addRow("Jeu", QLabel(game["name"]))
        form.addRow("Title ID", QLabel(game.get("title_id") or "Non détecté"))
        form.addRow("Packages", QLabel(str(len(db.packages(game["id"])))) )
        form.addRow("Dossier packages", QLabel(game["package_dir"]))
        form.addRow("prod.keys", QLabel(str(keys_path or "Non configuré")))
        form.addRow("Moteur", QLabel(f"{status['message']} · {status.get('version') or 'version inconnue'}"))
        form.addRow("Sortie", QLabel(str(output_dir)))
        root.addWidget(summary)
        self.note = muted("La compilation peut durer longtemps et demander beaucoup d'espace disque. Le moteur conserve ses caches dans le dossier de travail du jeu.")
        root.addWidget(self.note)
        self.progress = QProgressBar(); self.progress.setRange(0, 0); self.progress.setVisible(False)
        root.addWidget(self.progress)
        self.stage = QLabel("Prêt à démarrer")
        root.addWidget(self.stage)
        self.log_view = QTextEdit(); self.log_view.setReadOnly(True); self.log_view.setMinimumHeight(150)
        root.addWidget(self.log_view, 1)
        row = QHBoxLayout()
        self.cancel_btn = button("Fermer")
        self.start_btn = button("Lancer le build", True)
        row.addWidget(self.cancel_btn); row.addStretch(1); row.addWidget(self.start_btn)
        root.addLayout(row)
        self.cancel_btn.clicked.connect(self._close_or_cancel)
        self.start_btn.clicked.connect(self.start_build)

    def output_path_exists(self):
        safe_name = "".join(c for c in self.game["name"] if c.isalnum() or c in " -_").strip() or self.game["id"]
        return (Path(self.output_dir) / f"{safe_name}.app").exists()

    def start_build(self):
        status = self.engine.status()
        if not status["valid"]:
            QMessageBox.warning(self, "Moteur indisponible", "Configure d'abord une installation NX Native valide.")
            return
        if not self.keys_path or not Path(self.keys_path).is_file():
            QMessageBox.warning(self, "prod.keys manquant", "Sélectionne d'abord ton fichier prod.keys dans Import ou Réglages.")
            return
        if not self.game.get("title_id"):
            QMessageBox.warning(self, "Identification incomplète", "Le Title ID n'a pas été détecté dans le nom du package. Vérifie que les fichiers sont correctement nommés avant de lancer le build.")
            return
        if self.output_path_exists():
            answer = QMessageBox.question(self, "Application déjà présente", "Une application de sortie portant ce nom existe déjà. La remplacer ? L'ancienne sera conservée dans les sauvegardes NXManager.")
            if answer != QMessageBox.StandardButton.Yes: return
            try:
                from ..core.paths import BACKUP_DIR
                BACKUP_DIR.mkdir(parents=True, exist_ok=True)
                safe_name = "".join(c for c in self.game["name"] if c.isalnum() or c in " -_").strip() or self.game["id"]
                old_output = Path(self.output_dir) / f"{safe_name}.app"
                shutil.move(str(old_output), str(BACKUP_DIR / f"{old_output.name}-{int(time.time())}"))
            except Exception as exc:
                QMessageBox.critical(self, "Sauvegarde impossible", str(exc)); return
        self.start_btn.setEnabled(False); self.cancel_btn.setText("Annuler le build")
        self.progress.setVisible(True); self.progress.setRange(0, 0)
        self.stage.setText("Démarrage du moteur…")
        log_path = LOG_DIR / f"build-{self.game['id']}-{int(time.time())}.log"
        self.log_file_path = log_path
        self.log_file = log_path.open("a", encoding="utf-8")
        self.runner = BuildRunner(self.engine.build_script, self.game, self.keys_path, self.output_dir, self)
        self.runner.event.connect(self.on_event)
        self.runner.log.connect(self.on_log)
        self.runner.finished.connect(self.on_finished)
        self.started = datetime.now(timezone.utc).isoformat()
        try:
            self.runner.start()
        except Exception as exc:
            self.log_file.close()
            self.start_btn.setEnabled(True); self.cancel_btn.setText("Fermer")
            self.progress.setVisible(False)
            QMessageBox.critical(self, "Impossible de démarrer", str(exc))

    def on_event(self, event):
        kind = event.get("ev")
        if kind == "stage":
            self.stage.setText(f"Étape {event.get('k', '?')}/{event.get('n', '?')} · {event.get('name', 'Préparation')}")
            self.progress.setRange(0, 0)
        elif kind == "progress":
            frac = event.get("frac")
            if isinstance(frac, (int, float)):
                self.progress.setRange(0, 1000); self.progress.setValue(int(max(0, min(.99, frac)) * 1000))
            else:
                self.progress.setRange(0, 0)
            done, total, unit = event.get("done"), event.get("total"), event.get("unit", "")
            detail = f"{done} / {total} {unit}" if done is not None and total is not None else "Progression non quantifiable"
            eta = event.get("eta")
            self.stage.setText(f"{event.get('name', 'Compilation')} · {detail}" + (f" · ETA {int(eta)} s" if isinstance(eta, (int, float)) else ""))
        elif kind == "stage_end":
            self.stage.setText(f"{event.get('name', 'Étape')} · {'terminée' if event.get('ok') else 'échec'}")
        elif kind == "game":
            icon = event.get("icon")
            if icon and Path(icon).is_file():
                cover_dir = DATA_DIR / "Covers"; cover_dir.mkdir(exist_ok=True)
                dest = cover_dir / f"{self.game['id']}.jpg"
                try:
                    shutil.copy2(icon, dest)
                    self.db.set_cover(self.game["id"], dest)
                except OSError:
                    pass
            self.stage.setText(f"Préparation de {event.get('name', self.game['name'])}…")
        elif kind == "say":
            self.on_log(event.get("msg", ""))

    def on_log(self, line):
        self.log_view.append(str(line))
        try:
            self.log_file.write(str(line) + "\n"); self.log_file.flush()
        except Exception:
            pass

    def on_finished(self, exit_code, elapsed, stderr):
        try: self.log_file.close()
        except Exception: pass
        output = self.runner.output_path if self.runner else None
        success = exit_code == 0 and output and output.exists()
        cancelled = exit_code in (129, 130, 143, -15)
        status = "success" if success else ("cancelled" if cancelled else "failed")
        self.db.add_build(self.game["id"], self.started, status, output, getattr(self, "log_file_path", None), exit_code, elapsed,
                          self.engine.status().get("version"))
        self.progress.setVisible(False)
        self.start_btn.setEnabled(True); self.start_btn.setText("Terminé" if success else "Réessayer")
        self.cancel_btn.setText("Fermer")
        self.stage.setText(("Build terminé avec succès" if success else ("Build annulé" if cancelled else f"Build échoué · code {exit_code}")))
        if success:
            self.on_log(f"Application créée : {output}")
            self.open_output = button("Ouvrir le dossier de sortie")
            self.open_output.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(output.parent))))
            self.layout().insertWidget(self.layout().count()-1, self.open_output)
        else:
            self.on_log("La sortie attendue est absente ou le moteur a renvoyé une erreur. Consulte les logs ci-dessus et les journaux NX Native.")

    def _close_or_cancel(self):
        if self.runner and self.runner.process.state() != self.runner.process.ProcessState.NotRunning:
            answer = QMessageBox.question(self, "Annuler le build", "Interrompre le processus NX Native ?")
            if answer == QMessageBox.StandardButton.Yes:
                self.runner.cancel()
        else:
            self.accept()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.db = Database()
        self.engine = EngineManager(self.db.get_setting("engine_path"))
        self.keys_path = self.db.get_setting("keys_path", str(Path.home() / ".switch" / "prod.keys"))
        self.theme_name = self.db.get_setting("theme", "light")
        self.output_dir = Path(self.db.get_setting("output_dir", str(Path.home() / "Games" / "NXManager Builds"))).expanduser()
        self.current_game = None
        self.build_dialog = None
        self.setWindowTitle("NXManager")
        self.resize(1240, 820)
        self.setMinimumSize(980, 680)
        self._build_shell()
        self.monitor = ControllerMonitor(self)
        self.monitor.devices_changed.connect(self.on_devices_changed)
        self.monitor.input_detected.connect(self.on_controller_input)
        self.monitor.error.connect(self.on_controller_error)
        if not self.monitor.available:
            self.controller_error_label.setText("Framework GameController indisponible. Installe les dépendances macOS optionnelles et relance l'application.")
        self.monitor.start()
        self.apply_theme()
        self.refresh_games()
        self.refresh_engine_status()

    def _build_shell(self):
        central = QWidget(); self.setCentralWidget(central)
        outer = QHBoxLayout(central); outer.setContentsMargins(18, 18, 18, 18); outer.setSpacing(18)
        self.sidebar = QFrame(); self.sidebar.setObjectName("Sidebar"); self.sidebar.setFixedWidth(210)
        side = QVBoxLayout(self.sidebar); side.setContentsMargins(14, 22, 14, 16); side.setSpacing(10)
        brand = QLabel("NXManager"); brand.setStyleSheet("font-size:21px;font-weight:750;padding:4px 10px 18px 10px;")
        side.addWidget(brand)
        self.nav_buttons = {}
        for key, label in (("Games", "Games"), ("Controllers", "Controllers"), ("Import", "Import")):
            b = QPushButton(label); b.setObjectName("Nav"); b.setCheckable(True)
            b.clicked.connect(lambda checked=False, k=key: self.navigate(k))
            self.nav_buttons[key] = b; side.addWidget(b)
        side.addStretch(1)
        self.engine_sidebar = QLabel("Moteur : vérification…"); self.engine_sidebar.setWordWrap(True); self.engine_sidebar.setObjectName("Muted")
        side.addWidget(self.engine_sidebar)
        settings = QPushButton("⚙  Réglages"); settings.setObjectName("Nav"); settings.clicked.connect(self.show_settings)
        side.addWidget(settings)
        outer.addWidget(self.sidebar)
        self.stack = QStackedWidget(); outer.addWidget(self.stack, 1)
        self.games_page = self.make_games_page(); self.controllers_page = self.make_controllers_page(); self.import_page = self.make_import_page()
        self.stack.addWidget(self.games_page); self.stack.addWidget(self.controllers_page); self.stack.addWidget(self.import_page)
        self.navigate("Games")

    def navigate(self, key):
        mapping = {"Games": 0, "Controllers": 1, "Import": 2}
        self.stack.setCurrentIndex(mapping[key])
        for name, b in self.nav_buttons.items(): b.setChecked(name == key)
        if key == "Games": self.refresh_games()
        if key == "Import": self.refresh_import_status()
        if key == "Controllers":
            self.refresh_profile_game_choices()
            self.refresh_hid_game_choices()

    def make_games_page(self):
        page = QWidget(); root = QVBoxLayout(page); root.setContentsMargins(12, 8, 8, 8); root.setSpacing(18)
        top = QHBoxLayout(); top.addWidget(title_label("Games")); top.addStretch(1)
        self.search = QLineEdit(); self.search.setPlaceholderText("Rechercher un jeu…"); self.search.setMaximumWidth(260)
        self.search.textChanged.connect(self.refresh_games)
        add = button("Add new +", True); add.clicked.connect(self.add_package_dialog)
        top.addWidget(self.search); top.addWidget(add); root.addLayout(top)
        self.games_scroll = QScrollArea(); self.games_scroll.setWidgetResizable(True)
        self.games_content = QWidget(); self.games_grid = QGridLayout(self.games_content); self.games_grid.setContentsMargins(4, 4, 4, 4); self.games_grid.setSpacing(18)
        self.games_scroll.setWidget(self.games_content); root.addWidget(self.games_scroll, 1)
        self.games_empty = muted("Ta bibliothèque est vide. Utilise « Add new + » pour ajouter un package.")
        self.games_empty.setAlignment(Qt.AlignmentFlag.AlignCenter); root.addWidget(self.games_empty)
        return page

    def make_import_page(self):
        page = QWidget(); root = QVBoxLayout(page); root.setContentsMargins(12, 8, 8, 8); root.setSpacing(18)
        root.addWidget(title_label("Import")); root.addWidget(muted("Ajoute un package principal et, si nécessaire, une mise à jour. Les fichiers originaux restent à leur emplacement : NXManager crée uniquement des liens dans son espace de travail."))
        row = QHBoxLayout(); row.setSpacing(16)
        self.base_panel = self.make_drop_panel("Datanode", "XCI · NSP · NSZ · XCZ", "Sélectionner le package principal", "base")
        self.update_panel = self.make_drop_panel("Update (facultative)", "XCI · NSP · NSZ · XCZ", "Sélectionner une mise à jour", "update")
        row.addWidget(self.base_panel); row.addWidget(self.update_panel); root.addLayout(row)
        keys = panel(); kl = QVBoxLayout(keys); kl.setContentsMargins(18, 18, 18, 18)
        ktop = QHBoxLayout(); ktop.addWidget(QLabel("prod.keys")); ktop.addStretch(1)
        self.keys_status = QLabel(); ktop.addWidget(self.keys_status); kl.addLayout(ktop)
        self.keys_path_label = muted(""); kl.addWidget(self.keys_path_label)
        krow = QHBoxLayout(); self.keys_select_btn = button("Choisir le fichier"); self.keys_select_btn.clicked.connect(self.select_keys)
        self.keys_clear_btn = button("Retirer"); self.keys_clear_btn.clicked.connect(self.clear_keys)
        krow.addWidget(self.keys_select_btn); krow.addWidget(self.keys_clear_btn); krow.addStretch(1); kl.addLayout(krow)
        kl.addWidget(muted("NXManager vérifie ici l'existence et la lisibilité du fichier. La validation cryptographique complète appartient au moteur et ne sera confirmée qu'au build."))
        root.addWidget(keys)
        self.import_feedback = muted("Aucun package importé pendant cette session."); root.addWidget(self.import_feedback)
        build_row = QHBoxLayout(); build_row.addStretch(1)
        self.build_import_btn = button("BUILD", True); self.build_import_btn.setEnabled(False)
        self.build_import_btn.clicked.connect(self.build_last_imported_game)
        build_row.addWidget(self.build_import_btn); root.addLayout(build_row)
        root.addStretch(1)
        return page

    def make_drop_panel(self, heading, formats, action_text, role):
        p = DropFrame(); p.setMinimumHeight(230); lay = QVBoxLayout(p); lay.setContentsMargins(22, 22, 22, 22)
        h = QLabel(heading); h.setStyleSheet("font-size:18px;font-weight:700;"); lay.addWidget(h)
        lay.addWidget(muted(formats)); lay.addStretch(1)
        status = QLabel("Aucun fichier sélectionné"); status.setWordWrap(True); status.setObjectName("Muted")
        setattr(self, f"{role}_status_label", status); lay.addWidget(status)
        b = button(action_text); b.clicked.connect(lambda: self.select_package(role)); lay.addWidget(b)
        p.file_dropped.connect(lambda path, r=role: self.import_package(path, r))
        return p

    def make_controllers_page(self):
        page = QWidget(); root = QVBoxLayout(page); root.setContentsMargins(12, 8, 8, 8); root.setSpacing(16)
        root.addWidget(title_label("Controllers")); root.addWidget(muted("Connecte une manette en USB ou Bluetooth. NXManager détecte les entrées standard exposées par macOS et te guide pendant la calibration."))
        self.controller_device_label = QLabel("Recherche des manettes…"); self.controller_device_label.setStyleSheet("font-size:16px;font-weight:650;")
        self.controller_device_combo = QComboBox(); self.controller_device_combo.currentIndexChanged.connect(self._selected_device_changed)
        device_panel = panel(); dl = QVBoxLayout(device_panel); dl.setContentsMargins(18, 18, 18, 18); dl.addWidget(self.controller_device_label); dl.addWidget(self.controller_device_combo)
        self.controller_error_label = muted(""); dl.addWidget(self.controller_error_label)
        root.addWidget(device_panel)
        self.calibration_panel = panel(); cp = QVBoxLayout(self.calibration_panel); cp.setContentsMargins(20, 20, 20, 20)
        self.calibration_title = QLabel("Prêt pour le test ?"); self.calibration_title.setStyleSheet("font-size:20px;font-weight:700;")
        self.calibration_instruction = muted("Connecte ta manette, puis lance la calibration. Tu devras appuyer sur chaque bouton et déplacer chaque stick dans les directions demandées.")
        cp.addWidget(self.calibration_title); cp.addWidget(self.calibration_instruction)
        self.calibration_progress = QProgressBar(); self.calibration_progress.setRange(0, len(CALIBRATION_STEPS)); self.calibration_progress.setValue(0); cp.addWidget(self.calibration_progress)
        self.calibration_capture = QLabel("Aucune entrée en attente"); self.calibration_capture.setAlignment(Qt.AlignmentFlag.AlignCenter); self.calibration_capture.setMinimumHeight(74); self.calibration_capture.setStyleSheet("font-size:22px;font-weight:700;")
        cp.addWidget(self.calibration_capture)
        row = QHBoxLayout(); self.calibration_start_btn = button("Commencer la calibration", True); self.calibration_start_btn.clicked.connect(self.start_calibration)
        self.calibration_skip_btn = button("Ignorer cette entrée"); self.calibration_skip_btn.clicked.connect(self.skip_calibration); self.calibration_skip_btn.setEnabled(False)
        self.calibration_retry_btn = button("Recommencer l'entrée précédente"); self.calibration_retry_btn.clicked.connect(self.retry_previous_calibration); self.calibration_retry_btn.setEnabled(False)
        self.calibration_finish_btn = button("Terminer et enregistrer"); self.calibration_finish_btn.clicked.connect(self.save_calibration); self.calibration_finish_btn.setEnabled(False)
        row.addWidget(self.calibration_start_btn); row.addWidget(self.calibration_skip_btn); row.addWidget(self.calibration_retry_btn); row.addStretch(1); row.addWidget(self.calibration_finish_btn); cp.addLayout(row)
        root.addWidget(self.calibration_panel)
        self.profile_game_combo = QComboBox(); self.profile_game_combo.addItem("Profil global (tous les jeux)", None)
        for game in self.db.games(): self.profile_game_combo.addItem(f"Jeu : {game['name']}", game['id'])
        self.profile_list = QListWidget(); self.profile_list.setMinimumHeight(130)
        profiles_panel = panel(); pl = QVBoxLayout(profiles_panel); pl.setContentsMargins(18, 18, 18, 18); pl.addWidget(QLabel("Associer le profil à un jeu (facultatif)")); pl.addWidget(self.profile_game_combo); pl.addWidget(QLabel("Profils enregistrés")); pl.addWidget(self.profile_list)
        root.addWidget(profiles_panel)
        hid_panel = panel(); hl = QVBoxLayout(hid_panel); hl.setContentsMargins(18, 18, 18, 18)
        hl.addWidget(QLabel("Remapping HID par jeu"))
        hl.addWidget(muted("Pour les manettes que macOS ne reconnaît pas via GameController, NX Native accepte DM_HID_MAP dans le env.txt du jeu. Les valeurs numériques doivent être relevées avec DM_HID_LOG=1. Ce remapping ne s'applique pas aux manettes déjà prises en charge par GameController."))
        self.hid_game_combo = QComboBox()
        for game in self.db.games(): self.hid_game_combo.addItem(game['name'], game['id'])
        self.hid_game_combo.currentIndexChanged.connect(self.load_hid_mapping)
        hl.addWidget(self.hid_game_combo)
        hid_form = QHBoxLayout(); self.hid_code_fields = {}
        for key in ("A", "B", "X", "Y"):
            col = QVBoxLayout(); col.addWidget(QLabel(key))
            field = QLineEdit(); field.setPlaceholderText("code HID")
            field.setValidator(QIntValidator(1, 255, field)); field.setMaximumWidth(90)
            self.hid_code_fields[key] = field; col.addWidget(field); hid_form.addLayout(col)
        hid_form.addStretch(1); hl.addLayout(hid_form)
        self.hid_log_check = QCheckBox("Activer le journal des numéros HID (DM_HID_LOG=1)")
        hl.addWidget(self.hid_log_check)
        hid_actions = QHBoxLayout(); self.hid_save_btn = button("Appliquer au jeu", True); self.hid_save_btn.clicked.connect(self.save_hid_mapping)
        self.hid_open_log_btn = button("Ouvrir le journal du jeu"); self.hid_open_log_btn.clicked.connect(self.open_hid_log)
        hid_actions.addWidget(self.hid_save_btn); hid_actions.addWidget(self.hid_open_log_btn); hid_actions.addStretch(1); hl.addLayout(hid_actions)
        self.hid_status = muted("Sélectionne un jeu pour consulter ou modifier son mapping HID."); hl.addWidget(self.hid_status)
        root.addWidget(hid_panel)
        self._calibration_index = -1; self._calibration_mapping = {}; self._active_device = None; self._selected_device_index = 0
        self.refresh_controller_profiles()
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setWidget(page)
        return scroll

    def refresh_games(self):
        while self.games_grid.count():
            item = self.games_grid.takeAt(0); w = item.widget()
            if w: w.deleteLater()
        games = self.db.games()
        query = self.search.text().casefold() if hasattr(self, "search") else ""
        games = [g for g in games if query in g["name"].casefold() or query in (g.get("title_id") or "").casefold()]
        self.games_empty.setVisible(not games)
        cols = 3
        for i, game in enumerate(games):
            card = QFrame(); card.setObjectName("Card"); card.setMinimumSize(190, 320); card.setMaximumWidth(260)
            lay = QVBoxLayout(card); lay.setContentsMargins(12, 12, 12, 12); lay.setSpacing(8)
            cover = QLabel(); cover.setAlignment(Qt.AlignmentFlag.AlignCenter); cover.setMinimumHeight(220)
            cover_path = game.get("cover_path")
            if cover_path and Path(cover_path).is_file():
                pix = QPixmap(cover_path); cover.setPixmap(pix.scaled(190, 220, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
            else:
                cover.setText("NX"); cover.setStyleSheet("font-size:42px;font-weight:800;background:rgba(120,130,150,0.12);border-radius:10px;")
            lay.addWidget(cover)
            name = QLabel(game["name"]); name.setWordWrap(True); name.setStyleSheet("font-weight:700;font-size:14px;"); lay.addWidget(name)
            sub = QLabel(game.get("title_id") or "Title ID à identifier"); sub.setObjectName("Muted"); lay.addWidget(sub)
            status = QLabel({"success":"Dernier build réussi", "failed":"Dernier build en échec"}.get(game.get("last_build_status"), "Prêt à configurer")); status.setObjectName("Muted"); lay.addWidget(status)
            open_btn = button("Ouvrir la fiche"); open_btn.clicked.connect(lambda checked=False, g=game: self.show_game_details(g["id"]))
            lay.addWidget(open_btn)
            self.games_grid.addWidget(card, i // cols, i % cols)

    def show_game_details(self, game_id):
        game = self.db.game(game_id)
        if not game: return
        dlg = QDialog(self); dlg.setWindowTitle(game["name"]); dlg.resize(760, 650)
        root = QVBoxLayout(dlg); root.addWidget(title_label(game["name"]))
        root.addWidget(muted(f"Title ID : {game.get('title_id') or 'inconnu'}\nPackages liés : {len(self.db.packages(game_id))}\nDossier de travail : {game['package_dir']}"))
        package_list = QListWidget()
        for p in self.db.packages(game_id):
            exists = Path(p["path"]).is_file()
            state = "présent" if exists else "introuvable · à relocaliser"
            item = QListWidgetItem(f"{p['filename']}   ·   {p['role']}   ·   {p['version'] or 'version non détectée'}   ·   {state}")
            item.setToolTip(p["path"]); item.setData(Qt.ItemDataRole.UserRole, p["id"]); package_list.addItem(item)
        root.addWidget(QLabel("Packages")); root.addWidget(package_list)
        relink_btn = button("Relocaliser le package sélectionné")
        relink_btn.clicked.connect(lambda: self.relink_selected_package(game_id, package_list, dlg))
        root.addWidget(relink_btn)
        history = QListWidget()
        for b in self.db.builds(game_id): history.addItem(f"{b['started_at']} · {b['status']} · {b['duration'] or 0:.1f} s")
        root.addWidget(QLabel("Historique des builds")); root.addWidget(history)
        if game.get("title_id"):
            screenshot_dir = Path.home() / "Library" / "Application Support" / "nxnative" / game["title_id"]
            root.addWidget(QLabel("Captures NX Native"))
            screenshots = QListWidget()
            if screenshot_dir.is_dir():
                image_files = sorted([p for p in screenshot_dir.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}], key=lambda p:p.stat().st_mtime, reverse=True)
                for shot in image_files[:30]: screenshots.addItem(QListWidgetItem(shot.name))
                screenshots.itemDoubleClicked.connect(lambda item: QDesktopServices.openUrl(QUrl.fromLocalFile(str(screenshot_dir / item.text()))))
            else:
                screenshots.addItem("Aucune capture détectée dans le dossier NX Native.")
            root.addWidget(screenshots)
            open_shots = button("Ouvrir le dossier des captures")
            open_shots.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(screenshot_dir))))
            root.addWidget(open_shots)
        actions = QHBoxLayout()
        build_btn = button("BUILD…", True); build_btn.clicked.connect(lambda: (dlg.accept(), self.start_build(game_id)))
        last_success = next((b for b in self.db.builds(game_id) if b["status"] == "success" and b.get("output_path") and Path(b["output_path"]).exists()), None)
        if last_success:
            launch_btn = button("Lancer le jeu")
            launch_btn.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(last_success["output_path"])))
            actions.addWidget(launch_btn)
        folder_btn = button("Ouvrir le dossier des packages"); folder_btn.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(game["package_dir"])))
        cover_btn = button("Changer la jaquette"); cover_btn.clicked.connect(lambda: self.choose_cover(game_id, dlg))
        remove_btn = button("Retirer de la bibliothèque"); remove_btn.clicked.connect(lambda: self.remove_game(game_id, dlg))
        actions.addWidget(build_btn); actions.addWidget(folder_btn); actions.addWidget(cover_btn); actions.addWidget(remove_btn)
        root.addLayout(actions); dlg.exec()

    def relink_selected_package(self, game_id, package_list, dialog=None):
        item = package_list.currentItem()
        if not item:
            QMessageBox.information(self, "Sélection requise", "Sélectionne d'abord le package à relocaliser.")
            return
        package_id = item.data(Qt.ItemDataRole.UserRole)
        path, _ = QFileDialog.getOpenFileName(self, "Relocaliser le package", str(Path.home()), "Packages (*.xci *.nsp *.nsz *.xcz)")
        if not path: return
        try:
            from ..core.packages import inspect_package
            info = inspect_package(Path(path))
            game = self.db.game(game_id)
            expected_id = game.get("title_id")
            candidate_base_id = info.get("base_title_id") or info.get("title_id")
            if expected_id and candidate_base_id != expected_id.upper():
                raise ValueError("Le Title ID du nouveau fichier ne correspond pas à ce jeu.")
            old_package = next((p for p in self.db.packages(game_id) if p["id"] == package_id), None)
            if not old_package: raise ValueError("Package non trouvé dans la bibliothèque.")
            workspace = Path(game["package_dir"]); workspace.mkdir(parents=True, exist_ok=True)
            old_link = workspace / old_package["filename"]
            if old_link.is_symlink(): old_link.unlink()
            self.db.relink_package(package_id, path, info.get("version"), info.get("role", "unknown"))
            new_link = workspace / Path(path).name
            if new_link.exists() or new_link.is_symlink():
                new_link = workspace / f"{Path(path).stem}-{package_id}{Path(path).suffix}"
            new_link.symlink_to(Path(path).resolve())
            QMessageBox.information(self, "Package relocalisé", "Le chemin a été actualisé. Le fichier original n'a pas été déplacé.")
            if dialog: dialog.accept()
            self.show_game_details(game_id)
        except Exception as exc:
            QMessageBox.critical(self, "Relocalisation impossible", str(exc))

    def add_package_dialog(self):
        path, _ = QFileDialog.getOpenFileName(self, "Ajouter un package", str(Path.home()), "Packages Nintendo Switch (*.xci *.nsp *.nsz *.xcz)")
        if path: self.import_package(path)

    def select_package(self, role):
        path, _ = QFileDialog.getOpenFileName(self, "Sélectionner un package", str(Path.home()), "Packages (*.xci *.nsp *.nsz *.xcz)")
        if path:
            self.import_package(path, role)

    def import_package(self, path, role=None):
        try:
            from ..core.packages import inspect_package
            preview = inspect_package(Path(path))
            base_id = getattr(self, "_selected_base_title_id", None)
            if role == "update" and base_id and not package_matches_base(preview["title_id"], base_id):
                QMessageBox.warning(self, "Update incompatible", "Le Title ID de cette update ne correspond pas au jeu principal sélectionné. Pour les updates Switch, NXManager tient compte du décalage standard de 0x800.")
                return
            if role == "base":
                self._selected_base_title_id = preview["title_id"]
            if role == "update" and preview["role"] == "base":
                QMessageBox.warning(self, "Package possiblement incorrect", "Le nom du package indique v0. Vérifie qu'il s'agit bien d'une mise à jour.")
            if role == "base" and preview["role"] == "update":
                QMessageBox.warning(self, "Package possiblement incorrect", "Le nom du package indique une version non nulle. Vérifie qu'il s'agit bien du jeu principal.")
            game, info = register_package(self.db, Path(path), role=role)
            self._last_imported_game_id = game["id"]
            if hasattr(self, "build_import_btn"):
                self.build_import_btn.setEnabled(True)
            if role in ("base", "update"):
                label = getattr(self, f"{role}_status_label")
                label.setText(f"{info['path'].name}\n{info['title_id'] or 'Title ID non détecté'} · {info['version'] or 'version inconnue'}")
            self.import_feedback.setText(f"{info['path'].name} associé à {game['name']}. Les originaux n'ont pas été déplacés.")
            self.refresh_games(); self.refresh_import_status()
        except Exception as exc:
            QMessageBox.critical(self, "Import impossible", str(exc))

    def build_last_imported_game(self):
        game_id = getattr(self, "_last_imported_game_id", None)
        if game_id:
            self.start_build(game_id)

    def select_keys(self):
        path, _ = QFileDialog.getOpenFileName(self, "Choisir prod.keys", str(Path.home()), "Fichiers de clés (*)")
        if path:
            self.keys_path = path; self.db.set_setting("keys_path", path); self.refresh_import_status()

    def clear_keys(self):
        self.keys_path = ""; self.db.set_setting("keys_path", ""); self.refresh_import_status()

    def refresh_import_status(self):
        p = Path(self.keys_path).expanduser() if self.keys_path else None
        if p and p.is_file() and os.access(p, os.R_OK):
            self.keys_status.setText("Fichier accessible · validation moteur à effectuer")
            self.keys_path_label.setText(str(p))
        else:
            self.keys_status.setText("Aucun fichier accessible")
            self.keys_path_label.setText("Chemin par défaut : ~/.switch/prod.keys" if not self.keys_path else str(self.keys_path))

    def choose_cover(self, game_id, parent=None):
        path, _ = QFileDialog.getOpenFileName(self, "Choisir une jaquette", str(Path.home()), "Images (*.png *.jpg *.jpeg *.webp)")
        if path:
            covers = DATA_DIR / "Covers"; covers.mkdir(exist_ok=True)
            dest = covers / f"{game_id}{Path(path).suffix.lower()}"; shutil.copy2(path, dest)
            self.db.set_cover(game_id, dest); self.refresh_games()

    def remove_game(self, game_id, dialog=None):
        answer = QMessageBox.question(self, "Retirer le jeu", "Retirer cette entrée de NXManager ? Les fichiers originaux ne seront pas supprimés.")
        if answer == QMessageBox.StandardButton.Yes:
            game = self.db.game(game_id)
            self.db.remove_game(game_id)
            # Only the app-created symlink directory is removed; never touch original package paths.
            if game:
                try: shutil.rmtree(game["package_dir"])
                except OSError: pass
            if dialog: dialog.accept()
            self.refresh_games()

    def start_build(self, game_id):
        game = self.db.game(game_id)
        if not game: return
        self.build_dialog = BuildDialog(game, self.db, self.engine, self.keys_path, self.output_dir, self)
        self.build_dialog.exec()
        self.refresh_games()

    def refresh_engine_status(self):
        status = self.engine.status()
        label = f"Moteur : {status['version']}" if status.get("valid") else "Moteur : non configuré"
        self.engine_sidebar.setText(label)

    def show_settings(self):
        dlg = QDialog(self); dlg.setWindowTitle("Réglages NXManager"); dlg.resize(720, 560)
        root = QVBoxLayout(dlg); root.addWidget(title_label("Réglages"))
        form = QFormLayout()
        theme = QComboBox(); theme.addItem("Clair", "light"); theme.addItem("Sombre", "dark"); theme.setCurrentIndex(0 if self.theme_name == "light" else 1)
        engine_path = QLineEdit(str(self.engine.path)); engine_browse = button("Choisir…")
        engine_row = QHBoxLayout(); engine_row.addWidget(engine_path, 1); engine_row.addWidget(engine_browse)
        engine_browse.clicked.connect(lambda: engine_path.setText(QFileDialog.getExistingDirectory(dlg, "Dossier NX Native", engine_path.text()) or engine_path.text()))
        keys = QLineEdit(self.keys_path); keys_browse = button("Choisir…")
        keys_row = QHBoxLayout(); keys_row.addWidget(keys, 1); keys_row.addWidget(keys_browse)
        keys_browse.clicked.connect(lambda: keys.setText(QFileDialog.getOpenFileName(dlg, "prod.keys", str(Path.home()))[0] or keys.text()))
        output = QLineEdit(str(self.output_dir)); output_browse = button("Choisir…")
        out_row = QHBoxLayout(); out_row.addWidget(output, 1); out_row.addWidget(output_browse)
        output_browse.clicked.connect(lambda: output.setText(QFileDialog.getExistingDirectory(dlg, "Dossier de sortie", output.text()) or output.text()))
        form.addRow("Apparence", theme); form.addRow("Dépôt NX Native", engine_row); form.addRow("prod.keys", keys_row); form.addRow("Dossier de sortie", out_row)
        root.addLayout(form)
        engine_status = self.engine.status()
        root.addWidget(muted(f"État du moteur : {engine_status['message']} · commit {engine_status.get('version') or 'inconnu'}"))
        engine_actions = QHBoxLayout()
        install = button("Installer NX Native"); update = button("Rechercher des mises à jour"); rollback = button("Restaurer la version précédente"); diag = button("Diagnostic système")
        engine_actions.addWidget(install); engine_actions.addWidget(update); engine_actions.addWidget(rollback); engine_actions.addWidget(diag); root.addLayout(engine_actions)
        diagnostics = QTextEdit(); diagnostics.setReadOnly(True); diagnostics.setMaximumHeight(130); diagnostics.setVisible(False); root.addWidget(diagnostics)
        diag.clicked.connect(lambda: (diagnostics.setVisible(True), diagnostics.setPlainText("\n".join(f"{k} : {v}" for k,v in self.engine.diagnostics().items()))))
        install.clicked.connect(lambda: self.install_engine(engine_path.text(), dlg))
        update.clicked.connect(lambda: self.update_engine(dlg))
        rollback.clicked.connect(lambda: self.rollback_engine(dlg))
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(dlg.accept); buttons.rejected.connect(dlg.reject); root.addWidget(buttons)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            self.theme_name = theme.currentData(); self.db.set_setting("theme", self.theme_name)
            self.db.set_setting("engine_path", engine_path.text()); self.db.set_setting("keys_path", keys.text())
            self.db.set_setting("output_dir", output.text())
            self.keys_path = keys.text(); self.output_dir = Path(output.text()).expanduser()
            self.engine = EngineManager(engine_path.text())
            self.apply_theme(); self.refresh_engine_status(); self.refresh_import_status()

    def install_engine(self, path, parent):
        target = Path(path).expanduser()
        answer = QMessageBox.question(parent, "Installer NX Native", f"Cloner le dépôt officiel dans :\n{target}\n\nLes dépendances système ne seront pas installées automatiquement.")
        if answer != QMessageBox.StandardButton.Yes: return
        try:
            result = EngineManager(target).install()
            if result.returncode != 0: raise RuntimeError(result.stderr or result.stdout)
            QMessageBox.information(parent, "Installation terminée", "Le dépôt NX Native a été cloné. Vérifie maintenant les dépendances système dans Diagnostic.")
        except Exception as exc: QMessageBox.critical(parent, "Installation impossible", str(exc))

    def update_engine(self, parent):
        answer = QMessageBox.question(parent, "Mettre à jour NX Native", "Créer un point de restauration Git puis effectuer un git pull --ff-only ? Aucun build ne doit être en cours.")
        if answer != QMessageBox.StandardButton.Yes: return
        try:
            old, result = self.engine.update()
            if result.returncode != 0: raise RuntimeError(result.stderr or result.stdout)
            self.db.set_setting("engine_previous_commit", old)
            QMessageBox.information(parent, "Moteur mis à jour", f"Ancien commit sauvegardé : {old[:12]}\nNouveau commit : {self.engine.status().get('version')}")
            self.refresh_engine_status()
        except Exception as exc: QMessageBox.critical(parent, "Mise à jour impossible", str(exc))

    def rollback_engine(self, parent):
        commit = self.db.get_setting("engine_previous_commit")
        if not commit:
            QMessageBox.information(parent, "Aucune restauration", "Aucun commit précédent n'est enregistré par NXManager.")
            return
        answer = QMessageBox.question(parent, "Restaurer NX Native", f"Revenir au commit {commit[:12]} ?")
        if answer != QMessageBox.StandardButton.Yes: return
        result = self.engine.rollback(commit)
        if result.returncode != 0: QMessageBox.critical(parent, "Restauration impossible", result.stderr or result.stdout)
        else:
            QMessageBox.information(parent, "Version restaurée", f"NX Native est revenu au commit {commit[:12]}.")
            self.refresh_engine_status()

    def apply_theme(self):
        self.setStyleSheet(LIGHT if self.theme_name == "light" else DARK)

    def on_devices_changed(self, devices):
        current = self.controller_device_combo.currentData() if self.controller_device_combo.count() else None
        self.controller_device_combo.blockSignals(True); self.controller_device_combo.clear()
        for d in devices: self.controller_device_combo.addItem(d["name"], d["index"])
        if current is not None:
            idx = self.controller_device_combo.findData(current)
            if idx >= 0: self.controller_device_combo.setCurrentIndex(idx)
        self.controller_device_combo.blockSignals(False)
        self.controller_device_combo.setVisible(bool(devices))
        if not devices:
            self.controller_device_label.setText("Aucune manette détectée · connecte une manette en USB ou Bluetooth.")
            self._active_device = None
        else:
            self.controller_device_label.setText(f"{len(devices)} manette(s) détectée(s)")
            self._selected_device_changed(self.controller_device_combo.currentIndex())

    def _selected_device_changed(self, combo_index):
        device_index = self.controller_device_combo.currentData()
        if device_index is None: return
        self._selected_device_index = int(device_index)
        self._active_device = {"name": self.monitor.device_name(self._selected_device_index), "id": f"{self.monitor.device_name(self._selected_device_index)}:{self._selected_device_index}"}

    def on_controller_error(self, message):
        self.controller_error_label.setText(message)

    def start_calibration(self):
        if not self.monitor.available:
            QMessageBox.warning(self, "Détection indisponible", "La détection native GameController n'est pas disponible sur cet environnement. Lance NXManager sur macOS avec les dépendances optionnelles installées.")
            return
        devices = self.monitor.devices()
        if not devices:
            QMessageBox.information(self, "Connecte une manette", "Aucune manette n'est détectée pour le moment.")
            return
        selected = self.controller_device_combo.currentData()
        self._selected_device_index = int(selected) if selected is not None else 0
        self._calibration_index = 0; self._calibration_mapping = {}; self._active_device = {"name": self.monitor.device_name(self._selected_device_index), "id": f"{self.monitor.device_name(self._selected_device_index)}:{self._selected_device_index}"}
        self.calibration_start_btn.setEnabled(False); self.calibration_skip_btn.setEnabled(True); self.calibration_retry_btn.setEnabled(False); self.calibration_finish_btn.setEnabled(False)
        self._show_calibration_step()

    def _show_calibration_step(self):
        if self._calibration_index >= len(CALIBRATION_STEPS):
            self.calibration_title.setText("Calibration terminée")
            self.calibration_instruction.setText("Toutes les entrées prévues ont été parcourues. Vérifie le profil puis enregistre-le.")
            self.calibration_capture.setText("Prêt à enregistrer")
            self.calibration_finish_btn.setEnabled(True); self.calibration_skip_btn.setEnabled(False)
            return
        target = CALIBRATION_STEPS[self._calibration_index]
        self.calibration_title.setText(f"Étape {self._calibration_index + 1}/{len(CALIBRATION_STEPS)}")
        self.calibration_instruction.setText(f"Sur la manette, active maintenant : {target}. L'entrée détectée sera associée à cette commande.")
        self.calibration_capture.setText(f"Appuie sur {target}")
        self.calibration_progress.setValue(self._calibration_index)

    def on_controller_input(self, device_index, actual, strength):
        if int(device_index) != self._selected_device_index: return
        if self._calibration_index < 0 or self._calibration_index >= len(CALIBRATION_STEPS): return
        expected = CALIBRATION_STEPS[self._calibration_index]
        self._calibration_mapping[expected] = actual
        self.calibration_capture.setText(f"Détecté : {actual}  ✓")
        self.calibration_retry_btn.setEnabled(True)
        self._calibration_index += 1
        self.calibration_progress.setValue(self._calibration_index)
        self._show_calibration_step()

    def retry_previous_calibration(self):
        if self._calibration_index <= 0: return
        self._calibration_index -= 1
        self._calibration_mapping.pop(CALIBRATION_STEPS[self._calibration_index], None)
        self.calibration_finish_btn.setEnabled(False)
        self._show_calibration_step()

    def skip_calibration(self):
        if 0 <= self._calibration_index < len(CALIBRATION_STEPS):
            self._calibration_mapping[CALIBRATION_STEPS[self._calibration_index]] = None
            self.calibration_retry_btn.setEnabled(True)
            self._calibration_index += 1; self._show_calibration_step()

    def save_calibration(self):
        if not self._calibration_mapping:
            return
        name, ok = self.ask_text("Nom du profil", "Nom du profil de manette :", self._active_device.get("name", "Manette") if self._active_device else "Manette")
        if not ok or not name.strip(): return
        profile_id = str(uuid.uuid4())
        mapping = {"calibration": self._calibration_mapping, "source": "GameController.framework", "export_supported_by_engine": False}
        self.db.save_controller_profile(profile_id, name.strip(), self._active_device.get("id") if self._active_device else None, self.profile_game_combo.currentData(), mapping)
        self.calibration_title.setText("Profil enregistré")
        self.calibration_instruction.setText("Le profil GameController est conservé dans NXManager. Il documente les entrées standard rapportées par macOS. Pour les manettes HID brutes non reconnues par macOS, utilise la section Remapping HID par jeu ci-dessous : elle écrit DM_HID_MAP dans le env.txt officiel du jeu.")
        self.calibration_start_btn.setEnabled(True); self.calibration_finish_btn.setEnabled(False); self.calibration_skip_btn.setEnabled(False); self.calibration_retry_btn.setEnabled(False)
        self.refresh_controller_profiles()

    def ask_text(self, title, prompt, default=""):
        from PySide6.QtWidgets import QInputDialog
        return QInputDialog.getText(self, title, prompt, text=default)

    def refresh_hid_game_choices(self):
        if not hasattr(self, "hid_game_combo"): return
        selected = self.hid_game_combo.currentData()
        self.hid_game_combo.blockSignals(True); self.hid_game_combo.clear()
        for game in self.db.games(): self.hid_game_combo.addItem(game["name"], game["id"])
        idx = self.hid_game_combo.findData(selected)
        if idx >= 0: self.hid_game_combo.setCurrentIndex(idx)
        self.hid_game_combo.blockSignals(False)
        self.load_hid_mapping()

    def _selected_hid_game(self):
        game_id = self.hid_game_combo.currentData() if hasattr(self, "hid_game_combo") else None
        return self.db.game(game_id) if game_id else None

    def load_hid_mapping(self, *_):
        if not hasattr(self, "hid_code_fields"): return
        game = self._selected_hid_game()
        for field in self.hid_code_fields.values(): field.clear()
        self.hid_log_check.setChecked(False)
        if not game or not game.get("title_id"):
            self.hid_status.setText("Ce jeu n'a pas encore de Title ID reconnu : aucun env.txt ne peut être ciblé.")
            self.hid_save_btn.setEnabled(False); self.hid_open_log_btn.setEnabled(False)
            return
        self.hid_save_btn.setEnabled(True); self.hid_open_log_btn.setEnabled(True)
        path = env_file_for_title(game["title_id"])
        values = read_env(path)
        raw_map = values.get("DM_HID_MAP", "")
        for part in raw_map.split(","):
            if "=" in part:
                key, value = part.split("=", 1)
                if key.strip() in self.hid_code_fields:
                    self.hid_code_fields[key.strip()].setText(value.strip())
        self.hid_log_check.setChecked(values.get("DM_HID_LOG") == "1")
        self.hid_status.setText(f"Configuration par jeu : {path}\nDM_HID_MAP actuel : {raw_map or 'non défini'}")

    def save_hid_mapping(self):
        game = self._selected_hid_game()
        if not game or not game.get("title_id"):
            QMessageBox.warning(self, "Title ID manquant", "Impossible d'écrire un env.txt sans Title ID fiable.")
            return
        codes = {key: field.text().strip() for key, field in self.hid_code_fields.items()}
        if any(codes.values()) and not all(codes.values()):
            QMessageBox.warning(self, "Mapping incomplet", "Renseigne les quatre codes A, B, X et Y, ou laisse les quatre champs vides pour retirer le mapping.")
            return
        mapping = ",".join(f"{key}={codes[key]}" for key in ("A", "B", "X", "Y")) if all(codes.values()) else None
        path = env_file_for_title(game["title_id"])
        try:
            if path.is_file():
                from ..core.paths import BACKUP_DIR
                BACKUP_DIR.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, BACKUP_DIR / f"{game['title_id']}-env-{int(time.time())}.txt")
            update_env(path, {"DM_HID_MAP": mapping, "DM_HID_LOG": "1" if self.hid_log_check.isChecked() else None})
            self.hid_status.setText(f"Configuration enregistrée dans : {path}\nDM_HID_MAP : {mapping or 'retiré'}")
        except Exception as exc:
            QMessageBox.critical(self, "Écriture impossible", str(exc))

    def open_hid_log(self):
        game = self._selected_hid_game()
        if not game or not game.get("title_id"): return
        path = Path.home() / "Library" / "Logs" / "nxnative" / f"{game['title_id']}.log"
        if path.is_file():
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
        else:
            QMessageBox.information(self, "Journal introuvable", "Le journal apparaîtra après le lancement du jeu. Active DM_HID_LOG=1 puis lance une application compilée avec NX Native.")

    def refresh_profile_game_choices(self):
        if not hasattr(self, "profile_game_combo"): return
        selected = self.profile_game_combo.currentData()
        self.profile_game_combo.blockSignals(True)
        self.profile_game_combo.clear()
        self.profile_game_combo.addItem("Profil global (tous les jeux)", None)
        for game in self.db.games():
            self.profile_game_combo.addItem(f"Jeu : {game['name']}", game['id'])
        idx = self.profile_game_combo.findData(selected)
        if idx >= 0: self.profile_game_combo.setCurrentIndex(idx)
        self.profile_game_combo.blockSignals(False)

    def refresh_controller_profiles(self):
        if not hasattr(self, "profile_list"): return
        self.profile_list.clear()
        for p in self.db.controller_profiles():
            self.profile_list.addItem(f"{p['name']} · {p['device_id'] or 'manette'} · {p['updated_at'][:10]}")

    def closeEvent(self, event):
        self.monitor.stop()
        super().closeEvent(event)
