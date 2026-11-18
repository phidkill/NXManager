import os
import shutil
import subprocess
from pathlib import Path

from .paths import ENGINE_DIR

REPO_URL = "https://github.com/seedds/nxnative.git"

class EngineManager:
    def __init__(self, path=None):
        self.path = Path(path).expanduser() if path else ENGINE_DIR

    @property
    def build_script(self):
        return self.path / "scripts" / "build_ipa_from_nsp.py"

    def status(self):
        if not self.path.exists():
            return {"installed": False, "valid": False, "version": None, "message": "Moteur non installé"}
        valid = self.build_script.is_file()
        version = None
        if (self.path / ".git").exists():
            p = subprocess.run(["git", "-C", str(self.path), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
            version = p.stdout.strip() if p.returncode == 0 else None
        return {"installed": True, "valid": valid, "version": version,
                "message": "Moteur détecté" if valid else "Dépôt présent mais script de build absent"}

    def install(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists() and any(self.path.iterdir()):
            raise RuntimeError(f"Le dossier existe déjà et n'est pas vide : {self.path}")
        return subprocess.run(["git", "clone", "--depth", "1", REPO_URL, str(self.path)], capture_output=True, text=True)

    def update(self):
        if not (self.path / ".git").exists():
            raise RuntimeError("Le moteur sélectionné n'est pas un dépôt Git.")
        dirty = subprocess.run(["git", "-C", str(self.path), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip()
        if dirty:
            raise RuntimeError("Le dépôt NX Native contient des modifications locales. Sauvegarde-les ou nettoie le dépôt avant sa mise à jour.")
        old = subprocess.run(["git", "-C", str(self.path), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        branch = f"nxmanager-backup-{old[:10]}"
        subprocess.run(["git", "-C", str(self.path), "branch", branch, old], capture_output=True, text=True)
        checkout = subprocess.run(["git", "-C", str(self.path), "checkout", "main"], capture_output=True, text=True)
        if checkout.returncode != 0:
            raise RuntimeError(checkout.stderr or checkout.stdout)
        result = subprocess.run(["git", "-C", str(self.path), "pull", "--ff-only"], capture_output=True, text=True)
        return old, result

    def rollback(self, commit):
        return subprocess.run(["git", "-C", str(self.path), "checkout", "-B", "main", commit], capture_output=True, text=True)

    def diagnostics(self):
        def run(args):
            try:
                env = os.environ.copy()
                env["PATH"] = ":".join(["/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", "")])
                p = subprocess.run(args, capture_output=True, text=True, timeout=12, env=env)
                return (p.stdout or p.stderr).strip()
            except Exception as e:
                return str(e)
        return {
            "Architecture": run(["uname", "-m"]),
            "macOS": run(["sw_vers", "-productVersion"]),
            "Python": run(["python3", "--version"]),
            "Xcode": run(["xcodebuild", "-version"]),
            "Developer directory": run(["xcode-select", "-p"]),
            "Homebrew": run(["brew", "--prefix"]),
            "Git": run(["git", "--version"]),
            ".NET": run(["dotnet", "--version"]),
            "xcodegen": run(["xcodegen", "--version"]),
            "zstd": run(["zstd", "--version"]),
            "glslang": run(["glslangValidator", "--version"]),
        }
