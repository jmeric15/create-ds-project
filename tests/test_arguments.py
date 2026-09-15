"""The script must reject bad input before it writes anything."""

from __future__ import annotations

import pytest


def test_help_prints_usage(run_script, tmp_path):
    for flag in ("-h", "--help"):
        result = run_script(flag, cwd=tmp_path)
        assert result.returncode == 0
        assert "--task" in result.stdout
    assert list(tmp_path.iterdir()) == []


def test_no_arguments_prints_usage_and_fails(run_script, tmp_path):
    result = run_script(cwd=tmp_path)
    assert result.returncode != 0
    assert "--task" in result.stderr


@pytest.mark.parametrize(
    "name",
    ["bad name", "../escape", "a/b", "-rf", "_private", "$(touch pwned)", "demo;touch pwned", ""],
)
def test_rejects_unsafe_project_names(run_script, tmp_path, name):
    result = run_script(name, cwd=tmp_path)
    assert result.returncode != 0
    assert list(tmp_path.iterdir()) == [], "something was written despite the bad name"
    assert not (tmp_path.parent / "escape").exists()


@pytest.mark.parametrize(
    "args",
    [
        ["--task", "vision"],
        ["--task"],
        ["--task", "--no-git"],
        ["--package", "Bad-Name"],
        ["--package", "import"],
        ["--package", "pandas"],
        ["--author", 'Ada "Countess" Lovelace'],
        ["--author", "Ada \\ Lovelace"],
        ["--author", "Ada <not-an-email>"],
        ["--github-user", "bad/user"],
        ["--frobnicate"],
    ],
)
def test_rejects_bad_options_before_writing_anything(run_script, tmp_path, args):
    result = run_script("demo", *args, cwd=tmp_path)
    assert result.returncode != 0
    assert "[err]" in result.stderr
    assert list(tmp_path.iterdir()) == []


def test_refuses_to_touch_an_existing_directory(run_script, tmp_path):
    existing = tmp_path / "demo"
    existing.mkdir()
    (existing / "notes.txt").write_text("keep me")

    result = run_script("demo", cwd=tmp_path)

    assert result.returncode != 0
    assert "already exists" in result.stderr
    assert [p.name for p in existing.iterdir()] == ["notes.txt"]
    assert (existing / "notes.txt").read_text() == "keep me"


def test_derives_a_valid_package_name_from_the_project_name(run_script, tmp_path):
    result = run_script("My-Churn-Model", "--no-git", cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "My-Churn-Model" / "src" / "my_churn_model" / "__init__.py").is_file()
