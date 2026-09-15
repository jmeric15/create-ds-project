# Security policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/jmeric15/create-ds-project/security/advisories/new).

## Scope

- **The script.** For example, input that makes it write outside the new
  project directory, or run a command it shouldn't.
- **What it generates.** For example, a GitHub Actions workflow with more
  permissions than it needs, or ignore rules that let data or secrets be
  committed.

Vulnerabilities in the libraries generated projects depend on (pandas, MLflow
and so on) belong with those projects. Generated projects have Dependabot
configured to pick up the fixes.

Only the latest commit on `main` is supported.
