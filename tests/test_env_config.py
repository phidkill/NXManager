from pathlib import Path
import pytest
from nxmanager.core.env_config import env_file_for_title, read_env, update_env


def test_env_path_requires_title_id():
    with pytest.raises(ValueError):
        env_file_for_title("unknown")


def test_update_preserves_unrelated_lines(tmp_path):
    path = tmp_path / "env.txt"
    path.write_text("# comment\nDM_FPS_TARGET=30\nDM_HID_LOG=0\n", encoding="utf-8")
    update_env(path, {"DM_HID_MAP": "A=1,B=2,X=4,Y=5", "DM_HID_LOG": "1"})
    values = read_env(path)
    assert values["DM_FPS_TARGET"] == "30"
    assert values["DM_HID_LOG"] == "1"
    assert values["DM_HID_MAP"] == "A=1,B=2,X=4,Y=5"
    assert "# comment" in path.read_text(encoding="utf-8")


def test_remove_key(tmp_path):
    path = tmp_path / "env.txt"
    path.write_text("DM_HID_MAP=A=1,B=2\nDM_HID_LOG=1\n", encoding="utf-8")
    update_env(path, {"DM_HID_MAP": None, "DM_HID_LOG": None})
    assert read_env(path) == {}
