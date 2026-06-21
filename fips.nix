{
  stdenv,
  lib,
  rustPlatform,
  pkg-config,
  cmake,
  openssl,
  bluez,
  dbus,
  ...
}: let
  pname = "fips";
  version = "0.4.0-dev";
  src = ./.;
in
  rustPlatform.buildRustPackage rec {
    inherit pname version src;

    cargoLock.lockFile = ./Cargo.lock;

    nativeBuildInputs = [
      pkg-config
      cmake
      rustPlatform.bindgenHook
    ];

    buildInputs =
      [openssl]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        bluez
        dbus
      ];

    # Install immutable package assets only. Runtime integration (/etc,
    # systemd units, tmpfiles, state dirs) is owned by module.nix.
    postInstall = ''
      install -Dm644 ${./packaging/common/fips.yaml} $out/share/fips/fips.yaml.example
      install -Dm644 ${./packaging/common/hosts} $out/share/fips/hosts
      install -Dm644 ${./packaging/common/fips.nft} $out/share/fips/fips.nft

      install -Dm755 ${./packaging/common/fips-dns-setup} $out/libexec/fips/fips-dns-setup
      install -Dm755 ${./packaging/common/fips-dns-teardown} $out/libexec/fips/fips-dns-teardown
      patchShebangs $out/libexec/fips
    '';

    meta = with lib; {
      description = "Free Internetworking Peering System";
      homepage = "https://github.com/jmcorgan/fips";
      license = licenses.mit;
      mainProgram = "fips";
    };
  }
