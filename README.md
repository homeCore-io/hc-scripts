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

## Cutting a release: tag last, after CI is green

**Push the branch, watch the run, tag only when it is green.** Tagging is the
step that makes a mistake expensive, so it is the one to do last. To prove the
whole pipeline before committing to a version, run `release.yml` by
`workflow_dispatch` — it builds and archives without creating a Release.

**Local green is not CI green.** `rust-ci.yml` pins the toolchain to the version
the Dockerfiles ship (see *The toolchain is pinned, on purpose*, below) while a
dev machine tracks a newer stable, and clippy's lint set differs between them.
Two releases have been tagged off a commit whose CI then failed on exactly that:
`v0.1.66`, which had to be superseded by `v0.1.67` because its artifacts were
already published, and `v0.1.68`, which was recoverable only because the release
run was cancelled before it published anything. A published tag that changes
underneath somebody is worse than a wasted version number — so if artifacts are
out, fix forward.

### Every release gets notes

An entry in `homeCore-io.github.io/docs/release-notes.md`, written as part of
cutting it. That page is the operator-facing history and the only place a person
can read what changed without reading commits. A round containing nothing an
operator would notice still gets an entry saying so.

### There is no cross-repo tag ordering

This section used to say that `homeCore-io/docker` and
`homeCore-io/hc-web-leptos` had to be tagged *before* core or any plugin, and
that getting it wrong failed the release. **Both halves of that are now
historical.**

- **The Dockerfile moved in-repo.** A caller that sets `docker_context_dir`
  stages the recipe from its own repository, so the tag alone reproduces the
  image and `rust-release.yml` skips the `homeCore-io/docker` pre-flight
  entirely. Core does this (`docker_context_dir: docker`).
- **The WASM build is gone.** `rust-release.yml` no longer clones
  `hc-web-leptos` to bake a UI into `hc-core`; the UI is `hc-web`, with its own
  image and its own release.
- **Plugins publish no image at all** — they ship as signed registry artifacts
  (`publish_registry`), which involves neither repo.

The evidence, if this is ever doubted again: neither repo carries a `v0.1.6x`
tag, and core `v0.1.63`–`v0.1.68` all shipped without one.

The legacy path still exists for a caller that leaves `docker_context_dir`
empty: the Dockerfile and entrypoints are then fetched from `homeCore-io/docker`
at `docker_repo_ref`, that ref is part of the build recipe, and the pre-flight
fails the release by name if the tag is missing — which is still better than
silently falling back to `develop` and publishing an artifact nobody can
reproduce. **No caller in this workspace is that caller:** `hc-tui` publishes no
image, and `hc-web-flutter` ships its own `Dockerfile` from its own repo.

### This does NOT apply to `develop`

Ordinary day-to-day pushes need no ceremony. Everything above is about pushing
a `v*` tag.

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
could not be rebuilt from its own tag — the same reproducibility hole the old
`webui_ref` and `docker_repo_ref` had, and fixed the same way. (`webui_ref` no
longer exists; core's recipe now lives in core. See *There is no cross-repo tag
ordering*, above.)

Each repo has a weekly `canary.yml` that runs the same checks against latest
stable, on `develop`, and gates nothing. A red canary means *stable moved*, not
*develop is broken* — read it as a preview of what the next pin bump will demand.
(hc-web arrived with a deprecation from 3.41 that nothing had ever reported. That
is exactly the bill a canary stops you paying all at once.)
