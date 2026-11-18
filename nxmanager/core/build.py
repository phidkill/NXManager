import json
import os
import platform
import re
import shutil
import subprocess
import time
from pathlib import Path
from PySide6.QtCore import QObject, Signal, QProcess, QProcessEnvironment

from .paths import BUILD_WORK_DIR

class BuildRunner(QObject):
    event = Signal(dict)
    log = Signal(str)
    finished = Signal(int, float, str)

    def __init__(self, engine_script: Path, game: dict, keys_path: str, output_dir: Path, parent=None):
        super().__init__(parent)
        self.engine_script = Path(engine_script)
        self.game = game
        self.keys_path = Path(keys_path).expanduser()
        self.output_dir = Path(output_dir).expanduser()
        self.work_dir = BUILD_WORK_DIR / self.game["id"]
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        safe_name = "".join(c for c in self.game["name"] if c.isalnum() or c in " -_").strip() or self.game["id"]
        self.output_path = self.output_dir / f"{safe_name}.app"
        self.process = QProcess(self)
        self.process.setProcessChannelMode(QProcess.ProcessChannelMode.SeparateChannels)
        env = QProcessEnvironment.systemEnvironment()
        old_path = env.value("PATH", "")
        search_path = ":".join(["/opt/homebrew/bin", "/usr/local/bin", old_path])
        env.insert("PATH", search_path)
        env.insert("PYTHONUNBUFFERED", "1")
        self.process.setProcessEnvironment(env)
        self.python_executable = shutil.which("python3", path=search_path) or "python3"
        self.process.setWorkingDirectory(str(self.engine_script.parent.parent))
        self.process.readyReadStandardOutput.connect(self._read_stdout)
        self.process.readyReadStandardError.connect(self._read_stderr)
        self.process.finished.connect(self._on_finished)
        self.started_at = 0.0
        self._stdout_buffer = ""
        self._stderr_buffer = ""

    def command(self):
        return [
            self.python_executable, str(self.engine_script), str(self.game["package_dir"]),
            "-k", str(self.keys_path), "--platform", "mac-app", "--progress", "json",
            "--work-dir", str(self.work_dir), "-o", str(self.output_path)
        ]

    def start(self):
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("Les builds NX Native de cette configuration nécessitent macOS sur Apple Silicon.")
        check_env = os.environ.copy()
        check_env["PATH"] = ":".join(["/opt/homebrew/bin", "/usr/local/bin", check_env.get("PATH", "")])
        version_result = subprocess.run([self.python_executable, "--version"], capture_output=True, text=True, timeout=10, env=check_env)
        version_text = version_result.stdout or version_result.stderr
        match = re.search(r"Python (\d+)\.(\d+)", version_text)
        if not match or (int(match.group(1)), int(match.group(2))) < (3, 12):
            raise RuntimeError(f"Python 3.12+ est requis pour NX Native. Interpréteur détecté : {version_text.strip() or 'inconnu'}")
        if not self.engine_script.is_file():
            raise FileNotFoundError(f"Script NX Native introuvable : {self.engine_script}")
        if not self.keys_path.is_file() or not os.access(self.keys_path, os.R_OK):
            raise FileNotFoundError("Le fichier prod.keys est absent ou illisible.")
        if not any(Path(self.game["package_dir"]).glob("*")):
            raise FileNotFoundError("Aucun package n'est présent dans le dossier de travail du jeu.")
        self.started_at = time.monotonic()
        command = self.command()
        self.process.start(command[0], command[1:])
        if not self.process.waitForStarted(5000):
            raise RuntimeError(self.process.errorString())

    def cancel(self):
        if self.process.state() != QProcess.ProcessState.NotRunning:
            self.process.terminate()
            if not self.process.waitForFinished(5000):
                self.process.kill()

    def _read_stdout(self):
        self._stdout_buffer += bytes(self.process.readAllStandardOutput()).decode("utf-8", "replace")
        while "\n" in self._stdout_buffer:
            line, self._stdout_buffer = self._stdout_buffer.split("\n", 1)
            self._consume_line(line)

    def _consume_line(self, line):
        line = line.strip()
        if not line:
            return
        try:
            data = json.loads(line)
            if isinstance(data, dict) and "ev" in data:
                self.event.emit(data)
                return
        except json.JSONDecodeError:
            pass
        self.log.emit(line)

    def _read_stderr(self):
        data = bytes(self.process.readAllStandardError()).decode("utf-8", "replace")
        if data:
            self._stderr_buffer += data
            self.log.emit(data.rstrip())

    def _on_finished(self, exit_code, exit_status):
        if self._stdout_buffer.strip():
            self._consume_line(self._stdout_buffer)
            self._stdout_buffer = ""
        elapsed = max(0.0, time.monotonic() - self.started_at)
        self.finished.emit(int(exit_code), elapsed, self._stderr_buffer)
