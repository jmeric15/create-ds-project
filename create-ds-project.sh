#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Data science project scaffold
#
# Creates a standalone, publishable DS project with the three-pipeline spine
# (data -> model -> evaluation), four pluggable points (splitter, baseline,
# metrics, model), config split into schema (code) and values (yaml), a
# champion/challenger promotion gate, and property-tested splitters.
#
#   create-ds-project.sh <project-name> [--task tabular|timeseries|ranking|text]
#                                       [--package <python_pkg_name>]
#                                       [--author "Name <email>"]
#                                       [--github-user <username>]
#                                       [--no-git]
#
#   --task         preset for splitter, baseline and gate metric (default: tabular)
#   --package      import name (default: project name, lowercased, - becomes _)
#   --author       for pyproject.toml and LICENSE (default: git config user.name)
#   --github-user  for the README CI badge (default: git config github.user)
#   --no-git       skip git init and the initial commit
#
# Writes ./<project-name> in the current directory. Makes no network calls.
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi
# printf '%s' prints user-supplied text verbatim; echo -e would interpret escapes in it.
info()  { printf '%b[ok]%b %s\n' "$GREEN" "$NC" "$1"; }
warn()  { printf '%b[!]%b %s\n' "$YELLOW" "$NC" "$1"; }
die()   { printf '%b[err]%b %s\n' "$RED" "$NC" "$1" >&2; exit 1; }
head_() { printf '\n%b== %s ==%b\n' "$BLUE" "$1" "$NC"; }

usage() {
  # Print the comment block at the top of this file, minus the shebang.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit "${1:-0}"
}

[[ $# -eq 0 ]] && usage 1 >&2
[[ "$1" == "-h" || "$1" == "--help" ]] && usage 0

PROJECT="$1"; shift
TASK="tabular"; PKG=""; AUTHOR=""; GH_USER=""; DO_GIT=1

# An option's value must be present and must not be the next flag.
value() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)        value "$@"; TASK="$2"; shift 2 ;;
    --package)     value "$@"; PKG="$2"; shift 2 ;;
    --author)      value "$@"; AUTHOR="$2"; shift 2 ;;
    --github-user) value "$@"; GH_USER="$2"; shift 2 ;;
    --no-git)      DO_GIT=0; shift ;;
    -h|--help)     usage 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate everything before touching the filesystem. Every value below ends
