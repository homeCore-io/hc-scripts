# hc-scripts

Shared CI/CD workflows and workspace tooling for homeCore.

The reusable workflows here are referenced as `@main` by every component repo,
so **a change to them is live for the whole org the moment it merges to `main`.**
Work on `develop`, then PR to `main`.

| Workflow | Used by |
|---|---|
| `.github/workflows/rust-ci.yml` | every Rust repo's `ci.yml` — fmt, clippy, test |
| `.github/workflows/rust-release.yml` | every Rust repo's `release.yml` — build, Docker publish, appliance dispatch |
| `.github/workflows/flutter-ci.yml` | `hc-web`'s `ci.yml` — analyze, format, test, build web |
| `.github/workflows/cleanup-containers.yml` | GHCR retention |

`flutter-ci.yml` is the Dart counterpart of `rust-ci.yml` and follows the same
rules below — the pinned toolchain, the `permissions` block, the develop-red
tracking issue. `hc-web` publishes its own image from its own `release.yml`
(its `Dockerfile` lives in the repo, not in `homeCore-io/docker`), so there is no
`flutter-release.yml`.

---

## Cutting a release: tag order matters

**Tag `homeCore-io/docker` and `homeCore-io/hc-web-leptos` *before* tagging
core or any plugin.**

Get this wrong and the release **fails** — deliberately. The pre-flight steps in
`rust-release.yml` will tell you exactly which repo is missing which tag.

### Why

Two inputs to `rust-release.yml` are not just orchestration — they are part of
the **build recipe**, and whatever they point at ends up inside the published
image:

- **`webui_ref`** — `hc-web-leptos` has no release workflow of its own. Its WASM
  bundle is cloned and built *inside core's release*, so this ref decides which
  UI is baked into `hc-core`.
- **`docker_repo_ref`** — the `Dockerfile` and entrypoints are fetched from
  `homeCore-io/docker` at this ref. It decides *how* the image is built.

Both used to be hardcoded to `develop`. That meant a **tagged** image was built
from whatever those branches happened to be at that instant — so the image could
not be rebuilt from its own tag. The UI and the recipe inside a released artifact
were unrecorded. Rebuilding `v0.1.5` today could quietly produce a different
image than `v0.1.5` shipped, and nothing anywhere would say so. (This was not
hypothetical: one UI change landed in an appliance image with two minutes to
spare, purely by timing.)

Callers now pin both on a tag push:

```yaml
webui_ref:       ${{ startsWith(github.ref, 'refs/tags/') && github.ref_name || 'develop' }}
docker_repo_ref: ${{ startsWith(github.ref, 'refs/tags/') && github.ref_name || 'develop' }}
```

The repos are versioned in lockstep — `homeCore-io/docker` and `hc-web-leptos`
both carry `v0.1.0`–`v0.1.5` — so core `v0.1.6` builds against docker `v0.1.6`
and bundles UI `v0.1.6`. A tagged image is reproducible from its tag alone.

Failing the release beats falling back to `develop`: an artifact nobody can
reproduce is worse than a release that stopped and told you why.

### Order

```
1. Tag homeCore-io/docker        v0.1.6
2. Tag homeCore-io/hc-web-leptos v0.1.6
3. Tag homeCore (core) + any plugins being released   v0.1.6
```

### This does NOT apply to `develop`

Pushing to `develop` still resolves both refs to `develop`, which is the whole
point of a dev image — it tracks the branch. **Ordinary day-to-day pushes need no
ceremony.** The ordering only binds when you push a `v*` tag.

---

## CI: the `permissions` block is not optional

Every caller's `ci.yml` must declare:

```yaml
permissions:
  contents: read
  issues: write
```

Both `rust-ci.yml` and `flutter-ci.yml` open and close a tracking issue when
`develop` goes red, and a called workflow can never hold more permissions than
its caller. The default workflow token is read-only, so without this the run dies
at **startup** — zero jobs, no annotation, and a red X that explains nothing. CI
was dead org-wide for weeks this way before anyone noticed, because `release.yml`
had its own `permissions` block and kept working, which made it look like a code
problem.

This binds on **every** caller, not just `ci.yml`. `hc-web`'s `release.yml` runs
CI as a gate before it publishes an image, so it must grant `issues: write`
alongside its `packages: write` — declare it at the workflow level, where it is
hard to miss, rather than on the calling job.

## The toolchain is pinned, on purpose

`rust-ci.yml` pins `rust_version` (matching the `rust:<ver>-alpine` digest the
Dockerfiles build from), so **CI compiles with the toolchain that actually
ships**. Do not pass `rust_version: "stable"` from a caller — that gates merges
on a compiler you never ship with, and turns CI red on Rust release day with no
code change.

`flutter-ci.yml` pins `flutter_version` for the same reason. Keep it equal to
`ARG FLUTTER_VERSION` in `hc-web`'s Dockerfile — bump the two together, or CI is
no longer testing what ships.

Two wrinkles specific to Flutter:

- **The Dockerfile fetches the SDK tarball directly**, rather than building from
  `ghcr.io/cirruslabs/flutter`. That image bundles the Android SDK and NDK — about
  2 GB of layers a *web* build never touches, and a cold build spent over eleven
  minutes pulling it before compiling anything. It also only publishes some
  versions, which forced the pin to track the registry instead of the SDK. Pulling
  the tarball means the pin can be the version we actually develop against.
- **`flutter analyze` exits non-zero on *any* finding, including infos.** That is
  deliberate — it is the only way a lint gets fixed rather than accumulating. CI
  also runs `dart format --set-exit-if-changed`, the counterpart of
  `cargo fmt --check`.

`hc-web`'s Dockerfile used to build from `:stable`, which meant a tagged image
could not be rebuilt from its own tag — the same reproducibility hole `webui_ref`
and `docker_repo_ref` had, and fixed the same way.

Each repo has a weekly `canary.yml` that runs the same checks against latest
stable, on `develop`, and gates nothing. A red canary means *stable moved*, not
*develop is broken* — read it as a preview of what the next pin bump will demand.
(hc-web arrived with a deprecation from 3.41 that nothing had ever reported. That
is exactly the bill a canary stops you paying all at once.)
