"""Slow: install each generated project and run exactly what its own CI runs.

This is the promise the template makes: a new project is green on day one.
Run with `pytest -m integration` (needs network access to install packages).
"""

from __future__ import annotations

import csv
import os
import random
import subprocess
import venv
from datetime import datetime, timedelta
from pathlib import Path

import pytest
import yaml

from conftest import TASKS

pytestmark = pytest.mark.integration


@pytest.fixture(scope="session")
def venv_bin(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """One virtualenv shared by all tasks: their dependencies are identical."""
    path = tmp_path_factory.mktemp("venv")
    venv.create(path, with_pip=True)
    return path / "bin"


def sh(command: str, cwd: Path, venv_bin: Path) -> None:
    env = {**os.environ, "PATH": f"{venv_bin}{os.pathsep}{os.environ['PATH']}"}
    env.pop("PYTHONPATH", None)
    result = subprocess.run(
        command, shell=True, cwd=cwd, env=env, capture_output=True, text=True, timeout=1800
    )
    output = f"{result.stdout[-4000:]}\n{result.stderr[-4000:]}"
    assert result.returncode == 0, f"`{command}` failed:\n{output}"


def write_raw_data(project: Path, n: int = 600) -> None:
    """Synthetic rows with every column the task presets use, and a learnable target."""
    rng = random.Random(0)
    start = datetime(2026, 1, 1)
    path = project / "data" / "raw" / "raw.csv"
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["timestamp", "entity_id", "f1", "f2", "target"])
        for i in range(n):
            f1, f2 = rng.gauss(0, 1), rng.gauss(0, 1)
            target = int(f1 + 0.5 * rng.gauss(0, 1) > 0)
            when = (start + timedelta(minutes=30 * i)).isoformat()
            writer.writerow([when, rng.randrange(30), f1, f2, target])


@pytest.mark.parametrize("task", TASKS)
def test_generated_project_passes_its_ci_and_backtests(run_script, tmp_path, venv_bin, task):
    result = run_script(f"demo-{task}", "--task", task, cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    project = tmp_path / f"demo-{task}"

    # The `run:` steps of the generated ci.yml, in order.
    workflow = yaml.safe_load((project / ".github" / "workflows" / "ci.yml").read_text())
    steps = [step["run"] for step in workflow["jobs"]["check"]["steps"] if "run" in step]
    assert any("pytest" in step for step in steps)
    for step in steps:
        sh(step, project, venv_bin)

    # The shipped config end to end: default model, MLflow tracking, then the example experiment.
    write_raw_data(project)
    sh(f"python -m demo_{task}.cli backtest", project, venv_bin)
    report = (project / "reports" / "backtest.md").read_text()
    gate = yaml.safe_load((project / "conf" / "evaluation" / "gate.yaml").read_text())["gate"]
    assert f"({gate['primary_metric']}: " in report, report
    assert (project / "mlflow.db").exists()

    experiment = "conf/experiment/example.yaml"
    sh(f"python -m demo_{task}.cli backtest --config {experiment}", project, venv_bin)
