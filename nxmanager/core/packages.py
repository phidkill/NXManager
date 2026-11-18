import hashlib
import re
import uuid
from pathlib import Path

from .paths import PACKAGE_LINKS_DIR

SUPPORTED = {".xci", ".nsp", ".nsz", ".xcz"}
TITLE_RE = re.compile(r"\[([0-9A-Fa-f]{16})\]")
VERSION_RE = re.compile(r"\[v(\d+)\]", re.IGNORECASE)


def inspect_package(path: Path):
    path = Path(path).expanduser().resolve()
    if not path.is_file() or path.suffix.lower() not in SUPPORTED:
        raise ValueError("Choisis un package XCI, NSP, NSZ ou XCZ existant.")
    title_match = TITLE_RE.search(path.name)
    version_match = VERSION_RE.search(path.name)
    title_id = title_match.group(1).upper() if title_match else None
    version_num = int(version_match.group(1)) if version_match else None
    version = f"v{version_num}" if version_num is not None else None
    role = "base" if version_num == 0 else ("update" if version_num is not None else "unknown")
    base_title_id = base_title_id_for(title_id, role)
    name = re.sub(r"\s*\[[^]]+\]", "", path.stem).strip(" _-") or (title_id or path.stem)
    return {"path": path, "title_id": title_id, "base_title_id": base_title_id, "version": version, "role": role, "name": name}


def base_title_id_for(title_id, role):
    """Return the application (base-game) Title ID for a package.

    Nintendo Switch update/patch titles conventionally use the base Title ID
    plus 0x800. Keep an already-base ID unchanged for compatibility with
    dumps whose filenames expose the application ID for every package.
    """
    if not title_id:
        return None
    value = int(title_id, 16)
    if role == "update" and value >= 0x800:
        value -= 0x800
    return f"{value:016X}"


def package_matches_base(update_title_id, base_title_id):
    """Whether an update Title ID belongs to the selected base application."""
    if not update_title_id or not base_title_id:
        return False
    update = update_title_id.upper()
    base = base_title_id.upper()
    return update == base or base_title_id_for(update, "update") == base


def register_package(db, path: Path, role=None):
    info = inspect_package(path)
    if role in {"base", "update"}:
        info["role"] = role
    info["base_title_id"] = base_title_id_for(info["title_id"], info["role"])
    # If an update is named with the base ID itself, preserve that existing
    # game. Otherwise normalize the conventional patch ID (base + 0x800).
    if info["role"] == "update" and info["title_id"]:
        existing = db.game(info["title_id"].lower())
        if existing:
            info["base_title_id"] = info["title_id"]
    if info["base_title_id"]:
        game_id = info["base_title_id"].lower()
        name = info["name"]
        if info["role"] == "update":
            name = re.sub(r"\s+(update|patch)$", "", name, flags=re.IGNORECASE).strip() or name
        package_dir = PACKAGE_LINKS_DIR / game_id
    else:
        digest = hashlib.sha1(str(info["path"]).encode()).hexdigest()[:12]
        game_id = f"unknown-{digest}"
        name = info["name"]
        package_dir = PACKAGE_LINKS_DIR / game_id
    package_dir.mkdir(parents=True, exist_ok=True)
    link = package_dir / info["path"].name
    if link.is_symlink():
        if link.resolve() != info["path"]:
            link.unlink()
            link.symlink_to(info["path"])
    elif link.exists():
        raise FileExistsError(f"Package link path is occupied by a non-symlink: {link}")
    else:
        link.symlink_to(info["path"])
    for package in db.packages(game_id):
        if package["filename"] == info["path"].name and package["path"] != str(info["path"]):
            db.remove_package(package["id"])
    db.upsert_game(game_id, info["base_title_id"], name, package_dir, info["path"].parent)
    db.add_package(game_id, info["path"], info["version"], info["role"])
    return db.game(game_id), info
