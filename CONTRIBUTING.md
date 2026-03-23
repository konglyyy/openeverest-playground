# Contributing

Contributor validation commands live under the `ci` namespace so the default
`task --list` output stays focused on playground lifecycle commands.

## Validation Commands

List the contributor commands:

```bash
task ci
```

Run individual validation tasks:

```bash
task ci:all
task ci:bootstrap
task ci:lint
task ci:test
task ci:smoke:minimal
```

The smoke test expects Docker to already be installed and running.

## Shell Script Conventions

The static lint pass also checks the shell and Bats documentation style:

- Every `*.sh`, `*.bash`, and `*.bats` file should start with a short purpose
  comment block near the shebang.
- Every shell function should have a brief comment immediately above it that
  explains what it does.

Keeping those comments concise and factual makes the repo easier to scan and
keeps the automation output aligned with the code.

## Playground Config

`config/playground.env.example` is the committed default playground config.
Keep local playground edits in `config/playground.env`, and update the example
file only when the intended repo defaults change.

The repo root `.env` is intentionally ignored by the playground scripts.

## GitHub Actions Parity

The `Validation` workflow runs the same contributor commands:

- `static` runs `task ci:lint`
- `shell-tests` runs `task ci:test`
- `smoke-minimal` runs `task ci:smoke:minimal`
