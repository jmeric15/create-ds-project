from __future__ import annotations

import os
import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "create-ds-project.sh"
# CI points this at macOS's stock /bin/bash (3.2), the oldest bash the script supports.
BASH = os.environ.get("CDP_BASH", "bash")
TASKS = ["tabular", "timeseries", "ranking", "text"]

Run = Callable[..., subprocess.CompletedProcess[str]]


@pytest.fixture(scope="session")
def git_env(tmp_path_factory: pytest.TempPathFactory) -> dict[str, str]:
    """Environment with a throwaway git config, so the user's own never leaks in."""
    gitconfig = tmp_path_factory.mktemp("git") / "gitconfig"
    gitconfig.write_text("[user]\n\tname = Test Author\n\temail = test@example.com\n")
    return {
        **os.environ,
        "GIT_CONFIG_GLOBAL": str(gitconfig),
        "GIT_CONFIG_NOSYSTEM": "1",
        "NO_COLOR": "1",
    }


@pytest.fixture(scope="session")
def run_script(git_env: dict[str, str]) -> Run:
    def run(*args: str, cwd: Path, env: dict[str, str] | None = None):
        return subprocess.run(
            [BASH, str(SCRIPT), *args],
            cwd=cwd,
            env={**git_env, **(env or {})},
            capture_output=True,
            text=True,
            timeout=120,
        )

    return run


@pytest.fixture(scope="session")
def scaffolds(tmp_path_factory: pytest.TempPathFactory, run_script: Run) -> dict[str, Path]:
    """One generated project per task, shared by the read-only tests."""
    root = tmp_path_factory.mktemp("scaffolds")
    projects = {}
    for task in TASKS:
        result = run_script(f"demo-{task}", "--task", task, "--github-user", "octocat", cwd=root)
        assert result.returncode == 0, result.stderr
        projects[task] = root / f"demo-{task}"
    return projects
