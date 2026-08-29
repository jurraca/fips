# NixOS module for the FIPS mesh network daemon.
#
# Exposed as nixosModules.default in flake.nix.
# Consumers enable it with:
#
#   { inputs, ... }: {
#     imports = [ inputs.fips.nixosModules.default ];
#     services.fips.enable = true;
#   }
#
# The package is provided via the flake's overlay (overlays.default), so it
# lands in pkgs.fips without the consumer needing to know the input name.
#
# --- Hybrid config pattern ---
#
# fips.yaml and identity keys live in /etc/fips/ (writable, survives
# reboots and rebuilds), matching the Debian/AUR packaging layout. The
# shipped default is seeded there on first run only; operator edits are
# never clobbered. The daemon derives key paths (fips.key/fips.pub) from
# the config file's parent directory, so keys land alongside the config.
#
# The hosts file and ACL files (peers.allow, peers.deny) also live at
# /etc/fips/ because fips hardcodes those paths on Linux
# (DEFAULT_HOSTS_PATH, DEFAULT_PEERS_ALLOW_PATH, DEFAULT_PEERS_DENY_PATH).
# They are seeded as real writable files (not Nix store symlinks) so the
# operator can edit them directly.
#
# fips is launched with --config /etc/fips/fips.yaml, which bypasses
# the config search path entirely — fips will never accidentally load
# a stale or alternate config.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fips;
in
{
  options.services.fips = {
    enable = lib.mkEnableOption "FIPS mesh network daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fips;
      defaultText = lib.literalExpression "pkgs.fips";
      description = ''
        The fips package to use. Defaults to the one provided by the
        fips flake overlay (overlays.default).
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.package}/share/fips/fips.yaml";
      defaultText = lib.literalExpression "''${cfg.package}/share/fips/fips.yaml";
      description = ''
        Default fips.yaml used to seed the writable config at
        /etc/fips/fips.yaml on first run. The operator can then edit
        /etc/fips/fips.yaml directly; this file is never overwritten
        after the initial seed.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open firewall ports for fips transports
        (UDP 2121, TCP 8443).
      '';
    };

    dns = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Route .fips queries to the fips DNS responder on [::1]:5354
          via systemd-resolved. Without this, .fips hostnames don't
          resolve on the host.
        '';
      };
    };

    gateway = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the outbound LAN gateway. Lets non-fips hosts on the
          LAN reach mesh destinations via DNS-allocated virtual IPs
          and kernel NAT. Requires the fips daemon running with DNS.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # 'fips' group so non-root users can reach the control socket for
    # fipsctl/fipstop without sudo. Editing /etc/fips files requires root,
    # matching the Debian/AUR posture.
    users.groups.fips = { };

    # Root-owned writable directories for hosts file, ACL files, and
    # nftables drop-ins. fips hardcodes /etc/fips/hosts,
    # /etc/fips/peers.allow, /etc/fips/peers.deny on Linux, so these MUST
    # live here. Created as real directories (not environment.etc
    # symlinks) so the operator can edit files in place as root.
    systemd.tmpfiles.rules = [
      "d /etc/fips 0755 root root -"
      "d /etc/fips/fips.d 0755 root root -"
    ];

    systemd.services.fips = {
      description = "FIPS Mesh Network Daemon";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "network-online.target" ];

      # Seed config and hosts on first run only. Existing files are never
      # overwritten, so operator edits survive service restarts and system
      # rebuilds.
      preStart = ''
        # Seed writable config from the shipped default (only if absent).
        # fips derives key paths (fips.key/fips.pub) from the config file's
        # parent directory, so keys also land in /etc/fips/.
        # 0640 root:fips — group members (trusted operators) may read the
        # config, the world may not: the yaml can carry an inline nsec.
        if [ ! -f /etc/fips/fips.yaml ]; then
          cp "${cfg.configFile}" /etc/fips/fips.yaml
          chown root:fips /etc/fips/fips.yaml
          chmod 0640 /etc/fips/fips.yaml
        fi

        # Seed hosts file (fips hardcodes /etc/fips/hosts on Linux).
        # 0644 root:root — world-readable so fipsctl can load it without
        # privileges; it holds only hostname → npub mappings.
        if [ ! -f /etc/fips/hosts ]; then
          cp "${cfg.package}/share/fips/hosts" /etc/fips/hosts
          chown root:root /etc/fips/hosts
          chmod 0644 /etc/fips/hosts
        fi
      '';

      serviceConfig = {
        Type = "simple";
        # Run as root:fips so the daemon has root for TUN/raw sockets while
        # group members can reach the control socket.
        Group = "fips";
        # --config bypasses the search path: fips loads ONLY this file,
        # never a stale or alternate config.
        ExecStart = "${cfg.package}/bin/fips --config /etc/fips/fips.yaml";
        Restart = "on-failure";
        RestartSec = 5;
        # Back off between automatic restarts: 5s, 7s, 10s, 15s, 21s, then
        # 30s. Cleared by a stop then start, a restart while running, or
        # reset-failed; not by a run that succeeds, nor by a restart while
        # waiting to restart.
        RestartSteps = 5;
        RestartMaxDelaySec = 30;

        # Control socket directory (/run/fips/) — group-traversable so
        # 'fips' group members can reach the socket (write permission is
        # on the socket file itself). Matches upstream fips.service.
        RuntimeDirectory = "fips";
        RuntimeDirectoryMode = "0750";

        # Log directory (/var/log/fips/) for the built-in profiler.
        LogsDirectory = "fips";

        # Security hardening (daemon runs as root for TUN and raw sockets).
        # Mirrors packaging/systemd/fips.service.
        ProtectHome = "yes";
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = false;
      };
    };

    services.resolved = lib.mkIf cfg.dns.enable {
      enable = true;
      settings.Resolve = {
        DNS = [ "[::1]:5354" ];
        Domains = [ "~fips" ];
      };
    };

    systemd.services.fips-gateway = lib.mkIf cfg.gateway.enable {
      description = "FIPS Outbound LAN Gateway";
      wantedBy = [ "multi-user.target" ];
      after = [ "fips.service" ];
      requires = [ "fips.service" ];

      preStart = ''
        for i in $(seq 1 30); do
          ${pkgs.iproute2}/bin/ip link show fips0 >/dev/null 2>&1 && exit 0
          sleep 1
        done
        echo "fips0 did not appear within 30s" >&2
        exit 1
      '';

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/fips-gateway --config /etc/fips/fips.yaml";
        Restart = "on-failure";
        RestartSec = 5;
        # Back off between automatic restarts: 5s, 7s, 10s, 15s, 21s, then
        # 30s. Cleared by a stop then start, a restart while running, or
        # reset-failed; not by a run that succeeds, nor by a restart while
        # waiting to restart.
        RestartSteps = 5;
        RestartMaxDelaySec = 30;
        TimeoutStopSec = 15;
        ProtectHome = "yes";
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = false;
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 8443 ];
      allowedUDPPorts = [ 2121 ];
    };
  };
}
