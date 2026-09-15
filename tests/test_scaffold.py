"""What the script generates, checked without installing anything."""

from __future__ import annotations

import ast
import json
import os
import shutil
import subprocess
import tomllib
from pathlib import Path

import pytest
import yaml

from conftest import SCRIPT, TASKS

PRESETS = {
    "tabular": ("random", "mean", "rmse", False),
    "timeseries": ("walkforward", "seasonal_naive", "rmse", False),
    "ranking": ("group", "random_ranking", "ndcg", True),
    "text": ("stratified", "majority", "f1", True),
}


def project_files(project: Path) -> list[Path]:
    return [p for p in project.rglob("*") if p.is_file() and ".git" not in p.parts]


def registry_keys(module: Path, name: str) -> set[str]:
    """Keys of a module-level dict literal, read without importing the module."""
    for node in ast.parse(module.read_text()).body:
        target = getattr(node, "target", None) or (getattr(node, "targets", None) or [None])[0]
        if isinstance(target, ast.Name) and target.id == name and isinstance(node.value, ast.Dict):
            return {key.value for key in node.value.keys if isinstance(key, ast.Constant)}
    raise AssertionError(f"{name} not found in {module}")


@pytest.mark.parametrize("task", TASKS)
def test_every_placeholder_is_substituted(scaffolds, task):
    for path in project_files(scaffolds[task]):
        text = path.read_text()
        for placeholder in ("__PKG__", "__PROJECT__", "__USER__"):
            assert placeholder not in text, f"{placeholder} left in {path.name}"


@pytest.mark.parametrize("task", TASKS)
def test_generated_files_parse(scaffolds, task):
    project = scaffolds[task]
    for path in project_files(project):
        if path.suffix == ".py":
            compile(path.read_text(), str(path), "exec")
        elif path.suffix in {".yaml", ".yml"}:
            yaml.safe_load(path.read_text())
        elif path.suffix == ".ipynb":
            json.loads(path.read_text())
    pyproject = tomllib.loads((project / "pyproject.toml").read_text())
    assert pyproject["project"]["name"] == f"demo-{task}"
    assert pyproject["project"]["scripts"] == {f"demo_{task}": f"demo_{task}.cli:app"}


@pytest.mark.parametrize("task", TASKS)
def test_task_preset_is_wired_to_code_that_exists(scaffolds, task):
    project = scaffolds[task]
    splitter, baseline, metric, greater_is_better = PRESETS[task]
    config = yaml.safe_load((project / "conf" / "config.yaml").read_text())
    gate = yaml.safe_load((project / "conf" / "evaluation" / "gate.yaml").read_text())

    assert config["task"] == task
    assert f"splitter/{splitter}.yaml" in config["includes"]
    assert gate["baseline"]["kind"] == baseline
    assert gate["gate"]["primary_metric"] == metric
    assert gate["gate"]["greater_is_better"] is greater_is_better

    package = project / "src" / f"demo_{task}"
    assert metric in registry_keys(package / "model" / "metrics.py", "REGISTRY")
    assert baseline in registry_keys(package / "model" / "baselines.py", "_REGISTRY")


def test_initial_commit_is_on_main_and_leaves_a_clean_tree(scaffolds):
    project = scaffolds["tabular"]

    def git(*args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=project, capture_output=True, text=True, check=True
        ).stdout.strip()

    assert git("branch", "--show-current") == "main"
    assert git("rev-list", "--count", "HEAD") == "1"
    assert git("status", "--porcelain") == ""
    tracked = git("ls-files").splitlines()
    assert "data/raw/.gitkeep" in tracked
    assert not any(name.startswith((".venv", "mlruns")) for name in tracked)


def test_writes_nothing_outside_the_project(run_script, tmp_path):
    result = run_script("demo", "--no-git", cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    assert [p.name for p in tmp_path.iterdir()] == ["demo"]
    assert not (tmp_path / "demo" / ".git").exists()


def test_author_and_github_user_land_in_the_project(run_script, tmp_path):
    result = run_script(
        "demo",
        "--no-git",
        "--author",
        "Ada Lovelace <ada@example.com>",
        "--github-user",
        "ada",
        cwd=tmp_path,
    )
    assert result.returncode == 0, result.stderr
    project = tmp_path / "demo"
    pyproject = tomllib.loads((project / "pyproject.toml").read_text())
    assert pyproject["project"]["authors"] == [{"name": "Ada Lovelace", "email": "ada@example.com"}]
    assert "Ada Lovelace" in (project / "LICENSE").read_text()
    assert "github.com/ada/demo/actions" in (project / "README.md").read_text()


def test_email_is_only_published_when_passed_explicitly(run_script, tmp_path):
    result = run_script("demo", "--no-git", cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    pyproject = tomllib.loads((tmp_path / "demo" / "pyproject.toml").read_text())
    assert pyproject["project"]["authors"] == [{"name": "Test Author"}]
    assert "test@example.com" not in (tmp_path / "demo" / "pyproject.toml").read_text()


def test_works_without_any_git_identity(run_script, tmp_path):
    empty = tmp_path / "empty-gitconfig"
    empty.write_text("")
    workdir = tmp_path / "work"
    workdir.mkdir()
    result = run_script("demo", cwd=workdir, env={"GIT_CONFIG_GLOBAL": str(empty)})
    assert result.returncode == 0, result.stderr
    assert "Your Name" in (workdir / "demo" / "LICENSE").read_text()


def test_script_is_executable():
    assert os.access(SCRIPT, os.X_OK)


@pytest.mark.skipif(shutil.which("shellcheck") is None, reason="shellcheck not installed")
def test_script_passes_shellcheck():
    result = subprocess.run(["shellcheck", str(SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout


@pytest.mark.skipif(shutil.which("zizmor") is None, reason="zizmor not installed")
def test_generated_workflows_pass_zizmor(scaffolds):
    workflows = scaffolds["tabular"] / ".github"
    result = subprocess.run(["zizmor", "--offline", str(workflows)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.skipif(shutil.which("make") is None, reason="make not installed")
def test_makefile_targets_are_listed(scaffolds):
    project = scaffolds["tabular"]
    result = subprocess.run(["make", "help"], cwd=project, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    for target in ("install", "test", "backtest"):
        assert target in result.stdout
