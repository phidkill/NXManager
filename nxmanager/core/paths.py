from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "NXManager"
DATA_DIR = APP_SUPPORT / "Data"
ENGINE_DIR = APP_SUPPORT / "Engine" / "nxnative"
LOG_DIR = APP_SUPPORT / "Logs"
BACKUP_DIR = APP_SUPPORT / "Backups"
PACKAGE_LINKS_DIR = DATA_DIR / "PackageLinks"
BUILD_WORK_DIR = DATA_DIR / "Builds"

for directory in (DATA_DIR, LOG_DIR, BACKUP_DIR, PACKAGE_LINKS_DIR, BUILD_WORK_DIR):
    directory.mkdir(parents=True, exist_ok=True)

DB_PATH = DATA_DIR / "nxmanager.sqlite3"
