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

    firewall = {
      enable = lib.mkEnableOption "the fips0 mesh-interface nftables baseline" // {
        description = ''
          Install and load the shipped fips.nft baseline
          (packaging/common/fips.nft) as a fips-firewall.service oneshot.
          The baseline polices only the fips0 mesh interface, leaving
          Docker, Tor, and the host firewall untouched; inbound on the
          mesh interface is denied except for established replies,
          ICMPv6 echo-request, and the operator drop-ins from
          services.fips.firewall.extraRules. Outbound is unrestricted.
          Note that accepts in extraRules do not bypass the NixOS host
          firewall (networking.firewall, enabled by default) — a packet
          must pass both. Open the port in both places, or set
          networking.firewall.trustedInterfaces = [ "fips0" ] and let
          this baseline be the sole policy for the mesh interface.
        '';
      };

      extraRules = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          nftables rule lines written to /etc/fips/fips.d/extra.nft and
          included inline into the baseline inbound chain — e.g.
          `tcp dport 22 accept` to permit SSH over the mesh. Reload with
          `systemctl reload fips-firewall` (gapless: the table is
          replaced in a single nft transaction).
        '';
        example = ''
          tcp dport 22 accept
          tcp dport 80 accept
        '';
      };
    };

    dns = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Route .fips queries to the fips DNS responder on [::1]:5354
          via a systemd-resolved drop-in. Presupposes the host is
          running systemd-resolved; the module does not force it on so
          an operator's own resolver choice (dnsmasq, NetworkManager)
          is left undisturbed. Without this, .fips hostnames don't
          resolve on the host. Disabling removes the drop-in on the
          next rebuild, but systemd-resolved keeps the old routing in
          memory until it is restarted.
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

    # Put fipsctl/fipstop/fips-gateway on PATH so the operator can reach
    # them without referencing the store path.
    environment.systemPackages = [ cfg.package ];

    # .fips resolution presupposes systemd-resolved; surface a missing
    # resolver at eval time instead of only a failed fips-dns unit at boot.
    warnings = lib.optionals (cfg.dns.enable && !config.services.resolved.enable) [
      "services.fips.dns.enable is true but services.resolved.enable is false — .fips names will not resolve. Enable systemd-resolved, or forward the .fips zone to [::1]:5354 in your own resolver and ignore this warning."
    ];

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

    # Declarative resolved drop-in for the .fips zone. Writes
    # /etc/systemd/resolved.conf.d/fips.conf so systemd-resolved forwards
    # .fips queries to the daemon's DNS responder on [::1]:5354. This is
    # the NixOS-native equivalent of the upstream fips-dns-setup script's
    # "global drop-in" backend — it avoids per-link interface scoping and
    # the IPV6_PKTINFO ifindex attribution that can cause queries to be
    # silently dropped by the mesh-interface filter. Upstream's setup
    # script now prefers its dns-delegate backend on systemd >= 258; the
    # drop-in is kept here deliberately because it is uniform across
    # NixOS releases, declarative via environment.etc, and purely
    # additive — it never clobbers the operator's resolved config.
    environment.etc."systemd/resolved.conf.d/fips.conf" = lib.mkIf cfg.dns.enable {
      text = ''
        # Managed by services.fips.dns.enable — do not edit.
        [Resolve]
        DNS=[::1]:5354
        Domains=~fips
      '';
    };

    # Restart resolved once after the daemon is up so the drop-in takes
    # effect. Fails loudly on hosts without systemd-resolved so the
    # operator notices the missing dependency rather than debugging
    # silent .fips resolution failure. Deliberately no
    # PartOf=fips.service (unlike the rest of the wiring): the drop-in
    # needs no re-application, and matching upstream fips-dns.service
    # here keeps a fips restart from bouncing the host resolver.
    systemd.services.fips-dns = lib.mkIf cfg.dns.enable {
      description = "Apply .fips DNS forwarding to systemd-resolved";
      after = [ "fips.service" ];
      requires = [ "fips.service" ];
      wantedBy = [ "fips.service" ];
      unitConfig.ConditionPathExists = "/etc/systemd/resolved.conf.d/fips.conf";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.systemd}/bin/systemctl restart systemd-resolved.service";
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

    # Operator nftables drop-in for the mesh-interface baseline. The
    # /etc/fips/fips.d/ directory is created by the tmpfiles rules above;
    # fips.nft includes /etc/fips/fips.d/*.nft inline in its inbound chain.
    environment.etc."fips/fips.d/extra.nft" = lib.mkIf cfg.firewall.enable {
      text = cfg.firewall.extraRules;
    };

    systemd.services.fips-firewall = lib.mkIf cfg.firewall.enable {
      description = "FIPS mesh-interface nftables baseline";
      documentation = [ "file://${cfg.package}/share/fips/fips.nft" ];
      before = [ "fips.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${cfg.package}/share/fips/fips.nft";
        # Reapplies the ruleset in place: fips.nft adds then flushes the
        # table, so one nft run replaces it in a single transaction, with
        # no moment without it. A restart, by contrast, runs ExecStop
        # (delete table) before ExecStart, leaving a gap.
        ExecReload = "${pkgs.nftables}/bin/nft -f ${cfg.package}/share/fips/fips.nft";
        ExecStop = "-${pkgs.nftables}/bin/nft delete table inet fips";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 8443 ];
      allowedUDPPorts = [ 2121 ];
    };
  };
}
