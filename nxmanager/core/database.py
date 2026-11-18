import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .paths import DB_PATH

SCHEMA = """
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS games (
 id TEXT PRIMARY KEY, title_id TEXT, name TEXT NOT NULL, package_dir TEXT NOT NULL,
 original_dir TEXT, cover_path TEXT, created_at TEXT NOT NULL, last_build_status TEXT
);
CREATE TABLE IF NOT EXISTS packages (
 id INTEGER PRIMARY KEY AUTOINCREMENT, game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
 path TEXT NOT NULL UNIQUE, filename TEXT NOT NULL, extension TEXT NOT NULL,
 version TEXT, role TEXT NOT NULL DEFAULT 'unknown', size INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS controller_profiles (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, device_id TEXT, game_id TEXT,
 mapping_json TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS builds (
 id INTEGER PRIMARY KEY AUTOINCREMENT, game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
 started_at TEXT NOT NULL, finished_at TEXT, status TEXT NOT NULL, duration REAL,
 output_path TEXT, engine_version TEXT, exit_code INTEGER, log_path TEXT
);
"""

class Database:
    def __init__(self, path: Path = DB_PATH):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as con:
            con.executescript(SCHEMA)

    @contextmanager
    def connect(self):
        con = sqlite3.connect(self.path)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA foreign_keys=ON")
        try:
            yield con
            con.commit()
        finally:
            con.close()

    def get_setting(self, key, default=None):
        with self.connect() as con:
            row = con.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        if not row:
            return default
        try: return json.loads(row["value"])
        except Exception: return row["value"]

    def set_setting(self, key, value):
        with self.connect() as con:
            con.execute("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        (key, json.dumps(value)))

    def games(self):
        with self.connect() as con:
            return [dict(r) for r in con.execute("SELECT * FROM games ORDER BY name COLLATE NOCASE")]

    def game(self, game_id):
        with self.connect() as con:
            row = con.execute("SELECT * FROM games WHERE id=?", (game_id,)).fetchone()
            return dict(row) if row else None

    def packages(self, game_id):
        with self.connect() as con:
            return [dict(r) for r in con.execute("SELECT * FROM packages WHERE game_id=? ORDER BY version", (game_id,))]

    def upsert_game(self, game_id, title_id, name, package_dir, original_dir=None):
        now = datetime.now(timezone.utc).isoformat()
        with self.connect() as con:
            con.execute("""INSERT INTO games(id,title_id,name,package_dir,original_dir,created_at)
                VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                title_id=COALESCE(excluded.title_id,games.title_id),
                name=CASE WHEN games.name='' THEN excluded.name ELSE games.name END,
                package_dir=excluded.package_dir, original_dir=COALESCE(excluded.original_dir,games.original_dir)""",
                (game_id, title_id, name, str(package_dir), str(original_dir) if original_dir else None, now))

    def add_package(self, game_id, path, version, role):
        p = Path(path)
        with self.connect() as con:
            con.execute("""INSERT INTO packages(game_id,path,filename,extension,version,role,size)
                VALUES(?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET
                version=excluded.version, role=excluded.role, size=excluded.size""",
                (game_id, str(p), p.name, p.suffix.lower(), version, role, p.stat().st_size if p.exists() else 0))

    def relink_package(self, package_id, new_path, version=None, role="unknown"):
        p = Path(new_path).expanduser().resolve()
        if not p.is_file():
            raise FileNotFoundError("Le nouveau fichier est introuvable.")
        with self.connect() as con:
            con.execute("UPDATE packages SET path=?,filename=?,extension=?,version=?,role=?,size=? WHERE id=?",
                        (str(p), p.name, p.suffix.lower(), version, role, p.stat().st_size, package_id))

    def set_cover(self, game_id, path):
        with self.connect() as con:
            con.execute("UPDATE games SET cover_path=? WHERE id=?", (str(path), game_id))

    def remove_game(self, game_id):
        with self.connect() as con:
            con.execute("DELETE FROM games WHERE id=?", (game_id,))

    def add_build(self, game_id, started, status, output_path=None, log_path=None, exit_code=None, duration=None, engine_version=None):
        with self.connect() as con:
            con.execute("""INSERT INTO builds(game_id,started_at,finished_at,status,duration,output_path,engine_version,exit_code,log_path)
                VALUES(?,?,?,?,?,?,?,?,?)""",
                (game_id, started, datetime.now(timezone.utc).isoformat(), status, duration,
                 str(output_path) if output_path else None, engine_version, exit_code, str(log_path) if log_path else None))
            con.execute("UPDATE games SET last_build_status=? WHERE id=?", (status, game_id))

    def builds(self, game_id):
        with self.connect() as con:
            return [dict(r) for r in con.execute("SELECT * FROM builds WHERE game_id=? ORDER BY id DESC", (game_id,))]

    def save_controller_profile(self, profile_id, name, device_id, game_id, mapping):
        with self.connect() as con:
            con.execute("""INSERT INTO controller_profiles(id,name,device_id,game_id,mapping_json,updated_at)
                VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, device_id=excluded.device_id,
                game_id=excluded.game_id, mapping_json=excluded.mapping_json, updated_at=excluded.updated_at""",
                (profile_id, name, device_id, game_id, json.dumps(mapping), datetime.now(timezone.utc).isoformat()))

    def controller_profiles(self):
        with self.connect() as con:
            return [dict(r) for r in con.execute("SELECT * FROM controller_profiles ORDER BY updated_at DESC")]
