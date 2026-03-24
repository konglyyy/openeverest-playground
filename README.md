<p align="center">
  <img src="https://raw.githubusercontent.com/openeverest/openeverest/main/logo.png" alt="OpenEverest logo" width="320">
  <h1 align="center">OpenEverest Playground</h1>
</p>

<p align="center">
  <a href="https://github.com/konglyyy/openeverest-playground/actions/workflows/validation.yml"> <img src="https://github.com/konglyyy/openeverest-playground/actions/workflows/validation.yml/badge.svg" alt="Validation workflow status" /> </a>
</p>

<p align="center">
  A community-maintained local playground for trying OpenEverest on <code>k3d</code>.
</p>

> **Community-maintained, not official**
>
> This repository is not an official OpenEverest repository. It is a community-maintained playground built to make OpenEverest easier to evaluate, demo, and discuss locally. For the upstream project, releases, and official documentation, see [OpenEverest](https://github.com/openeverest/openeverest) and [openeverest.io](https://openeverest.io/).

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Technologies](#technologies)
- [Support Matrix](#support-matrix)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [Configuration](#configuration)
- [Commands](#commands)
- [Playground Layout](#playground-layout)
- [Troubleshooting](#troubleshooting)
- [Script Layout](#script-layout)
- [Contributing](#contributing)
- [References](#references)

* * *

### Introduction

OpenEverest Playground gives you an opinionated local cluster for exploring core OpenEverest DBaaS workflows without manually wiring together Kubernetes, ingress, operators, namespaces, or optional backup storage.

The playground is built around a simple lifecycle:

- `task init` is the required first-run entrypoint
- `task down` stops the cluster without deleting it
- `task up` resumes a previously initialized cluster
- `task reset` deletes the cluster and local state while preserving the repo-local Docker Hub cache
- `task reset:full` deletes the cluster, local state, and the repo-local Docker Hub cache

`task init` prompts only for optional features, then evaluates the live Docker CPU and memory budget and computes the best cluster plan it can fit. The planner always sizes the control plane first, then fits one to three database worker nodes using internal `small`, `medium`, and `large` worker classes. Those classes are not user-facing modes.

After a successful `task init`, the playground gives you:

- A local `k3d` cluster with one tainted control-plane node and one to three database worker nodes
- OpenEverest installed from the configured Helm repo, using pinned chart versions only when you opt in
- All three database operators available in one shared namespace, `everest-databases`
- An always-on Docker Hub pull-through cache persisted under `.cache/dockerhub-registry`
- Direct browser access to the OpenEverest UI on `localhost:8080`
- An optional shared SeaweedFS S3-compatible backup endpoint for backup feature testing
- Fast `task down` and `task up` cycles after the initial install

The project intentionally optimizes for fast local evaluation and repeatable demos rather than full production parity.

* * *

### Features

- OpenEverest installed from `openeverest/openeverest`, with optional version pinning for CI or debugging
- All three database operators always available: PostgreSQL, MySQL/PXC, and MongoDB
- Single shared database namespace, `everest-databases`, for a simpler mental model
- Always-on Docker Hub pull-through cache for `docker.io` images, stored under `.cache/dockerhub-registry`
- Optional shared SeaweedFS S3-compatible backup endpoint for backup testing
- Resume-only `task up` flow so start/stop is fast and predictable after initialization
- Direct local UI access on [http://localhost:8080](http://localhost:8080) through the built-in k3s Traefik ingress
- Concise terminal UX with an init wizard, structured `[INFO]` logs, resolved layout summaries, and loading indicators for long-running steps
- Contributor validation workflows for static checks, shell tests, and a minimal-layout smoke test

* * *

### Technologies

The playground is built on a small set of familiar tools and platform components:

- `k3d` for the local Kubernetes cluster lifecycle
- `helm` for installing OpenEverest and the namespace-scoped DB operator stack
- `kubectl` for cluster interactions and readiness checks
- `task` for the main user-facing command surface
- `jq` for lightweight JSON-driven shell automation
- built-in k3s Traefik ingress for direct local UI access
- optional SeaweedFS for a shared S3-compatible backup endpoint

* * *

### Support Matrix

| Platform | Status | Notes |
| --- | --- | --- |
| Ubuntu Linux | Supported | Validated in CI. |
| macOS | Best effort | Intended to work locally, but not CI-validated. |
| Windows with WSL2 Ubuntu | Recommended Windows path | Run the playground inside the Linux distro with Docker Desktop WSL integration enabled. Prefer the Linux filesystem over `/mnt/c/...`. |
| Windows native (`PowerShell` / `cmd.exe`) | Not supported | The playground is Bash-centric. |

If you are using Windows, WSL2 Ubuntu is the path this playground is designed to fit most naturally.

* * *

### Prerequisites

The playground expects these tools to be installed locally:

- `docker`
- `k3d`
- `kubectl`
- `helm`
- `jq`
- `task`

You can validate the environment with:

```bash
task doctor
```

`task doctor` checks the local toolchain and Docker/k3d access quickly. `task init` also performs the Helm repo and chart reachability checks before it installs anything.

Sizing notes:

- The planner uses the Docker budget that `k3d` sees, not raw host RAM. On Docker Desktop, that means the Docker VM memory and CPU limits matter more than the machine's physical specs.
- The control-plane node is tainted `NoSchedule` under both the `node-role.kubernetes.io/control-plane` key and the legacy `node-role.kubernetes.io/master` key. OpenEverest core services, all database operators, and optional add-ons such as SeaweedFS are placed there.
- Database workloads run on the worker nodes. The planner tries to fit the best layout in this order: `LLL`, `LLM`, `LMM`, `MMM`, `MMS`, `MSS`, `SSS`, then two-worker layouts, then one-worker layouts.
- If the Docker budget cannot fit the control plane plus one `small` worker, `task init` exits cleanly with an error.

* * *

### Quickstart

1. Validate the local prerequisites:

```bash
task doctor
```

2. Initialize the playground (may take up to 5-10 minutes on first run):

```bash
task init
```

3. During `task init`, choose whether to enable backup testing.

4. Reprint the access details at any time:

```bash
task status
```

5. Sign in with:

- Username: `admin`
- Password: `playground-admin`

6. Stop and resume it when needed:

```bash
task down
task up
```

The first `task init` can take up to 5-10 minutes on a fresh machine because it needs to create the cluster, pull images, install OpenEverest, and start all three database operators. Enabling backup adds extra work on top of that.

The Docker Hub cache is always enabled. The first pull for a given `docker.io` image still goes upstream, but later resets and reinitializations can reuse the cached layers from `.cache/dockerhub-registry`. The backing registry keeps its default seven-day proxy retention window. `task reset` preserves that cache; `task reset:full` removes it.

* * *

### Configuration

`task init` writes a local `config/playground.env` file for you. If you prefer
to edit settings directly, start from the committed defaults in
`config/playground.env.example`.

```bash
cp config/playground.env.example config/playground.env
```

Supported settings:

```bash
ENABLE_BACKUP=false
EVEREST_UI_PORT=8080
EVEREST_HELM_CHART_VERSION=
EVEREST_DB_NAMESPACE_CHART_VERSION=
```

Configuration behavior:

- `config/playground.env.example` is the committed default template
- edit `config/playground.env` directly or let `task init` update it interactively
- `task init` is where config changes are applied; if the playground is already initialized with the same effective config, it exits early and points you to `task up`, `task status`, or `task reset`
- `task up` never reconciles config drift; if `config/playground.env` changed, rerun `task init`
- `ENABLE_BACKUP` is the supported feature toggle
- `EVEREST_UI_PORT` lets you avoid a local port conflict on `localhost`
- `EVEREST_HELM_CHART_VERSION` and `EVEREST_DB_NAMESPACE_CHART_VERSION` are optional; leave them empty to use the chart defaults from the configured Helm repo, or set them to pin validation or debugging runs

Non-configurable behavior:

- the Docker Hub cache is an internal always-on implementation detail, not a public config setting
- the resolved worker layout, control-plane reservation, port mapping, and feature set are treated as reset-required when they drift
- namespace names, chart repository details, and backup internals are fixed implementation defaults rather than public playground settings

* * *

### Commands

| Command | Description |
| --- | --- |
| `task init` | Interactively configure the playground and provision it |
| `task up` | Resume a previously initialized playground without reinstalling it |
| `task down` | Stop the `k3d` cluster without deleting it |
| `task reset` | Delete the cluster and local state while preserving `.cache/dockerhub-registry` |
| `task reset:full` | Delete the cluster, local state, and `.cache/dockerhub-registry` |
| `task status` | Print cluster, namespace, database engine, backup, and access status |
| `task logs` | Tail OpenEverest logs |
| `task doctor` | Validate local dependencies, Docker, k3d, and Helm availability |
| `task help` | Show the available playground commands |

* * *

### Playground Layout

The playground is intentionally small, but it still exposes a few real-world DBaaS concepts.

#### Control Plane

- one tainted server node
- runs OpenEverest core services
- runs all three database operators
- runs optional SeaweedFS components when enabled

#### Database Workers

- one to three worker nodes
- each worker is assigned an internal `small`, `medium`, or `large` class
- workers are engine-agnostic and may host PostgreSQL, MySQL/PXC, or MongoDB workloads
- the resolved layout is shown after `task init` and in `task status`, for example `3 workers: large, large, medium`

#### Shared Database Namespace

- all database engines are exposed through one namespace: `everest-databases`
- namespace quotas are sized from the total resolved worker pool
- this keeps the user-facing database model simple

#### Backup Layout

When backup is enabled:

- `playground-system` hosts a single SeaweedFS instance
- `everest-databases` reuses one S3-compatible endpoint and one credential pair
- `everest-databases` gets one `BackupStorage` object backed by a bucket under the `everest-backups-*` prefix

#### Access Model

- the UI is exposed through the built-in k3s Traefik ingress
- `k3d` maps host port `8080` to that ingress
- no background tunnel or `kubectl port-forward` process is required

* * *

### Troubleshooting

- If `task up` says the playground is not initialized, run `task init` first.
- If `task up` says the config changed, rerun `task init` to apply the current `config/playground.env`.
- If `task init` says the current plan requires a reset, run `task reset` and then `task init`.
- If `task init` says the Docker budget cannot fit the resolved plan, increase the Docker Desktop memory or CPU limit and rerun it.
- If setup feels slow, the biggest unavoidable costs are first-time image pulls and starting the control-plane services and operators. Backup-enabled runs also need to start their optional add-ons.
- The Docker Hub cache only helps `docker.io` images. Images from other registries, such as `public.ecr.aws`, are unaffected.
- Tagged pulls can still revalidate against Docker Hub, so pinned versions or digests are more cache-friendly than mutable tags like `:latest`.
- Use `task reset:full` when you want a truly cold rerun and need to purge `.cache/dockerhub-registry` as well as `.state`.

* * *

### Script Layout

The shell scripts are grouped by responsibility:

- `scripts/access/` for final access output helpers
- `scripts/config/` for interactive setup and config policy checks
- `scripts/cluster/` for `k3d` lifecycle actions
- `scripts/ci/` for GitHub Actions bootstrap, validation helpers, smoke checks, and diagnostics
- `scripts/common/` for the shared helper loader plus focused helper modules under `scripts/common/modules/`
- `scripts/doctor/` for preflight validation
- `scripts/ops/` for logs, status, and resume flow
- `scripts/platform/` for Everest installation, DB namespace setup, backup setup, control-plane placement and tainting, ingress checks, and readiness waits

Shell and Bats files also follow one repo-wide convention: each file starts with
a short purpose header, and each function is preceded by a brief comment that
describes what it does.

The playground config follows the same principle: use
`config/playground.env.example` as the committed template, keep local edits in
`config/playground.env`, and do not use a repo root `.env`.

* * *

### Contributing

This playground is community-maintained, and contributions are welcome. Contributor validation commands live under the `ci` namespace so the default command list stays focused on playground lifecycle commands.

Run the contributor command list with:

```bash
task ci
```

For the maintainer workflow summary, open [`CONTRIBUTING.md`](./CONTRIBUTING.md).

* * *

### References

- [Official OpenEverest repository](https://github.com/openeverest/openeverest)
- [OpenEverest website and documentation](https://openeverest.io/)
