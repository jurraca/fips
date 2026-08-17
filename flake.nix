{
  description = "FIPS — a distributed, decentralized network routing protocol for mesh nodes connecting over arbitrary transports";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
    }:
    let
      # The systems we build for. Matches `meta.platforms` in
      # nix/package.nix (Linux + Darwin). Restricting the set explicitly
      # (rather than flake-utils' eachDefaultSystem) keeps `nix flake
      # check` from evaluating ill-supported platforms and is the
      # nixpkgsFor idiom.
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      # Import nixpkgs for a given system with this flake's overlay
      # applied, so `pkgs.fips` resolves to the package defined here.
      nixpkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

      # The Rust toolchain pinned in rust-toolchain.toml (channel 1.94.1
      # + rustfmt/clippy), materialized via fenix so Nix builds match CI
      # and the AUR/Debian packaging exactly, including the edition-2024
      # frontend.
      rustToolchainFor =
        system:
        fenix.packages.${system}.fromToolchainFile {
          file = ./rust-toolchain.toml;
          sha256 = "sha256-zC8E38iDVJ1oPIzCqTk/Ujo9+9kx9dXq7wAwPMpkpg0=";
        };
    in
    {
      overlays.default = final: _prev: {
        fips = final.callPackage ./nix/package.nix {
          rustToolchain = rustToolchainFor final.system;
        };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor system;
        in
        {
          default = pkgs.fips;
          fips = pkgs.fips;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor system;
          mkApp = name: {
            type = "app";
            program = "${pkgs.fips}/bin/${name}";
            meta.description = "Run the ${name} binary from the FIPS package";
          };
        in
        {
          default = mkApp "fips";
          fips = mkApp "fips";
          fipsctl = mkApp "fipsctl";
          fips-gateway = mkApp "fips-gateway";
          fipstop = mkApp "fipstop";
        }
      );

      # `nix flake check` builds the package (and thus validates the
      # flake on the current system).
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor system;
        in
        {
          fips = pkgs.fips;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor system;
          rustToolchain = rustToolchainFor system;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
          # Keep the dev shell's native/build inputs in lockstep with the
          # package derivation (nix/package.nix) so `nix develop` matches
          # `nix build` for bindgen/dbus/libclang provisioning.
          nativeBuildInputs = [
            pkgs.pkg-config
            rustPlatform.bindgenHook
          ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.dbus
            pkgs.stdenv.cc.cc.lib
          ];
        in
        {
          default = pkgs.mkShell {
            inherit buildInputs;
            nativeBuildInputs = nativeBuildInputs ++ [
              rustToolchain
              pkgs.cargo-edit
            ];
            # Point rust-analyzer at the matching std sources.
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
          };
        }
      );

      nixosModules = {
        fips = ./nix/module.nix;
        default = self.nixosModules.fips;
      };

      formatter = forAllSystems (system: (nixpkgsFor system).nixfmt);
    };
}
