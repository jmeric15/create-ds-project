# create-ds-project

[![ci](https://github.com/jmeric15/create-ds-project/actions/workflows/ci.yml/badge.svg)](https://github.com/jmeric15/create-ds-project/actions/workflows/ci.yml)

A single bash script that scaffolds a new data science project: an installable,
tested Python package with a data → model → evaluation pipeline, a baseline
every model has to beat, leakage-safe splitters, a promotion gate, and CI that
passes from the first commit.

## Quick start

Install once (clone and put the script on your `PATH`):

```bash
git clone https://github.com/jmeric15/create-ds-project.git ~/create-ds-project
mkdir -p ~/.local/bin
ln -s ~/create-ds-project/create-ds-project.sh ~/.local/bin/create-ds-project
```

`~/.local/bin` needs to be on your `PATH`. Run `git -C ~/create-ds-project pull` to update.

Then, for each new project:

```bash
create-ds-project churn-model --task tabular
cd churn-model
python3 -m venv .venv && source .venv/bin/activate
make install
make test
```

To publish it, `gh repo create churn-model --private --source . --push`
(or `--public`).

## Usage

```
create-ds-project <project-name> [--task tabular|timeseries|ranking|text]
                                 [--package <python_pkg_name>]
                                 [--author "Name <email>"]
                                 [--github-user <username>]
                                 [--no-git]
```

| Option | Default | What it sets |
|---|---|---|
| `--task` | `tabular` | The splitter, baseline and gate metric (see below) |
| `--package` | project name, lowercased, `-` → `_` | The Python import name |
| `--author` | `git config user.name` | `pyproject.toml` and `LICENSE`. An email is only written if you pass one |
| `--github-user` | `git config github.user` | The CI badge link in the README |
| `--no-git` | | Skips `git init` and the initial commit |

Run `git config --global github.user <your-username>` once and every new
project's README badge links to the right place.

### Task presets

| `--task` | Splitter | Baseline | Gate metric |
|---|---|---|---|
| `tabular` | random k-fold | training mean | RMSE, lower is better |
| `timeseries` | walk-forward on `timestamp` | seasonal naive (period 48) | RMSE, lower is better |
| `ranking` | group k-fold on `entity_id` | random ranking | NDCG, higher is better |
| `text` | stratified k-fold | majority class | F1, higher is better |

A preset only writes these values into `conf/`. The candidate model defaults to
a LightGBM regressor for every task. Replace it in
`src/<package>/model/training.py` with whatever your problem needs.

## What you get

```
churn-model/
├── src/churn_model/
│   ├── config.py          config schema (pydantic); the values live in conf/
│   ├── data/              collect -> process -> validate (contracts) -> store
│   ├── model/             baselines, metrics, training, MLflow tracking
│   ├── evaluation/        splitters, promotion gate, drift check, report
│   └── cli.py             data | backtest | show
├── conf/                  yaml: data, model, splitter, gate, experiments
├── tests/                 property tests for splitters, gate, config, end-to-end CLI
├── notebooks/, reports/, docs/decisions/
├── .github/               CI, a manual "refresh" workflow, Dependabot
├── README.md, MODEL_CARD.md, DATA_SOURCES.md, LICENSE
└── Makefile, pyproject.toml, .pre-commit-config.yaml
```

Put your data at `data/raw/raw.csv`, set `target` in `conf/config.yaml`, and
run `make backtest`. It scores the model and the baseline on every fold, then
runs the promotion gate. A model is promoted only if it beats both the baseline
and the current champion, and nothing is promoted when the scores can't be
compared. The results go to `reports/backtest.md`.

## Security

The script:

- makes no network calls and installs nothing
- validates every argument before writing anything, and writes only inside the new project directory
- refuses to run if that directory already exists

Every generated project starts with:

- GitHub Actions workflows with read-only default permissions, and actions pinned to commit SHAs that Dependabot keeps current
- raw and processed data, `.env` files, private keys and the MLflow database in `.gitignore`
- a pre-commit hook that stops private keys being committed

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Development

The tests are in Python, and they check the script and the projects it generates.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest                  # fast (seconds): arguments, generated files, shellcheck, zizmor
pytest -m integration   # slow (minutes): installs a project per task, runs its CI steps and a backtest
```

CI runs the fast tests on Ubuntu and on macOS's stock bash 3.2, then the
integration tests. It also runs weekly, so a dependency release that breaks new
projects shows up here first.

Dependabot only updates this repo's own workflow. The workflows that the script
writes into new projects pin the same actions, so when Dependabot bumps
`actions/checkout` or `actions/setup-python` here, update the pins in
`create-ds-project.sh` too.

## License

[MIT](LICENSE)
