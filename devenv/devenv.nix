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
    version = "1.99.1";
  };

  # Python plugins and the Python SDK. 3.12 is the interpreter
  # python-release.yml builds artifacts for.
  languages.python = {
    enable = true;
    package = pkgs.python312;
    uv.enable = true;
  };

  # The web app (hc-web-svelte) and the JS SDK. Node 24 matches the
  # node:24-alpine image the app builds from and node-ci.yml's pin.
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_24;
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
