from pathlib import Path
import pytest
from nxmanager.core.database import Database
from nxmanager.core import packages
from nxmanager.core.packages import inspect_package, SUPPORTED, base_title_id_for, package_matches_base

@pytest.mark.parametrize("ext", [".xci", ".NSP", ".nsz", ".XCZ"])
def test_supported_extensions_case_insensitive(tmp_path, ext):
    p = tmp_path / f"Sample [0100F2C0115B6000][v0]{ext}"
    p.write_bytes(b"test")
    info = inspect_package(p)
    assert info["title_id"] == "0100F2C0115B6000"
    assert info["version"] == "v0"
    assert info["role"] == "base"


def test_update_filename(tmp_path):
    p = tmp_path / "Sample Update [0100F2C0115B6000][v720896].nsp"
    p.write_bytes(b"test")
    info = inspect_package(p)
    assert info["role"] == "update"
    assert info["version"] == "v720896"


def test_unknown_title_id_is_not_invented(tmp_path):
    p = tmp_path / "sample.nsp"
    p.write_bytes(b"test")
    info = inspect_package(p)
    assert info["title_id"] is None
    assert info["version"] is None
    assert info["role"] == "unknown"


def test_invalid_extension_rejected(tmp_path):
    p = tmp_path / "sample.zip"
    p.write_bytes(b"test")
    with pytest.raises(ValueError):
        inspect_package(p)


def test_update_title_id_maps_to_base_title_id():
    assert base_title_id_for("0100F2C0115B6800", "update") == "0100F2C0115B6000"


def test_update_matches_base_with_standard_800_offset():
    assert package_matches_base("0100F2C0115B6800", "0100F2C0115B6000")


def test_same_title_id_remains_accepted_for_legacy_dumps():
    assert package_matches_base("0100F2C0115B6000", "0100F2C0115B6000")


def test_different_update_is_rejected():
    assert not package_matches_base("0100F2C0115B7800", "0100F2C0115B6000")


def test_reimport_replaces_stale_package_symlink(tmp_path, monkeypatch):
    link_root = tmp_path / "links"
    monkeypatch.setattr(packages, "PACKAGE_LINKS_DIR", link_root)
    db = Database(tmp_path / "catalogue.sqlite3")
    original = tmp_path / "first" / "Game [0100F2C0115B6000][v0].nsp"
    replacement = tmp_path / "second" / original.name
    original.parent.mkdir()
    replacement.parent.mkdir()
    original.write_bytes(b"old package")
    replacement.write_bytes(b"replacement package")

    game, _ = packages.register_package(db, original)
    link = link_root / game["id"] / original.name
    assert link.resolve() == original.resolve()

    packages.register_package(db, replacement)

    assert link.is_symlink()
    assert link.resolve() == replacement.resolve()
    assert {package["path"] for package in db.packages(game["id"])} == {str(replacement.resolve())}