# up inside generated files (and a sed replacement), so each is restricted to
# characters that are inert in all of them.
# ---------------------------------------------------------------------------
[[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
  die "project name must start with a letter or digit and contain only letters, digits, - and _ (got '$PROJECT')"
[[ "$TASK" =~ ^(tabular|timeseries|ranking|text)$ ]] || die "--task must be tabular|timeseries|ranking|text"
[[ -e "$PROJECT" || -L "$PROJECT" ]] && die "'$PROJECT' already exists here"

[[ -z "$PKG" ]] && PKG="$(printf '%s' "${PROJECT//-/_}" | tr '[:upper:]' '[:lower:]')"
[[ "$PKG" =~ ^[a-z_][a-z0-9_]*$ ]] ||
  die "package name must be a lowercase python identifier (got '$PKG'); pass --package"
# Python keywords, and names that would shadow something the scaffold imports.
reserved="and as assert async await break class continue def del elif else except finally for from global"
reserved="$reserved if import in is lambda nonlocal not or pass raise return try while with yield tests"
reserved="$reserved hypothesis lightgbm matplotlib mlflow numpy optuna pandas pyarrow pydantic pytest sklearn typer yaml"
[[ " $reserved " == *" $PKG "* ]] &&
  die "'$PKG' can't be the package name: it is a python keyword or clashes with a dependency; pass --package"

[[ -z "$AUTHOR" ]] && AUTHOR="$(git config --get user.name 2>/dev/null || true)"
case "$AUTHOR" in *\"* | *\\*) die "--author must not contain quotes or backslashes" ;; esac
[[ "$AUTHOR" =~ [[:cntrl:]] ]] && die "--author must not contain control characters"
AUTHOR_NAME="$(printf '%s' "$AUTHOR" | sed -e 's/<.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
AUTHOR_EMAIL="$(printf '%s' "$AUTHOR" | sed -n 's/.*<\(.*\)>.*/\1/p')"
if [[ -n "$AUTHOR_EMAIL" && ! "$AUTHOR_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
  die "--author email doesn't look like an email address (got '$AUTHOR_EMAIL')"
fi

[[ -z "$GH_USER" ]] && GH_USER="$(git config --get github.user 2>/dev/null || true)"
[[ -z "$GH_USER" || "$GH_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
  die "--github-user must be a GitHub username (got '$GH_USER')"

if [[ $DO_GIT -eq 1 ]] && ! command -v git >/dev/null 2>&1; then
  die "git not found: install it or pass --no-git"
fi

if [[ -z "$AUTHOR_NAME" ]]; then
  AUTHOR_NAME="Your Name"
  warn "no --author and no git user.name: LICENSE and pyproject.toml say '$AUTHOR_NAME'"
fi
if [[ -z "$GH_USER" ]]; then
  GH_USER="your-username"
  warn "no --github-user and no git config github.user: the README badge says '$GH_USER'"
fi
# The email is optional: it is published in pyproject.toml, so it is only
# used when passed explicitly.
if [[ -n "$AUTHOR_EMAIL" ]]; then
  AUTHORS_TOML="{name = \"$AUTHOR_NAME\", email = \"$AUTHOR_EMAIL\"}"
else
  AUTHORS_TOML="{name = \"$AUTHOR_NAME\"}"
fi

case "$TASK" in
  timeseries) SPLITTER="walkforward"; BASELINE="seasonal_naive"; METRIC="rmse"; GIB="false" ;;
  ranking)    SPLITTER="group";       BASELINE="random_ranking"; METRIC="ndcg"; GIB="true"  ;;
  text)       SPLITTER="stratified";  BASELINE="majority";       METRIC="f1";   GIB="true"  ;;
  *)          SPLITTER="random";      BASELINE="mean";           METRIC="rmse"; GIB="false" ;;
esac

head_ "Scaffolding $PROJECT (task=$TASK, package=$PKG)"
trap 'printf "%b[err]%b failed at line %s; partial scaffold left in %s\n" "$RED" "$NC" "$LINENO" "$PWD" >&2' ERR

mkdir -p "$PROJECT"/{conf/{data,model,splitter,evaluation,experiment},reports,notebooks,docs/decisions}
mkdir -p "$PROJECT"/.github/workflows "$PROJECT"/data/{raw,processed}
mkdir -p "$PROJECT"/src/"$PKG"/{data/{collectors,processors,storage},model,evaluation,feature_importance}
mkdir -p "$PROJECT"/tests/{data,model,evaluation}
cd "$PROJECT"

# ===========================================================================
# Package: config schema
# ===========================================================================
cat > "src/$PKG/__init__.py" <<'EOF'
"""__PROJECT__ — data science project."""

__version__ = "0.1.0"
EOF

cat > "src/$PKG/config.py" <<'EOF'
"""Configuration SCHEMA.

Values live in ``conf/*.yaml``. This module defines their shape, types and
defaults, and nothing else. The rule: if a setting can change between runs
without a code change, it belongs in yaml, not here.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field

Task = Literal["tabular", "timeseries", "ranking", "text"]
SplitterKind = Literal["random", "stratified", "group", "walkforward", "purged"]


class _Schema(BaseModel):
    # Unknown keys are errors: a typo in yaml must not silently fall back to a default.
    model_config = ConfigDict(extra="forbid")


class DataConfig(_Schema):
    source: str = "file"
    raw_dir: Path = Path("data/raw")
    processed_dir: Path = Path("data/processed")
    required_columns: list[str] = Field(default_factory=list)
    params: dict[str, Any] = Field(default_factory=dict)


class SplitterConfig(_Schema):
    kind: SplitterKind = "random"
    n_splits: int = 5
    test_size: float = 0.2
    horizon: int = 1  # timeseries: rows ahead to predict
    embargo: int = 0  # purged: rows dropped either side of a test fold
    group_col: str | None = None
    time_col: str | None = None


class ModelConfig(_Schema):
    name: str = "lightgbm"
    n_trials: int = 20
    # Declarative Optuna space; see model/hyperparameter_configs.py
    params: dict[str, Any] = Field(default_factory=dict)


class BaselineConfig(_Schema):
    kind: str = "mean"
    period: int = 48  # seasonal_naive: season length


class GateConfig(_Schema):
    primary_metric: str = "rmse"
    greater_is_better: bool = False
    min_relative_improvement: float = 0.0
    must_beat_baseline: bool = True


class Config(_Schema):
    project: str
    task: Task = "tabular"
    seed: int = 42
    target: str = "target"
    # Recent MLflow refuses a bare ./mlruns directory store; SQLite needs no server either.
    mlflow_uri: str = "sqlite:///mlflow.db"
    data: DataConfig = Field(default_factory=DataConfig)
    splitter: SplitterConfig = Field(default_factory=SplitterConfig)
    model: ModelConfig = Field(default_factory=ModelConfig)
    baseline: BaselineConfig = Field(default_factory=BaselineConfig)
    gate: GateConfig = Field(default_factory=GateConfig)

    def flat(self) -> dict[str, Any]:
        """Flatten for experiment-tracking params."""
        out: dict[str, Any] = {}

        def walk(prefix: str, value: Any) -> None:
            if isinstance(value, dict):
                for k, v in value.items():
                    walk(f"{prefix}.{k}" if prefix else k, v)
            else:
                out[prefix] = value

        walk("", self.model_dump(mode="json"))
        return out


def _deep_merge(base: dict[str, Any], other: dict[str, Any]) -> dict[str, Any]:
    """``base`` updated with ``other``: nested mappings merge, anything else is replaced."""
    merged = dict(base)
    for key, value in other.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def _resolve(path: Path, chain: tuple[Path, ...] = ()) -> dict[str, Any]:
    """Read a yaml file and fold in its ``includes``, recursively.

    Include paths are relative to the file that lists them. Includes apply in
    order, so later ones win, and the including file wins over all of them.
    """
    path = path.resolve()
    if path in chain:
        cycle = " -> ".join(p.name for p in (*chain, path))
        raise ValueError(f"config include cycle: {cycle}")

    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: expected a mapping at the top level")

    merged: dict[str, Any] = {}
    for include in raw.pop("includes", None) or []:
        merged = _deep_merge(merged, _resolve(path.parent / include, (*chain, path)))
    return _deep_merge(merged, raw)


def load_config(path: str | Path = "conf/config.yaml", **overrides: Any) -> Config:
    """Load a config file with its ``includes`` resolved, then apply overrides."""
    raw = _resolve(Path(path))
    if overrides:
        raw = _deep_merge(raw, overrides)
    return Config(**raw)
EOF

# ===========================================================================
# Package: data pipeline
# ===========================================================================
cat > "src/$PKG/data/__init__.py" <<'EOF'
from .data_pipeline import DataPipeline

__all__ = ["DataPipeline"]
EOF

cat > "src/$PKG/data/contracts.py" <<'EOF'
"""Data contracts. Fail fast and loudly rather than pass a bad frame downstream.

A silently wrong frame produces a plausible metric, which is the expensive
kind of failure. Everything here raises.
"""

from __future__ import annotations

import pandas as pd


class ContractError(AssertionError):
    """Raised when a frame violates its declared contract."""


def check(
    df: pd.DataFrame,
    *,
    required: list[str] | None = None,
    non_null: list[str] | None = None,
    unique: list[str] | None = None,
    min_rows: int = 1,
    name: str = "frame",
) -> pd.DataFrame:
    if len(df) < min_rows:
        raise ContractError(f"{name}: {len(df)} rows, expected at least {min_rows}")

    missing = sorted(set(required or []) - set(df.columns))
    if missing:
        raise ContractError(f"{name}: missing required columns {missing}")

    for col in non_null or []:
        n_null = int(df[col].isna().sum())
        if n_null:
            raise ContractError(f"{name}: column '{col}' has {n_null} nulls")

    if unique:
        dupes = int(df.duplicated(subset=unique).sum())
        if dupes:
            raise ContractError(f"{name}: {dupes} duplicate rows on {unique}")

    return df
EOF

cat > "src/$PKG/data/collectors/__init__.py" <<'EOF'
from .base import Collector
from .file import FileCollector

__all__ = ["Collector", "FileCollector"]
EOF

cat > "src/$PKG/data/collectors/base.py" <<'EOF'
"""Collectors acquire RAW data and cache it verbatim.

Cache the raw response before touching it. Re-running a pipeline should never
depend on an external service being up, and the cached bytes are what the run
hash is computed over.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Protocol

import pandas as pd


class Collector(Protocol):
    def collect(self) -> pd.DataFrame: ...


def content_hash(path: Path) -> str:
    """Short sha256 of a file, recorded against each run for reproducibility."""
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest[:16]
EOF

cat > "src/$PKG/data/collectors/file.py" <<'EOF'
"""Local file collector. Replace or extend with an API/SQL collector."""

from __future__ import annotations

from pathlib import Path

import pandas as pd


class FileCollector:
    """Reads csv or parquet from disk."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)

    def collect(self) -> pd.DataFrame:
        if not self.path.exists():
            raise FileNotFoundError(f"no raw data at {self.path}")
        if self.path.suffix in {".parquet", ".pq"}:
            return pd.read_parquet(self.path)
        return pd.read_csv(self.path)
EOF

cat > "src/$PKG/data/processors/__init__.py" <<'EOF'
from .base import Processor

__all__ = ["Processor"]
EOF

cat > "src/$PKG/data/processors/base.py" <<'EOF'
"""Processors turn raw frames into the modelling frame. Pure and testable."""

from __future__ import annotations

from typing import Protocol

import pandas as pd


class Processor(Protocol):
    def process(self, df: pd.DataFrame) -> pd.DataFrame: ...


class DropNullTarget:
    def __init__(self, target: str) -> None:
        self.target = target

    def process(self, df: pd.DataFrame) -> pd.DataFrame:
        return df.dropna(subset=[self.target]).reset_index(drop=True)
EOF

cat > "src/$PKG/data/storage/__init__.py" <<'EOF'
from .parquet import ParquetStore

__all__ = ["ParquetStore"]
EOF

cat > "src/$PKG/data/storage/parquet.py" <<'EOF'
"""Parquet store. Swap for duckdb when a project outgrows flat files."""

from __future__ import annotations

from pathlib import Path

import pandas as pd


class ParquetStore:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def path(self, name: str) -> Path:
        return self.root / f"{name}.parquet"

    def write(self, df: pd.DataFrame, name: str) -> Path:
        target = self.path(name)
        df.to_parquet(target, index=False)
        return target

    def read(self, name: str) -> pd.DataFrame:
        return pd.read_parquet(self.path(name))

    def exists(self, name: str) -> bool:
        return self.path(name).exists()
EOF

cat > "src/$PKG/data/data_pipeline.py" <<'EOF'
"""DataPipeline: collect -> process -> validate -> store."""

from __future__ import annotations

from pathlib import Path

import pandas as pd

from ..config import Config
from . import contracts
from .collectors.file import FileCollector
from .processors.base import DropNullTarget
from .storage.parquet import ParquetStore


class DataPipeline:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.raw_path = Path(cfg.data.raw_dir) / "raw.csv"
        self.store = ParquetStore(cfg.data.processed_dir)

    def run(self) -> pd.DataFrame:
        df = FileCollector(self.raw_path).collect()

        df = DropNullTarget(self.cfg.target).process(df)

        contracts.check(
            df,
            required=[*self.cfg.data.required_columns, self.cfg.target],
            non_null=[self.cfg.target],
            name="processed",
        )

        self.store.write(df, "dataset")
        return df
EOF

# ===========================================================================
# Package: model pipeline
# ===========================================================================
cat > "src/$PKG/model/__init__.py" <<'EOF'
from .model_pipeline import ModelPipeline

__all__ = ["ModelPipeline"]
EOF

cat > "src/$PKG/model/baselines.py" <<'EOF'
"""Baselines. Every project must declare one.

A metric without a baseline is unreadable: you cannot tell whether 0.94 is
good or whether predicting the mean would have got 0.93. This is the single
most common omission in portfolio projects.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Protocol

import numpy as np
import pandas as pd


class Baseline(Protocol):
    def fit(self, X: pd.DataFrame, y: pd.Series) -> Baseline: ...
    def predict(self, X: pd.DataFrame) -> np.ndarray: ...


class MeanBaseline:
    """Regression: predict the training mean."""

    def fit(self, X: pd.DataFrame, y: pd.Series) -> MeanBaseline:
        self.value_ = float(np.mean(y))
        return self

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        return np.full(len(X), self.value_)


class MajorityBaseline:
    """Classification: predict the modal class."""

    def fit(self, X: pd.DataFrame, y: pd.Series) -> MajorityBaseline:
        self.value_ = y.mode().iloc[0]
        return self

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        return np.full(len(X), self.value_)


class LastValueBaseline:
    """Time series: carry the last observed value forward."""

    def fit(self, X: pd.DataFrame, y: pd.Series) -> LastValueBaseline:
        self.value_ = float(y.iloc[-1])
        return self

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        return np.full(len(X), self.value_)


class SeasonalNaiveBaseline:
    """Time series: predict the value one season ago.

    For half-hourly data a day is period=48. Beating this is the minimum bar
    for claiming a forecasting model works.
    """

    def __init__(self, period: int = 48) -> None:
        self.period = period

    def fit(self, X: pd.DataFrame, y: pd.Series) -> SeasonalNaiveBaseline:
        self.history_ = np.asarray(y, dtype=float)
        return self

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        n = len(X)
        if len(self.history_) < self.period:
            return np.full(n, float(np.mean(self.history_)))
        season = self.history_[-self.period :]
        return np.resize(season, n)


class RandomRankingBaseline:
    """Ranking: shuffle. Any ranker must beat this."""

    def __init__(self, seed: int = 42) -> None:
        self.rng = np.random.default_rng(seed)

    def fit(self, X: pd.DataFrame, y: pd.Series) -> RandomRankingBaseline:
        return self

    def predict(self, X: pd.DataFrame) -> np.ndarray:
        return self.rng.random(len(X))


_REGISTRY: dict[str, Callable[..., Baseline]] = {
    "mean": MeanBaseline,
    "majority": MajorityBaseline,
    "last_value": LastValueBaseline,
    "seasonal_naive": SeasonalNaiveBaseline,
    "random_ranking": RandomRankingBaseline,
}


def build_baseline(kind: str, *, period: int = 48, seed: int = 42) -> Baseline:
    """Build a baseline by name, passing each one only the options it takes."""
    if kind not in _REGISTRY:
        raise ValueError(f"unknown baseline '{kind}'; choose from {sorted(_REGISTRY)}")
    if kind == "seasonal_naive":
        return SeasonalNaiveBaseline(period=period)
    if kind == "random_ranking":
        return RandomRankingBaseline(seed=seed)
    return _REGISTRY[kind]()
EOF

cat > "src/$PKG/model/metrics.py" <<'EOF'
"""Metric registry. Each entry knows its own direction."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

import numpy as np


def _rmse(y: np.ndarray, p: np.ndarray) -> float:
    return float(np.sqrt(np.mean((y - p) ** 2)))


def _mae(y: np.ndarray, p: np.ndarray) -> float:
    return float(np.mean(np.abs(y - p)))


def _mape(y: np.ndarray, p: np.ndarray) -> float:
    mask = y != 0
    if not mask.any():
        return float("nan")
    return float(np.mean(np.abs((y[mask] - p[mask]) / y[mask])) * 100)


def _r2(y: np.ndarray, p: np.ndarray) -> float:
    ss_res = float(np.sum((y - p) ** 2))
    ss_tot = float(np.sum((y - np.mean(y)) ** 2))
    return 1.0 - ss_res / ss_tot if ss_tot else float("nan")


def _accuracy(y: np.ndarray, p: np.ndarray) -> float:
    return float(np.mean(y == np.round(p)))


def _f1(y: np.ndarray, p: np.ndarray) -> float:
    pred = np.round(p)
    tp = float(np.sum((pred == 1) & (y == 1)))
    fp = float(np.sum((pred == 1) & (y == 0)))
    fn = float(np.sum((pred == 0) & (y == 1)))
    denom = 2 * tp + fp + fn
    return 2 * tp / denom if denom else 0.0


def _ndcg(y: np.ndarray, p: np.ndarray) -> float:
    """NDCG with linear gains, ranking the whole fold as a single list.

    Relevance must be non-negative. For per-query ranking, average this over
    the rows of each query group instead of scoring the fold as one list.
    """
    if len(y) == 0 or (y < 0).any():
        return float("nan")
    discounts = 1.0 / np.log2(np.arange(2, len(y) + 2))
    dcg = float(np.sum(y[np.argsort(-p, kind="stable")] * discounts))
    ideal = float(np.sum(np.sort(y)[::-1] * discounts))
    return dcg / ideal if ideal > 0 else float("nan")


@dataclass(frozen=True)
class Metric:
    fn: Callable[[np.ndarray, np.ndarray], float]
    greater_is_better: bool


REGISTRY: dict[str, Metric] = {
    "rmse": Metric(_rmse, False),
    "mae": Metric(_mae, False),
    "mape": Metric(_mape, False),
    "r2": Metric(_r2, True),
    "accuracy": Metric(_accuracy, True),
    "f1": Metric(_f1, True),
    "ndcg": Metric(_ndcg, True),
}


def evaluate(y_true, y_pred, names: list[str] | None = None) -> dict[str, float]:
    y = np.asarray(y_true, dtype=float)
    p = np.asarray(y_pred, dtype=float)
    keys = names or list(REGISTRY)
    return {k: REGISTRY[k].fn(y, p) for k in keys if k in REGISTRY}
EOF

cat > "src/$PKG/model/hyperparameter_configs.py" <<'EOF'
"""Translate a declarative yaml search space into Optuna suggestions.

Keeping the space in yaml means a sweep can be widened, narrowed or
reproduced without touching source.

    params:
      num_leaves:    {type: int,   low: 16,   high: 256, log: true}
      learning_rate: {type: float, low: 1e-3, high: 0.3, log: true}
      booster:       {type: categorical, choices: [gbdt, dart]}
"""

from __future__ import annotations

from typing import Any


def suggest(trial: Any, space: dict[str, dict[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for name, spec in space.items():
        kind = spec.get("type", "float")
        if kind == "int":
            out[name] = trial.suggest_int(
                name, int(spec["low"]), int(spec["high"]), log=bool(spec.get("log", False))
            )
        elif kind == "float":
            out[name] = trial.suggest_float(
                name, float(spec["low"]), float(spec["high"]), log=bool(spec.get("log", False))
            )
        elif kind == "categorical":
            out[name] = trial.suggest_categorical(name, list(spec["choices"]))
        else:
            raise ValueError(f"unsupported param type '{kind}' for '{name}'")
    return out
EOF

cat > "src/$PKG/model/preprocessing.py" <<'EOF'
"""Feature preparation. Fit on train only — never on the full frame."""

from __future__ import annotations

import pandas as pd


def split_xy(df: pd.DataFrame, target: str, drop: list[str] | None = None):
    drop_cols = [target, *(drop or [])]
    X = df.drop(columns=[c for c in drop_cols if c in df.columns])
    y = df[target]
    return X, y


def numeric_only(X: pd.DataFrame) -> pd.DataFrame:
    return X.select_dtypes(include="number").copy()
EOF

cat > "src/$PKG/model/mlflow_integration.py" <<'EOF'
"""Experiment tracking against a local SQLite store — no server needed.

Each run records the resolved config and a hash of the raw input, so any
number in reports/ can be traced back to the data and settings that produced
it. That is also what makes the promotion gate honest: champion and
challenger can be shown to have run under identical conditions.

Everything here is a no-op when the ``track`` extra (mlflow) is not installed.
"""

from __future__ import annotations

from contextlib import contextmanager

from ..config import Config

try:
    import mlflow

    HAS_MLFLOW = True
except ImportError:  # pragma: no cover - optional dependency
    HAS_MLFLOW = False


@contextmanager
def run(cfg: Config, name: str, data_hash: str | None = None):
    if not HAS_MLFLOW:
        yield None
        return

    mlflow.set_tracking_uri(cfg.mlflow_uri)
    mlflow.set_experiment(cfg.project)
    with mlflow.start_run(run_name=name) as active:
        mlflow.log_params({k: str(v)[:250] for k, v in cfg.flat().items()})
        if data_hash:
            mlflow.set_tag("data_hash", data_hash)
        yield active


def log_metrics(metrics: dict[str, float], prefix: str = "") -> None:
    if not HAS_MLFLOW:
        return
    mlflow.log_metrics({f"{prefix}{k}": v for k, v in metrics.items() if v == v})


def log_artifact(path: str) -> None:
    if not HAS_MLFLOW:
        return
    mlflow.log_artifact(path)
EOF

cat > "src/$PKG/model/training.py" <<'EOF'
"""Model training. The estimator is a plug point: anything with fit/predict."""

from __future__ import annotations

from typing import Any, Protocol

import numpy as np
import pandas as pd


class Estimator(Protocol):
    def fit(self, X: pd.DataFrame, y: pd.Series) -> Any: ...
    def predict(self, X: pd.DataFrame) -> np.ndarray: ...


def build_estimator(name: str, params: dict[str, Any] | None = None) -> Estimator:
    """Return an estimator by name. Extend as projects need."""
    params = params or {}

    if name == "lightgbm":
        from lightgbm import LGBMRegressor

        return LGBMRegressor(verbose=-1, **params)
    if name == "ridge":
        from sklearn.linear_model import Ridge

        return Ridge(**params)
    if name == "random_forest":
        from sklearn.ensemble import RandomForestRegressor

        return RandomForestRegressor(**params)
    raise ValueError(f"unknown model '{name}'")
EOF

cat > "src/$PKG/model/export.py" <<'EOF'
"""Optional ONNX export. Install with the 'onnx' extra."""

from __future__ import annotations

from pathlib import Path
from typing import Any


def to_onnx(model: Any, n_features: int, path: str | Path) -> Path:
    from skl2onnx import convert_sklearn
    from skl2onnx.common.data_types import FloatTensorType

    onx = convert_sklearn(model, initial_types=[("input", FloatTensorType([None, n_features]))])
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(onx.SerializeToString())
    return path
EOF

cat > "src/$PKG/model/model_pipeline.py" <<'EOF'
"""ModelPipeline: fit a baseline and a candidate over the configured splits."""

from __future__ import annotations

import numpy as np
import pandas as pd

from ..config import Config
from ..evaluation.splitters import build_splitter
from .baselines import build_baseline
from .metrics import evaluate
from .preprocessing import numeric_only, split_xy
from .training import build_estimator


def _mean(values: list[float]) -> float:
    """Mean over folds, ignoring folds where a metric is undefined (NaN)."""
    finite = [v for v in values if np.isfinite(v)]
    return float(np.mean(finite)) if finite else float("nan")


class ModelPipeline:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    def run(self, df: pd.DataFrame) -> dict[str, dict[str, float]]:
        X, y = split_xy(df, self.cfg.target)
        X = numeric_only(X)
        splitter = build_splitter(self.cfg)

        fold_scores: dict[str, list[dict[str, float]]] = {"candidate": [], "baseline": []}

        for train_idx, test_idx in splitter.split(df):
            X_tr, X_te = X.iloc[train_idx], X.iloc[test_idx]
            y_tr, y_te = y.iloc[train_idx], y.iloc[test_idx]

            model = build_estimator(self.cfg.model.name, self.cfg.model.params.get("fixed"))
            model.fit(X_tr, y_tr)
            fold_scores["candidate"].append(evaluate(y_te, model.predict(X_te)))

            base = build_baseline(
                self.cfg.baseline.kind,
                period=self.cfg.baseline.period,
                seed=self.cfg.seed,
            )
            base.fit(X_tr, y_tr)
            fold_scores["baseline"].append(evaluate(y_te, base.predict(X_te)))

        return {
            who: {k: _mean([f[k] for f in folds]) for k in folds[0]}
            for who, folds in fold_scores.items()
            if folds
        }
EOF

# ===========================================================================
# Package: evaluation pipeline
# ===========================================================================
cat > "src/$PKG/evaluation/__init__.py" <<'EOF'
"""Evaluation: splitters, promotion gate, reporting.

Import ``EvaluationPipeline`` from ``.evaluation_pipeline``. It is deliberately
not re-exported here: ``model.model_pipeline`` imports ``evaluation.splitters``,
and an eager re-export would turn that into a circular import that breaks
whichever module happens to be imported first.
"""
EOF

cat > "src/$PKG/evaluation/splitters.py" <<'EOF'
"""Splitters — how rows become train/test folds.

This is the highest-value module to get right, because a wrong split does not
raise: it quietly returns a better number. Every splitter here is covered by
property tests asserting no index appears on both sides, that temporal order
holds, and that embargo gaps are respected.

Time-based splitters sort by ``time_col`` and never cut between rows that share
a timestamp (e.g. several entities observed in the same period), so no test row
is ever contemporaneous with a training row.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Protocol

import numpy as np
import pandas as pd

from ..config import Config

Fold = tuple[np.ndarray, np.ndarray]


class Splitter(Protocol):
    def split(self, df: pd.DataFrame) -> Iterator[Fold]: ...


def _time_order(df: pd.DataFrame, time_col: str | None) -> tuple[np.ndarray, np.ndarray]:
    """Row indices in time order, and the sort key at each position."""
    if time_col is None:
        order = np.arange(len(df))
        return order, order
    times = df[time_col].to_numpy()
    order = np.argsort(times, kind="stable")
    return order, times[order]


def _snap(position: int, keys: np.ndarray) -> int:
    """Move a cut back to the first position sharing its key, so ties stay together."""
    if position <= 0 or position >= len(keys):
        return position
    return int(np.searchsorted(keys, keys[position], side="left"))


class RandomSplitter:
    """i.i.d. tabular data."""

    def __init__(self, n_splits: int = 5, seed: int = 42) -> None:
        self.n_splits = n_splits
        self.seed = seed

    def split(self, df: pd.DataFrame) -> Iterator[Fold]:
        idx = np.arange(len(df))
        rng = np.random.default_rng(self.seed)
        rng.shuffle(idx)
        for fold in np.array_split(idx, self.n_splits):
            if len(fold) == 0:
                continue
            test = np.sort(fold)
            train = np.sort(np.setdiff1d(idx, test))
            yield train, test


class StratifiedSplitter:
    """Preserves class balance. For imbalanced classification."""

    def __init__(self, target: str, n_splits: int = 5, seed: int = 42) -> None:
        self.target = target
        self.n_splits = n_splits
        self.seed = seed

    def split(self, df: pd.DataFrame) -> Iterator[Fold]:
        from sklearn.model_selection import StratifiedKFold

        skf = StratifiedKFold(n_splits=self.n_splits, shuffle=True, random_state=self.seed)
        yield from skf.split(np.zeros(len(df)), df[self.target])


class GroupSplitter:
    """Keeps every row of an entity on one side. Prevents entity leakage."""

    def __init__(self, group_col: str, n_splits: int = 5, seed: int = 42) -> None:
        self.group_col = group_col
        self.n_splits = n_splits
        self.seed = seed

    def split(self, df: pd.DataFrame) -> Iterator[Fold]:
        groups = df[self.group_col].to_numpy()
        unique = np.unique(groups)
        rng = np.random.default_rng(self.seed)
        rng.shuffle(unique)
        for chunk in np.array_split(unique, self.n_splits):
            if len(chunk) == 0:
                continue
            mask = np.isin(groups, chunk)
            yield np.where(~mask)[0], np.where(mask)[0]


class WalkForwardSplitter:
    """Expanding window. Train on the past, test on the future, never reverse."""

    def __init__(self, n_splits: int = 5, horizon: int = 1, time_col: str | None = None) -> None:
        self.n_splits = n_splits
        self.horizon = horizon
        self.time_col = time_col

    def split(self, df: pd.DataFrame) -> Iterator[Fold]:
        order, keys = _time_order(df, self.time_col)
        n = len(order)
        test_size = max(self.horizon, n // (self.n_splits + 1))
        for i in range(1, self.n_splits + 1):
            if i * test_size >= n:
                break
            start = _snap(i * test_size, keys)
            end = _snap(min((i + 1) * test_size, n), keys)
            if start == 0 or end <= start:
                continue  # one timestamp spans the whole window: no clean cut
            yield order[:start], order[start:end]


class PurgedKFoldSplitter:
    """K-fold with a purge/embargo band around each test fold.

    When labels are built from overlapping windows, rows adjacent to the test
    fold share information with it. Dropping them is the difference between a
    real improvement and an artefact of the split.
    """

    def __init__(self, n_splits: int = 5, embargo: int = 0, time_col: str | None = None) -> None:
        self.n_splits = n_splits
        self.embargo = embargo
        self.time_col = time_col

    def split(self, df: pd.DataFrame) -> Iterator[Fold]:
        order, keys = _time_order(df, self.time_col)
        n = len(order)
        positions = np.arange(n)
        # Fold boundaries are positions in time order (not row labels), snapped
        # so rows sharing a timestamp land in the same fold.
        sizes = np.full(self.n_splits, n // self.n_splits)
        sizes[: n % self.n_splits] += 1
        cuts = [0, *(_snap(int(c), keys) for c in np.cumsum(sizes)[:-1]), n]
        for lo, hi in zip(cuts[:-1], cuts[1:], strict=True):
            if hi <= lo:
                continue
            keep = (positions < lo - self.embargo) | (positions >= hi + self.embargo)
            yield order[keep], order[lo:hi]


def build_splitter(cfg: Config) -> Splitter:
    kind = cfg.splitter.kind
    s = cfg.splitter
    if kind == "random":
        return RandomSplitter(s.n_splits, cfg.seed)
    if kind == "stratified":
        return StratifiedSplitter(cfg.target, s.n_splits, cfg.seed)
    if kind == "group":
        if not s.group_col:
            raise ValueError("splitter.group_col is required for the group splitter")
        return GroupSplitter(s.group_col, s.n_splits, cfg.seed)
    if kind == "walkforward":
        return WalkForwardSplitter(s.n_splits, s.horizon, s.time_col)
    if kind == "purged":
        return PurgedKFoldSplitter(s.n_splits, s.embargo, s.time_col)
    raise ValueError(f"unknown splitter '{kind}'")
EOF

cat > "src/$PKG/evaluation/validation.py" <<'EOF'
"""Champion / challenger promotion gate.

Promotion requires beating the incumbent on the same split, and beating the
baseline. The gate fails closed: if the comparison cannot be made, nothing is
promoted.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

from ..config import Config
from ..model.metrics import REGISTRY


@dataclass
class GateResult:
    promoted: bool
    reasons: list[str]
    candidate: float
    champion: float | None
    baseline: float | None

    def render(self) -> str:
        verdict = "PROMOTED" if self.promoted else "REJECTED"
        lines = [f"**{verdict}**", ""]
        lines += [f"- {r}" for r in self.reasons]
        return "\n".join(lines)


def _better(a: float, b: float, greater_is_better: bool) -> bool:
    return a > b if greater_is_better else a < b


def evaluate_gate(
    cfg: Config,
    candidate: dict[str, float],
    baseline: dict[str, float] | None = None,
    champion_path: str | Path = "reports/champion.json",
) -> GateResult:
    metric = cfg.gate.primary_metric
    gib = cfg.gate.greater_is_better
    reasons: list[str] = []

    def closed(reason: str) -> GateResult:
        return GateResult(False, [f"{reason} — failing closed"], float("nan"), None, None)

    if metric in REGISTRY and REGISTRY[metric].greater_is_better != gib:
        return closed(f"gate.greater_is_better={gib} contradicts the '{metric}' metric")
    if metric not in candidate:
        return closed(f"candidate has no '{metric}'")

    cand = candidate[metric]
    if not math.isfinite(cand):
        return closed(f"candidate {metric} is {cand}")
    base = (baseline or {}).get(metric)

    champ_path = Path(champion_path)
    champ = None
    if champ_path.exists():
        champ = json.loads(champ_path.read_text()).get(metric)

    ok = True

    if cfg.gate.must_beat_baseline:
        if base is None:
            ok = False
            reasons.append("no baseline score — failing closed")
        elif not _better(cand, base, gib):
            ok = False
            reasons.append(f"does not beat baseline ({metric}: {cand:.4f} vs {base:.4f})")
        else:
            reasons.append(f"beats baseline ({metric}: {cand:.4f} vs {base:.4f})")

    if champ is None:
        reasons.append("no incumbent champion — bootstrap promotion")
    else:
        margin = abs(champ) * cfg.gate.min_relative_improvement
        threshold = champ + margin if gib else champ - margin
        if _better(cand, threshold, gib):
            reasons.append(f"beats champion ({metric}: {cand:.4f} vs {champ:.4f})")
        else:
            ok = False
            reasons.append(f"does not beat champion ({metric}: {cand:.4f} vs {champ:.4f})")

    if ok:
        champ_path.parent.mkdir(parents=True, exist_ok=True)
        # Undefined metrics become null: NaN is not valid JSON.
        record = {k: v if math.isfinite(v) else None for k, v in candidate.items()}
        champ_path.write_text(json.dumps(record, indent=2))

    return GateResult(ok, reasons, cand, champ, base)
EOF

cat > "src/$PKG/evaluation/drift.py" <<'EOF'
"""Lightweight input drift check: population stability index per column."""

from __future__ import annotations

import numpy as np
import pandas as pd


def psi(expected: pd.Series, actual: pd.Series, bins: int = 10) -> float:
    edges = np.nanpercentile(expected, np.linspace(0, 100, bins + 1))
    edges[0], edges[-1] = -np.inf, np.inf
    e = np.histogram(expected, bins=edges)[0] / max(len(expected), 1)
    a = np.histogram(actual, bins=edges)[0] / max(len(actual), 1)
    e, a = np.clip(e, 1e-6, None), np.clip(a, 1e-6, None)
    return float(np.sum((a - e) * np.log(a / e)))


def drift_report(reference: pd.DataFrame, current: pd.DataFrame) -> dict[str, float]:
    cols = set(reference.select_dtypes("number")) & set(current.select_dtypes("number"))
    return {c: psi(reference[c].dropna(), current[c].dropna()) for c in sorted(cols)}
EOF

cat > "src/$PKG/evaluation/reporting.py" <<'EOF'
"""Write a human-readable report. CI attaches this to a pull request."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from ..config import Config
from .validation import GateResult


def write_report(
    cfg: Config,
    scores: dict[str, dict[str, float]],
    gate: GateResult,
    data_hash: str | None = None,
    path: str | Path = "reports/backtest.md",
) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    metrics = sorted({m for s in scores.values() for m in s})
    header = "| model | " + " | ".join(metrics) + " |"
    divider = "|---" * (len(metrics) + 1) + "|"
    rows = [
        "| "
        + name
        + " | "
        + " | ".join(f"{scores[name].get(m, float('nan')):.4f}" for m in metrics)
        + " |"
        for name in scores
    ]

    body = f"""# Backtest — {cfg.project}

_generated {datetime.now(UTC):%Y-%m-%d %H:%M UTC}_

**Task** `{cfg.task}` · **splitter** `{cfg.splitter.kind}` ({cfg.splitter.n_splits} folds) ·
**baseline** `{cfg.baseline.kind}` · **seed** `{cfg.seed}`{f" · **data** `{data_hash}`" if data_hash else ""}

{header}
{divider}
{chr(10).join(rows)}

## Promotion gate

{gate.render()}
"""
    path.write_text(body)
    return path
EOF

cat > "src/$PKG/evaluation/evaluation_pipeline.py" <<'EOF'
"""EvaluationPipeline: score -> gate -> report."""

from __future__ import annotations

from pathlib import Path

import pandas as pd

from ..config import Config
from ..model.model_pipeline import ModelPipeline
from .reporting import write_report
from .validation import GateResult, evaluate_gate


class EvaluationPipeline:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    def run(self, df: pd.DataFrame, data_hash: str | None = None) -> tuple[dict, GateResult, Path]:
        scores = ModelPipeline(self.cfg).run(df)
        gate = evaluate_gate(self.cfg, scores.get("candidate", {}), scores.get("baseline"))
        report = write_report(self.cfg, scores, gate, data_hash)
        return scores, gate, report
EOF

cat > "src/$PKG/feature_importance/__init__.py" <<'EOF'
from .feature_importance_pipeline import permutation_importance_report

__all__ = ["permutation_importance_report"]
EOF

cat > "src/$PKG/feature_importance/feature_importance_pipeline.py" <<'EOF'
"""Feature importance. SHAP is an optional extra; permutation always works."""

from __future__ import annotations

import numpy as np
import pandas as pd

from ..model.metrics import REGISTRY


def permutation_importance_report(
    model, X: pd.DataFrame, y: pd.Series, metric: str = "rmse", n_repeats: int = 5, seed: int = 42
) -> pd.DataFrame:
    scorer = REGISTRY[metric]
    rng = np.random.default_rng(seed)
    base = scorer.fn(np.asarray(y, float), np.asarray(model.predict(X), float))

    rows = []
    for col in X.columns:
        deltas = []
        for _ in range(n_repeats):
            shuffled = X.copy()
            shuffled[col] = rng.permutation(shuffled[col].to_numpy())
            score = scorer.fn(np.asarray(y, float), np.asarray(model.predict(shuffled), float))
            deltas.append(score - base if not scorer.greater_is_better else base - score)
        rows.append({"feature": col, "importance": float(np.mean(deltas))})

    return pd.DataFrame(rows).sort_values("importance", ascending=False).reset_index(drop=True)
EOF

# ===========================================================================
# CLI
# ===========================================================================
cat > "src/$PKG/cli.py" <<'EOF'
"""Command line entry point. `make` targets call these."""

from __future__ import annotations

import typer

from .config import load_config
from .data.collectors.base import content_hash
from .data.data_pipeline import DataPipeline
from .evaluation.evaluation_pipeline import EvaluationPipeline
from .model import mlflow_integration as tracking

app = typer.Typer(add_completion=False, help="__PROJECT__")


@app.command()
def data(config: str = "conf/config.yaml") -> None:
    """Collect, process, validate and store the dataset."""
    cfg = load_config(config)
    df = DataPipeline(cfg).run()
    typer.echo(f"dataset: {len(df):,} rows x {df.shape[1]} cols")


@app.command()
def backtest(config: str = "conf/config.yaml") -> None:
    """Score candidate and baseline over the configured splits, gate, report."""
    cfg = load_config(config)
    pipeline = DataPipeline(cfg)
    df = pipeline.run()
    data_hash = content_hash(pipeline.raw_path)

    with tracking.run(cfg, "backtest", data_hash):
        scores, gate, report = EvaluationPipeline(cfg).run(df, data_hash)
        for name, metrics in scores.items():
            tracking.log_metrics(metrics, prefix=f"{name}.")
        tracking.log_artifact(str(report))

    for name, metrics in scores.items():
        rendered = "  ".join(f"{k}={v:.4f}" for k, v in metrics.items())
        typer.echo(f"{name:>10}  {rendered}")
    typer.echo(f"\ngate: {'PROMOTED' if gate.promoted else 'REJECTED'}")
    for reason in gate.reasons:
        typer.echo(f"  - {reason}")
    typer.echo(f"\nreport: {report}")
    raise typer.Exit(0)


@app.command()
def show(config: str = "conf/config.yaml") -> None:
    """Print the resolved config."""
    typer.echo(load_config(config).model_dump_json(indent=2))


if __name__ == "__main__":
    app()
EOF

# ===========================================================================
# conf/ — values
# ===========================================================================
cat > conf/config.yaml <<EOF
project: $PROJECT
task: $TASK
seed: 42
target: target
mlflow_uri: "sqlite:///mlflow.db"

includes:
  - data/source.yaml
  - model/default.yaml
  - splitter/$SPLITTER.yaml
  - evaluation/gate.yaml
EOF

cat > conf/data/source.yaml <<'EOF'
data:
  source: file
  raw_dir: data/raw
  processed_dir: data/processed
  required_columns: []
  params: {}
EOF

cat > conf/model/default.yaml <<'EOF'
model:
  name: lightgbm
  n_trials: 20
  params:
    fixed:
      n_estimators: 200
    # Declarative Optuna space -> model/hyperparameter_configs.py
    search:
      num_leaves:    {type: int,   low: 16,   high: 256, log: true}
      learning_rate: {type: float, low: 0.001, high: 0.3, log: true}
EOF

cat > conf/splitter/random.yaml <<'EOF'
splitter:
  kind: random
  n_splits: 5
EOF

cat > conf/splitter/stratified.yaml <<'EOF'
splitter:
  kind: stratified
  n_splits: 5
EOF

cat > conf/splitter/group.yaml <<'EOF'
splitter:
  kind: group
  n_splits: 5
  group_col: entity_id
EOF

cat > conf/splitter/walkforward.yaml <<'EOF'
splitter:
  kind: walkforward
  n_splits: 5
  horizon: 48
  time_col: timestamp
EOF

cat > conf/splitter/purged.yaml <<'EOF'
splitter:
  kind: purged
  n_splits: 5
  embargo: 48
  time_col: timestamp
EOF

cat > conf/evaluation/gate.yaml <<EOF
baseline:
  kind: $BASELINE
  period: 48

gate:
  primary_metric: $METRIC
  greater_is_better: $GIB
  min_relative_improvement: 0.0
  must_beat_baseline: true
EOF

cat > conf/experiment/example.yaml <<'EOF'
# Compose an experiment by overriding the base config:
#   python -m __PKG__.cli backtest --config conf/experiment/example.yaml
#
# Includes resolve relative to this file and are followed recursively, so this
# inherits the task's splitter, baseline and gate. Mappings deep-merge: keys set
# here replace the base values and everything else is inherited, including
# model.params.fixed, so a new model must accept (or override) those keys.
includes:
  - ../config.yaml

seed: 7
model:
  name: random_forest
  params:
    fixed: {n_estimators: 100, min_samples_leaf: 5}
EOF

# ===========================================================================
# tests
# ===========================================================================
cat > tests/conftest.py <<'EOF'
from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from __PKG__.config import Config


@pytest.fixture
def frame() -> pd.DataFrame:
    rng = np.random.default_rng(0)
    n = 240
    return pd.DataFrame(
        {
            "timestamp": pd.date_range("2026-01-01", periods=n, freq="30min"),
            "entity_id": rng.integers(0, 12, n),
            "f1": rng.normal(size=n),
            "f2": rng.normal(size=n),
            "target": rng.normal(size=n),
        }
    )


@pytest.fixture
def cfg() -> Config:
    return Config(project="test", target="target")
EOF

cat > tests/evaluation/test_splitters.py <<'EOF'
"""Property tests for splitters.

A wrong split does not raise — it returns a better number. These are the
tests that catch the failure everything else hides. Hypothesis generates
panel-shaped frames (rows in random order, a varying number of rows per
timestamp) and every property must hold for all of them.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from __PKG__.evaluation.splitters import (
    GroupSplitter,
    PurgedKFoldSplitter,
    RandomSplitter,
    StratifiedSplitter,
    WalkForwardSplitter,
)

N_SPLITS = st.integers(min_value=2, max_value=6)


@st.composite
def panels(draw: st.DrawFn) -> pd.DataFrame:
    rows_per_period = draw(st.lists(st.integers(1, 4), min_size=3, max_size=40))
    n = sum(rows_per_period)
    periods = pd.date_range("2026-01-01", periods=len(rows_per_period), freq="h")
    frame = pd.DataFrame(
        {
            "timestamp": periods.repeat(rows_per_period),
            "entity_id": draw(st.lists(st.integers(0, 9), min_size=n, max_size=n)),
        }
    )
    return frame.iloc[draw(st.permutations(range(n)))].reset_index(drop=True)


@settings(max_examples=60, deadline=None)
@given(frame=panels(), k=N_SPLITS)
def test_train_and_test_never_overlap(frame, k):
    splitters = [
        RandomSplitter(k),
        GroupSplitter("entity_id", k),
        WalkForwardSplitter(k, time_col="timestamp"),
        PurgedKFoldSplitter(k, time_col="timestamp"),
    ]
    for splitter in splitters:
        for train, test in splitter.split(frame):
            assert len(test) > 0
            assert len(np.intersect1d(train, test)) == 0


@settings(max_examples=60, deadline=None)
@given(frame=panels(), k=N_SPLITS)
def test_walkforward_only_trains_on_the_strict_past(frame, k):
    times = frame["timestamp"].to_numpy()
    for train, test in WalkForwardSplitter(k, time_col="timestamp").split(frame):
        assert times[train].max() < times[test].min(), "a training row is not in the past"


@settings(max_examples=60, deadline=None)
@given(frame=panels(), k=N_SPLITS, embargo=st.integers(0, 8))
def test_purged_keeps_the_embargo_band_out_of_training(frame, k, embargo):
    times = frame["timestamp"].to_numpy()
    position = np.empty(len(frame), dtype=int)
    position[np.argsort(times, kind="stable")] = np.arange(len(frame))
    for train, test in PurgedKFoldSplitter(k, embargo=embargo, time_col="timestamp").split(frame):
        assert not np.isin(times[train], times[test]).any(), "train and test share a timestamp"
        if len(train):
            gap = np.abs(position[train][:, None] - position[test][None, :]).min()
            assert gap > embargo, f"training row within the embargo ({gap} <= {embargo})"


@settings(max_examples=60, deadline=None)
@given(frame=panels(), k=N_SPLITS)
def test_group_keeps_each_entity_on_one_side(frame, k):
    ids = frame["entity_id"].to_numpy()
    for train, test in GroupSplitter("entity_id", k).split(frame):
        assert not set(ids[train]) & set(ids[test]), "an entity appears on both sides"


@settings(max_examples=60, deadline=None)
@given(frame=panels(), k=N_SPLITS)
def test_random_test_folds_cover_every_row_once(frame, k):
    tests = np.concatenate([test for _, test in RandomSplitter(k).split(frame)])
    assert np.array_equal(np.sort(tests), np.arange(len(frame)))


@pytest.mark.parametrize(
    "splitter",
    [
        RandomSplitter(4),
        GroupSplitter("entity_id", 4),
        WalkForwardSplitter(4, time_col="timestamp"),
        PurgedKFoldSplitter(4, time_col="timestamp"),
    ],
)
def test_yields_the_requested_folds_on_regular_data(frame, splitter):
    assert len(list(splitter.split(frame))) == 4


def test_stratified_preserves_class_balance(frame):
    frame["label"] = (np.arange(len(frame)) % 4 == 0).astype(int)
    for train, test in StratifiedSplitter("label", 4).split(frame):
        assert len(np.intersect1d(train, test)) == 0
        assert frame["label"].iloc[test].mean() == pytest.approx(0.25, abs=0.02)
EOF

cat > tests/evaluation/test_validation.py <<'EOF'
from __future__ import annotations

import json

from __PKG__.config import Config
from __PKG__.evaluation.validation import evaluate_gate


def test_rejects_when_baseline_not_beaten(cfg, tmp_path):
    result = evaluate_gate(cfg, {"rmse": 1.0}, {"rmse": 0.5}, champion_path=tmp_path / "champ.json")
    assert not result.promoted


def test_bootstrap_promotes_without_a_champion(cfg, tmp_path):
    result = evaluate_gate(cfg, {"rmse": 0.4}, {"rmse": 0.9}, champion_path=tmp_path / "champ.json")
    assert result.promoted
    assert "bootstrap" in " ".join(result.reasons)


def test_promotion_records_the_champion_as_valid_json(cfg, tmp_path):
    champ = tmp_path / "champ.json"
    evaluate_gate(cfg, {"rmse": 0.4, "r2": float("nan")}, {"rmse": 0.9}, champion_path=champ)
    assert json.loads(champ.read_text()) == {"rmse": 0.4, "r2": None}


def test_rejects_when_champion_not_beaten(cfg, tmp_path):
    champ = tmp_path / "champ.json"
    evaluate_gate(cfg, {"rmse": 0.4}, {"rmse": 0.9}, champion_path=champ)
    result = evaluate_gate(cfg, {"rmse": 0.6}, {"rmse": 0.9}, champion_path=champ)
    assert not result.promoted


def test_fails_closed_without_the_primary_metric(cfg, tmp_path):
    result = evaluate_gate(cfg, {"mae": 0.1}, {"mae": 0.2}, champion_path=tmp_path / "c.json")
    assert not result.promoted


def test_fails_closed_on_a_nan_score(cfg, tmp_path):
    champ = tmp_path / "c.json"
    result = evaluate_gate(cfg, {"rmse": float("nan")}, {"rmse": 0.9}, champion_path=champ)
    assert not result.promoted
    assert not champ.exists()


def test_fails_closed_when_the_gate_direction_contradicts_the_metric(tmp_path):
    cfg = Config(project="test", gate={"primary_metric": "rmse", "greater_is_better": True})
    result = evaluate_gate(cfg, {"rmse": 0.9}, {"rmse": 0.4}, champion_path=tmp_path / "c.json")
    assert not result.promoted
EOF

cat > tests/data/test_contracts.py <<'EOF'
from __future__ import annotations

import pytest

from __PKG__.data import contracts


def test_passes_a_valid_frame(frame):
    assert contracts.check(frame, required=["target"], non_null=["target"]) is not None


def test_rejects_missing_columns(frame):
    with pytest.raises(contracts.ContractError, match="missing required"):
        contracts.check(frame, required=["nope"])


def test_rejects_nulls(frame):
    frame.loc[0, "target"] = None
    with pytest.raises(contracts.ContractError, match="nulls"):
        contracts.check(frame, non_null=["target"])


def test_rejects_an_empty_frame(frame):
    with pytest.raises(contracts.ContractError, match="rows"):
        contracts.check(frame.head(0))
EOF

cat > tests/model/test_baselines.py <<'EOF'
from __future__ import annotations

import numpy as np
import pytest

from __PKG__.model.baselines import _REGISTRY, build_baseline


def test_mean_baseline_predicts_the_mean(frame):
    base = build_baseline("mean").fit(frame, frame.target)
    assert np.allclose(base.predict(frame), frame.target.mean())


def test_seasonal_naive_repeats_the_season(frame):
    base = build_baseline("seasonal_naive", period=48).fit(frame, frame.target)
    preds = base.predict(frame.head(48))
    assert np.allclose(preds, frame.target.to_numpy()[-48:])


@pytest.mark.parametrize("kind", sorted(_REGISTRY))
def test_every_baseline_predicts_one_value_per_row(frame, kind):
    base = build_baseline(kind).fit(frame, frame.target)
    assert len(base.predict(frame.head(10))) == 10


def test_unknown_baseline_is_rejected():
    with pytest.raises(ValueError, match="unknown baseline"):
        build_baseline("nonsense")
EOF

cat > tests/model/test_metrics.py <<'EOF'
from __future__ import annotations

import numpy as np
import pytest

from __PKG__.model.metrics import REGISTRY, evaluate


def test_perfect_prediction_scores_perfectly():
    y = np.array([1.0, 2.0, 3.0])
    scores = evaluate(y, y, ["rmse", "mae", "r2", "ndcg"])
    assert scores["rmse"] == 0
    assert scores["mae"] == 0
    assert scores["r2"] == 1
    assert scores["ndcg"] == pytest.approx(1)


def test_ndcg_penalises_a_worse_ranking():
    y = np.array([3.0, 2.0, 1.0, 0.0])
    assert evaluate(y, -y, ["ndcg"])["ndcg"] < evaluate(y, y, ["ndcg"])["ndcg"]


def test_every_metric_declares_a_direction():
    assert all(isinstance(m.greater_is_better, bool) for m in REGISTRY.values())
EOF

cat > tests/test_config.py <<'EOF'
from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import ValidationError

from __PKG__.config import load_config
from __PKG__.model.baselines import build_baseline
from __PKG__.model.metrics import REGISTRY

CONF = Path(__file__).resolve().parents[1] / "conf"


def test_loads_and_resolves_includes():
    cfg = load_config(CONF / "config.yaml")
    assert cfg.project == "__PROJECT__"
    assert cfg.splitter.kind
    assert cfg.gate.primary_metric


def test_gate_and_baseline_name_things_that_exist():
    cfg = load_config(CONF / "config.yaml")
    assert cfg.gate.primary_metric in REGISTRY, "the gate can never pass on an unknown metric"
    assert REGISTRY[cfg.gate.primary_metric].greater_is_better == cfg.gate.greater_is_better
    build_baseline(cfg.baseline.kind)


def test_experiments_keep_the_base_split_baseline_and_gate():
    base = load_config(CONF / "config.yaml")
    exp = load_config(CONF / "experiment" / "example.yaml")
    assert (exp.splitter, exp.baseline, exp.gate) == (base.splitter, base.baseline, base.gate)
    assert exp.model.name != base.model.name


def test_includes_apply_in_order_and_the_including_file_wins(tmp_path):
    (tmp_path / "a.yaml").write_text("seed: 1\nsplitter: {kind: group, n_splits: 3}\n")
    (tmp_path / "b.yaml").write_text("seed: 2\n")
    (tmp_path / "main.yaml").write_text(
        "project: p\nincludes: [a.yaml, b.yaml]\nsplitter: {n_splits: 7}\n"
    )
    cfg = load_config(tmp_path / "main.yaml")
    assert cfg.seed == 2
    assert (cfg.splitter.kind, cfg.splitter.n_splits) == ("group", 7)


def test_include_cycles_are_rejected(tmp_path):
    (tmp_path / "a.yaml").write_text("includes: [b.yaml]\n")
    (tmp_path / "b.yaml").write_text("includes: [a.yaml]\n")
    with pytest.raises(ValueError, match="cycle"):
        load_config(tmp_path / "a.yaml")


def test_unknown_keys_are_rejected(tmp_path):
    (tmp_path / "typo.yaml").write_text("project: p\nspliter: {kind: group}\n")
    with pytest.raises(ValidationError):
        load_config(tmp_path / "typo.yaml")


def test_flat_is_trackable():
    flat = load_config(CONF / "config.yaml").flat()
    assert "seed" in flat
    assert all(not isinstance(v, dict) for v in flat.values())
EOF

cat > tests/test_cli.py <<'EOF'
"""End to end: the CLI runs the whole spine on a small synthetic dataset."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import yaml
from typer.testing import CliRunner

from __PKG__.cli import app
from __PKG__.config import load_config

CONF = Path(__file__).resolve().parents[1] / "conf"


def test_backtest_writes_a_report_that_applies_the_gate(tmp_path, monkeypatch):
    rng = np.random.default_rng(0)
    n = 400
    raw = pd.DataFrame(
        {
            "timestamp": pd.date_range("2026-01-01", periods=n, freq="30min"),
            "entity_id": rng.integers(0, 20, n),
            "f1": rng.normal(size=n),
            "f2": rng.normal(size=n),
        }
    )
    # A binary target with some signal suits every task preset alike:
    # regression, stratified classification and ranking.
    raw["target"] = (raw["f1"] + 0.5 * rng.normal(size=n) > 0).astype(int)
    (tmp_path / "data" / "raw").mkdir(parents=True)
    raw.to_csv(tmp_path / "data" / "raw" / "raw.csv", index=False)

    # The project's own config, with a small sklearn model so no extras are needed.
    config = tmp_path / "config.yaml"
    overrides = {
        "includes": [str(CONF / "config.yaml")],
        "model": {"name": "random_forest", "params": {"fixed": {"n_estimators": 20}}},
    }
    config.write_text(yaml.safe_dump(overrides))
    monkeypatch.chdir(tmp_path)

    result = CliRunner().invoke(app, ["backtest", "--config", str(config)])

    assert result.exit_code == 0, f"{result.output}\n{result.exception!r}"
    report = (tmp_path / "reports" / "backtest.md").read_text()
    metric = load_config(config).gate.primary_metric
    assert "## Promotion gate" in report
    assert f"({metric}: " in report, "the gate never compared the primary metric"
    assert "**data** `" in report, "the report does not record the data hash"
EOF

cat > tests/test_imports.py <<'EOF'
"""Every module must import cleanly on its own.

A circular import only fails for some import orders, so the rest of the suite
can pass while the first cell of a notebook crashes. Each module is imported
into a fresh copy of the package, in a separate interpreter.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import __PKG__

CHECK = """
import importlib, sys
for name in sys.argv[1:]:
    for loaded in [m for m in sys.modules if m.split(".")[0] == "__PKG__"]:
        del sys.modules[loaded]
    importlib.import_module(name)
"""


def test_every_module_imports_first():
    root = Path(__PKG__.__file__).parent
    modules = sorted(
        ".".join(("__PKG__", *path.relative_to(root).with_suffix("").parts)).removesuffix(
            ".__init__"
        )
        for path in root.rglob("*.py")
    )
    subprocess.run([sys.executable, "-c", CHECK, *modules], check=True)
EOF

# ===========================================================================
# project files
# ===========================================================================
cat > pyproject.toml <<EOF
[project]
name = "$PROJECT"
version = "0.1.0"
description = "TODO: one line on what this predicts and why it matters"
readme = "README.md"
requires-python = ">=3.11"
license = "MIT"
license-files = ["LICENSE"]
authors = [$AUTHORS_TOML]
dependencies = [
    "pandas>=2.0",
    "numpy>=1.24",
    "pyarrow>=14.0",
    "pydantic>=2.0",
    "pyyaml>=6.0",
    "typer>=0.12",
    "scikit-learn>=1.3",
    "matplotlib>=3.7",
]

[project.optional-dependencies]
model      = ["lightgbm>=4.0", "optuna>=3.0"]
track      = ["mlflow>=2.9"]
explain    = ["shap>=0.44"]
onnx       = ["skl2onnx>=1.16", "onnxruntime>=1.16"]
timeseries = ["statsmodels>=0.14"]
dev = [
    "pytest>=8.0",
    "pytest-cov>=5.0",
    "hypothesis>=6.100",
    # One minor series, matching .pre-commit-config.yaml, so lint and format
    # results only change when you choose to bump it.
    "ruff>=0.16.7,<0.17",
    "mypy>=1.8",
    "pre-commit>=3.6",
]

[project.scripts]
$PKG = "$PKG.cli:app"

[build-system]
requires = ["hatchling>=1.27"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/$PKG"]

[tool.ruff]
# The target Python version is read from requires-python.
line-length = 100
src = ["src", "tests"]

[tool.ruff.lint]
select = ["E", "F", "W", "I", "N", "UP", "B", "C4", "SIM"]
# Deliberately short. A long ignore list on a public repo reads as
# "cannot write lint-clean code". Only X/y conventions earn an exception.
ignore = ["N803", "N806", "E501"]

[tool.ruff.lint.per-file-ignores]
"tests/*" = ["N802"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-q --cov=src --cov-report=term-missing"

[tool.mypy]
# No python_version: checking against the running interpreter keeps mypy in
# step with the installed numpy/pandas stubs.
ignore_missing_imports = true
exclude = ["tests/", "notebooks/"]
EOF

cat > Makefile <<'EOF'
.DEFAULT_GOAL := help
PY := python -m __PKG__.cli

help:  ## show targets
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

install:  ## install with dev, model and tracking extras (run inside a virtualenv)
	python -m pip install -e ".[dev,model,track]"
	@if [ -d .git ]; then pre-commit install; else echo "not a git repo: skipped pre-commit install"; fi

data:  ## build the dataset
	$(PY) data

backtest:  ## score, gate and write reports/backtest.md
	$(PY) backtest

show:  ## print the resolved config
	$(PY) show

test:  ## run the test suite
	pytest

lint:  ## lint, format check and type check
	ruff check .
	ruff format --check .
	mypy src

fmt:  ## autoformat
	ruff check --fix .
	ruff format .

.PHONY: help install data backtest show test lint fmt
EOF

cat > .github/workflows/ci.yml <<'EOF'
name: ci

on:
  push: {branches: [main]}
  pull_request:

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      # Actions are pinned to commit SHAs because tags can be moved; Dependabot
      # (.github/dependabot.yml) keeps the pins current.
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: {persist-credentials: false}
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with: {python-version: "3.12", cache: pip, cache-dependency-path: pyproject.toml}
      - run: python -m pip install -e ".[dev,model,track]"
      - run: ruff check .
      - run: ruff format --check .
      - run: mypy src
      - run: pytest
EOF

cat > .github/workflows/refresh.yml <<'EOF'
# Scheduled re-run: rebuild the dataset, re-backtest, and open a PR when the
# metrics move. The public analogue of pre-merge model validation.
# Enable by uncommenting the schedule once the data source refreshes. data/raw/
# is gitignored, so this needs a collector that fetches the data, and the repo
# setting "Allow GitHub Actions to create and approve pull requests".
name: refresh

on:
  workflow_dispatch:
  # schedule:
  #   - cron: "0 6 * * 1"

permissions: {}

jobs:
  backtest:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: {persist-credentials: false}
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with: {python-version: "3.12"}
      - run: python -m pip install -e ".[model,track]"
      - run: python -m __PKG__.cli backtest
      - uses: peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1 # v8.1.1
        with:
          branch: refresh/backtest
          title: "chore: refresh backtest metrics"
          commit-message: "chore: refresh backtest metrics"
          body-path: reports/backtest.md
          add-paths: reports/
EOF

cat > .github/dependabot.yml <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: {interval: monthly}
    cooldown: {default-days: 7}
    groups: {actions: {patterns: ["*"]}}
  - package-ecosystem: pip
    directory: /
    schedule: {interval: monthly}
    cooldown: {default-days: 7}
    groups: {python: {patterns: ["*"]}}
EOF

cat > .pre-commit-config.yaml <<'EOF'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.16.7  # keep in step with the ruff pin in pyproject.toml
    hooks:
      - id: ruff-check
        args: [--fix]
      - id: ruff-format
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-yaml
      - id: check-added-large-files
      - id: detect-private-key
EOF

cat > .gitignore <<'EOF'
__pycache__/
*.py[cod]
.venv/
venv/
.env
.env.*
*.pem
*.key
build/
dist/
*.egg-info/
.pytest_cache/
.ruff_cache/
.mypy_cache/
.hypothesis/
.coverage
coverage.xml
.ipynb_checkpoints/
data/raw/*
data/processed/*
!data/raw/.gitkeep
!data/processed/.gitkeep
mlruns/
mlflow.db
models/*.onnx
models/*.pkl
.DS_Store
EOF

cat > README.md <<'EOF'
# __PROJECT__

[![ci](https://github.com/__USER__/__PROJECT__/actions/workflows/ci.yml/badge.svg)](https://github.com/__USER__/__PROJECT__/actions/workflows/ci.yml)

> TODO: one sentence on what this predicts and why anyone should care.

## Results

Latest backtest: [`reports/backtest.md`](reports/backtest.md)

| model | rmse | mae | r2 |
|---|---|---|---|
| candidate | – | – | – |
| baseline | – | – | – |

Every number above is produced by `make backtest` from the config in `conf/`,
against the baseline named there. A model that does not beat its baseline is
rejected by the promotion gate and never recorded as champion.

## Run it

```bash
python3 -m venv .venv && source .venv/bin/activate
make install
make data        # needs data/raw/raw.csv
make backtest
```

## How it is put together

Three pipelines, four plug points.

```
data/        collect -> process -> validate (contracts) -> store
model/       baseline + candidate, tracked to a local MLflow SQLite store (mlflow.db)
evaluation/  split -> score -> promotion gate -> report
```

| Plug point | Where | Why it is swappable |
|---|---|---|
| Splitter | `evaluation/splitters.py` | The correct split differs per project; the wrong one silently inflates results |
| Baseline | `model/baselines.py` | A metric without a baseline is unreadable |
| Metrics | `model/metrics.py` | Each metric declares its own direction |
| Model | `model/training.py` | Anything with `fit`/`predict` |

Configuration is split: **schema** lives in `src/__PKG__/config.py`, **values**
live in `conf/*.yaml`. If a setting can change between runs without a code
change, it belongs in yaml.

## Honest limits

See [`MODEL_CARD.md`](MODEL_CARD.md) for intended use, and what this is *not*
valid for.

## Licence

MIT. Data sources and their terms: [`DATA_SOURCES.md`](DATA_SOURCES.md).
EOF

cat > MODEL_CARD.md <<'EOF'
# Model card — __PROJECT__

## Intended use
TODO: who would use this output, for what decision.

## Out of scope
TODO: the decisions this must not be used for.

## Data
- Source: TODO
- Period: TODO
- Licence: see `DATA_SOURCES.md`

## Evaluation
- Splitter: see `conf/splitter/`
- Baseline: see `conf/evaluation/gate.yaml`
- Primary metric: see `conf/evaluation/gate.yaml`
- Results: `reports/backtest.md`

## Known limitations
TODO. Be specific. State what would have to be true for this to be wrong,
and whether you can currently detect that.

## Ethical and practical considerations
TODO.
EOF

cat > DATA_SOURCES.md <<'EOF'
# Data sources

| Source | URL | Licence / terms | Refresh | Notes |
|---|---|---|---|---|
| TODO | | | | |

Raw pulls are cached under `data/raw/` (gitignored). Each run records a hash of
its raw input so any published number can be traced to the exact data behind it.
EOF

cat > docs/decisions/0001-record-architecture-decisions.md <<'EOF'
# 1. Record architecture decisions

Date: TODO
Status: accepted

## Context
Decisions made early in a project become invisible assumptions later. Without a
record, the reasoning is lost and the decision gets silently reversed.

## Decision
Record any decision that would be expensive to reverse, or that a reader would
otherwise question, as a numbered file in `docs/decisions/`.

## Consequences
One short file per decision. The cost is a few minutes; the benefit is that
future-you and any reviewer can see why, not just what.
EOF

cat > docs/decisions/0002-baseline-and-splitter-are-mandatory.md <<'EOF'
# 2. Every project declares a baseline and a splitter

Date: TODO
Status: accepted

## Context
A metric reported without a baseline cannot be interpreted. A split chosen
implicitly is the most common source of results that are wrong but plausible —
leakage does not raise an error, it improves the number.

## Decision
`conf/` must name a baseline and a splitter. The promotion gate refuses to
promote a model that does not beat its baseline, and fails closed when the
comparison cannot be made.

## Consequences
Slightly more setup per project. In exchange, every number in `reports/` is
interpretable and every split is property-tested.
EOF

cat > notebooks/01-exploration.ipynb <<'EOF'
{
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "# Exploration\n",
    "\n",
    "Notebooks are for **looking**. Anything importable belongs in `src/` with a test.\n",
    "This notebook calls the package; it never defines pipeline logic."
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "from __PKG__.config import load_config\n",
    "from __PKG__.data.data_pipeline import DataPipeline\n",
    "\n",
    "cfg = load_config(\"../conf/config.yaml\")\n",
    "df = DataPipeline(cfg).run()\n",
    "df.head()"
   ]
  }
 ],
 "metadata": {"language_info": {"name": "python"}},
 "nbformat": 4,
 "nbformat_minor": 5
}
EOF

mkdir -p data/raw data/processed
cat > data/raw/.gitkeep <<'EOF'
EOF
cat > data/processed/.gitkeep <<'EOF'
EOF
cat > reports/.gitkeep <<'EOF'
EOF

cat > LICENSE <<EOF
MIT License

Copyright (c) $(date +%Y) $AUTHOR_NAME

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

# ===========================================================================
# placeholder substitution + init
# ===========================================================================
# Write to a temp file and move it back rather than `sed -i`, whose syntax
# differs between macOS (BSD) and Linux (GNU) sed.
while IFS= read -r -d '' file; do
  sed -e "s/__PKG__/$PKG/g" -e "s/__PROJECT__/$PROJECT/g" -e "s/__USER__/$GH_USER/g" \
    "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
done < <(find . -type f \( -name '*.py' -o -name '*.md' -o -name '*.yaml' -o -name '*.yml' \
  -o -name '*.ipynb' -o -name 'Makefile' \) -print0)

touch "src/$PKG/data/processors/__init__.py" "src/$PKG/data/storage/__init__.py" 2>/dev/null || true
for d in tests tests/data tests/model tests/evaluation; do touch "$d/__init__.py"; done

if [[ $DO_GIT -eq 1 ]]; then
  git init -q
  git symbolic-ref HEAD refs/heads/main  # CI runs on main, whatever init.defaultBranch says
  git add -A
  msg="feat: scaffold $PROJECT data science project"
  if git config user.name >/dev/null && git config user.email >/dev/null; then
    git commit -qm "$msg" || warn "initial commit skipped"
  else
    git -c user.name="$AUTHOR_NAME" -c user.email="${AUTHOR_EMAIL:-noreply@example.com}" \
      commit -qm "$msg" || warn "initial commit skipped"
  fi
  info "git repo initialised on main"
fi

head_ "Done"
info "created ./$PROJECT ($(find . -path ./.git -prune -o -type f -print | wc -l | tr -d ' ') files, task=$TASK)"
cat <<NEXT

Next:
  cd $PROJECT
  python3 -m venv .venv && source .venv/bin/activate
  make install
  make test                 # splitter, gate, config and end-to-end tests
  make show                 # resolved config

Then:
  1. Drop data at data/raw/raw.csv, set 'target' in conf/config.yaml
  2. make backtest          # writes reports/backtest.md, runs the gate
  3. Fill in README results, MODEL_CARD.md and DATA_SOURCES.md
  4. gh repo create $PROJECT --private --source . --push   (or --public)

NEXT
