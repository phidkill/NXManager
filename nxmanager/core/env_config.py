from pathlib import Path

NXNATIVE_SUPPORT = Path.home() / "Library" / "Application Support" / "nxnative"


def env_file_for_title(title_id: str) -> Path:
    if not title_id or len(title_id) != 16 or any(c not in "0123456789abcdefABCDEF" for c in title_id):
        raise ValueError("Title ID invalide : impossible de déterminer le env.txt du jeu.")
    return NXNATIVE_SUPPORT / title_id.upper() / "env.txt"


def read_env(path: Path) -> dict[str, str]:
    result = {}
    if not path.exists():
        return result
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def update_env(path: Path, updates: dict[str, str | None]):
    """Update selected keys while preserving unrelated env.txt lines and comments."""
    path.parent.mkdir(parents=True, exist_ok=True)
    old_lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    wanted = dict(updates)
    output = []
    seen = set()
    for line in old_lines:
        stripped = line.strip()
        key = stripped.split("=", 1)[0].strip() if "=" in stripped and not stripped.startswith("#") else None
        if key in wanted:
            value = wanted[key]
            if value is not None:
                output.append(f"{key}={value}")
            seen.add(key)
        else:
            output.append(line)
    for key, value in wanted.items():
        if key not in seen and value is not None:
            output.append(f"{key}={value}")
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("\n".join(output).rstrip() + ("\n" if output else ""), encoding="utf-8")
    tmp.replace(path)
    return path
