{ pkgs, config, ... }:

{
  packages = with pkgs; [
    gh
    just
    jq
    curl
    unzip
    cmake
    pkg-config
    openssl
  ];

  # Pinned to the toolchain CI and the release builds use (hc-scripts'
  # rust-ci.yml / rust-release.yml `rust_version`), so a local clippy run sees
  # the same lints CI does. Bump all of them together.
  languages.rust = {
    enable = true;
    channel = "stable";
    version = "1.100.0";
  };

  # Python plugins and the Python SDK. 3.15 is the minor python-release.yml
  # builds plugins for by default, and the newest the registry ships an
  # interpreter for (homeCore-io/interpreters). Bump them together.
  languages.python = {
    enable = true;
    package = pkgs.python315;
    uv.enable = true;
  };

  # The web app (hc-web-svelte) and the JS SDK. Node 26 (LTS) matches the
  # node:26-alpine image the app builds from and node-ci.yml's pin.
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_26;
  };

  # --home > HOMECORE_HOME > cwd, per core/homecore/src/main.rs. Anchor both to
  # the workspace root so entering the shell from core/ or clients/ still points
  # at sandbox/ rather than the subdirectory. The config sits where core looks
  # under any home, config/homecore.toml; HOMECORE_CONFIG outranks that default,
  # so it must name the same file.
  env = {
    HOMECORE_HOME = "${config.devenv.root}/sandbox";
    HOMECORE_CONFIG = "${config.devenv.root}/sandbox/config/homecore.toml";
  };

  enterShell = ''
    export PATH="$DEVENV_ROOT/core/target/debug:$PATH"

    echo "homeCore dev environment ready"
    echo "  rust: $(rustc --version)"
    echo "  node: $(node --version)"
    echo "  python: $(python --version)"
  '';
}
