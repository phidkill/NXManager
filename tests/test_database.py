from nxmanager.core.database import Database


def test_settings_roundtrip(tmp_path):
    db = Database(tmp_path / "test.sqlite3")
    db.set_setting("theme", "dark")
    assert db.get_setting("theme") == "dark"
    assert db.get_setting("missing", "default") == "default"
