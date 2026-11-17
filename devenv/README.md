# devenv for the homeCore workspace

These files set up the development shell for the whole workspace: the pinned
Rust toolchain, Python 3.12 with uv, Node 24, `just`, `gh` and the build
libraries. They belong at the workspace root (the directory that holds
`core/`, `clients/`, `hc-scripts/` and the rest), which is not a repository,
so they are kept here.

| File here | Goes to the workspace root as |
|---|---|
| `devenv.nix` | `devenv.nix` |
| `devenv.yaml` | `devenv.yaml` |
| `devenv.lock` | `devenv.lock` |
| `envrc` | `.envrc` |

`envrc` has no leading dot here so that direnv does not offer to load it
inside `hc-scripts/`.

## Setting it up

You need [devenv](https://devenv.sh) and, for the automatic shell,
[direnv](https://direnv.net). From the workspace root:

```bash
cp hc-scripts/devenv/devenv.nix hc-scripts/devenv/devenv.yaml hc-scripts/devenv/devenv.lock .
cp hc-scripts/devenv/envrc .envrc
direnv allow        # or run `devenv shell` by hand
```

The first load builds the toolchain and takes a while; later loads are quick.

Copies drift from this directory once you edit them. To pick up changes made
here, copy again; to share a change you made at the root, copy it back here
and commit it.

## What it sets

- `HOMECORE_HOME` is `<workspace>/sandbox` and `HOMECORE_CONFIG` is
  `<workspace>/sandbox/config/homecore.toml`, so a bare `homecore` run from
  anywhere in the shell uses the sandbox. That is the same home and config the
  workspace `Justfile`'s `sandbox` recipes pass on the command line.
- `core/target/debug` is put on `PATH`, so a fresh `cargo build` is the
  `homecore` you run.

The Rust version is pinned to the one CI uses (`rust_version` in
`.github/workflows/rust-ci.yml` and `rust-release.yml`). Bump them together.

`.devenv/` and `.direnv/` are caches; `just clean-env` removes both and the
next load rebuilds them.
