{
  lib,
  stdenv,
  makeRustPlatform,
  pkg-config,
  dbus,
  autoPatchelfHook,
  rustToolchain,
}: let
  # Honor the toolchain the repo pins in rust-toolchain.toml
  # (channel 1.94.1 + rustfmt, clippy) so Nix builds match CI and the
  # AUR/Debian packaging exactly, including the edition-2024 frontend.
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  cargoToml = lib.importTOML ../Cargo.toml;

  # libdbus-sys (pulled in transitively by `bluer`, Linux/glibc only)
  # runs `bindgen` against the system D-Bus headers at build time.
  nativeBuildInputs = [
    pkg-config
    rustPlatform.bindgenHook # sets LIBCLANG_PATH + clang for bindgen
  ];

  buildInputs = lib.optionals stdenv.isLinux [
    dbus # libdbus-1.so.3, linked via bluer→libdbus-sys
    stdenv.cc.cc.lib # libgcc_s.so.1, needed by every Rust binary
  ];
in
  rustPlatform.buildRustPackage {
    pname = "fips";
    version = cargoToml.package.version;

    src = lib.cleanSourceWith {
      src = ../.;
      # Drop the build dir and the usual editor/VCS noise so the source
      # hash is stable and unrelated edits don't trigger rebuilds.
      filter = path: type:
        (lib.cleanSourceFilter path type) && (baseNameOf path != "target");
    };

    cargoLock.lockFile = ../Cargo.lock;

    inherit buildInputs;

    # autoPatchelfHook rewrites the RPATH of the built binaries so the
    # daemon finds libdbus-1.so.3 (linked via bluer→libdbus-sys) in the
    # Nix store at runtime — without it the `fips` binary fails to load
    # on NixOS where there is no global /usr/lib.
    nativeBuildInputs = nativeBuildInputs ++ lib.optionals stdenv.isLinux [autoPatchelfHook];

    # The test suite exercises TUN devices, raw sockets and mDNS, none of
    # which exist in the build sandbox. The AUR/Debian packaging likewise
    # ships the release binaries without running the integration tests
    # here, so keep the package build hermetic and skip them.
    doCheck = false;

    meta = {
      description = cargoToml.package.description;
      homepage = cargoToml.package.homepage;
      license = lib.licenses.mit;
      mainProgram = "fips";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
