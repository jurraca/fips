# NixOS module for FIPS — the Free Internetworking Peering System.
#
# Maps the documented YAML configuration (docs/reference/configuration.md)
# and the four upstream systemd units (packaging/systemd/*.service) onto
# declarative NixOS options. The full `fips.yaml` schema is intentionally
# exposed as a freeform `settings` attrset rather than re-typed field by
# field: the schema has ~100 keys across node/tun/dns/transports/peers/
# gateway, many of them nested and transport-specific, and re-typing them
# here would just duplicate (and drift from) the reference doc. Typed
# convenience options are provided only for the fields the module itself
# needs to wire systemd / firewall / DNS plumbing, so NixOS and the
# generated config never disagree about the TUN name, DNS port, etc.
#
# Usage (with the flake's overlay applied):
#
#   services.fips.enable = true;
#   services.fips.openFirewall = true;
#   services.fips.settings = {
#     node.identity.persistent = true;
#     peers = [ { npub = "npub1..."; alias = "gateway";
#                 addresses = [ { transport = "udp"; addr = "203.0.113.5:2121"; } ]; } ];
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.fips;

  # Default config mirroring packaging/common/fips.yaml plus the
  # NixOS-appropriate choices (persistent identity so /etc/fips/fips.key
  # is generated once and reused; TUN + DNS + UDP/TCP listeners on the
  # documented ports). `cfg.settings` is deep-merged over this, so users
  # only override the keys they care about.
  defaultSettings = {
    node.identity.persistent = true;
    tun = {
      enabled = true;
      name = cfg.tun.name;
      mtu = 1280;
    };
    dns = {
      enabled = true;
      bind_addr = cfg.dns.bindAddr;
      port = cfg.dns.port;
    };
    transports.udp.bind_addr = "0.0.0.0:2121";
    transports.tcp.bind_addr = "0.0.0.0:8443";
    peers = [];
  };

  finalSettings = lib.recursiveUpdate defaultSettings cfg.settings;

  # Rendered YAML lives in the Nix store (world-readable). Operators who
  # need a secret nsec in-config should instead rely on the persistent
  # keyfile (`node.identity.persistent: true`, the default here) which is
  # written to /etc/fips/fips.key (mode 0600) at runtime — never put a
  # secret nsec in `services.fips.settings`, it will land in the store.
  generatedConfigYaml = pkgs.writeText "fips.yaml" (
    lib.generators.toYAML {} finalSettings
  );

  # The config file passed to the daemon. If the operator points at an
  # external file we use it verbatim; otherwise we use the generated one.
  # We don't symlink /etc/fips/fips.yaml directly at the store path
  # because the daemon writes fips.key/fips.pub "adjacent to the config
  # file" — a symlink into the store would make that a read-only dir. The
  # fips-init oneshot below copies the generated YAML into /etc/fips/ so
  # the runtime keyfile write succeeds.
  configFilePath =
    if cfg.configFile != null
    then cfg.configFile
    else "/etc/fips/fips.yaml";

  # The shipped mesh-interface nftables baseline (packaging/common/fips.nft),
  # with the interface name templated to the configured TUN name so a
  # non-default `tun.name` still matches. The upstream file targets fips0.
  fipsNft = let
    src = builtins.readFile ../packaging/common/fips.nft;
    rewritten =
      lib.replaceStrings [''iifname != "fips0"''] [
        ''iifname != "${cfg.tun.name}"''
      ]
      src;
  in
    pkgs.writeText "fips.nft" rewritten;

  # Upstream static hostname→npub roster for .fips DNS resolution
  # (packaging/common/hosts). Exposed verbatim; operators can extend via
  # `services.fips.settings`-free /etc/fips/hosts.d drop-ins out of scope.
  fipsHosts = ../packaging/common/hosts;
in {
  options.services.fips = {
    enable = lib.mkEnableOption "the FIPS mesh network daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fips;
      defaultText = lib.literalExpression "pkgs.fips";
      description = ''
        The FIPS package to use. Defaults to the one provided by this
        flake's overlay; apply the overlay (`overlays.default`) or
        override this option if you are not importing the flake as a
        NixOS module.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an explicit `fips.yaml` to pass to the daemon with
        `--config`. When set, the module does not generate
        `/etc/fips/fips.yaml` from `settings` and the `fips-init`
        oneshot is skipped. Use this to manage the config outside Nix
        (e.g. a secrets-rendering tool).
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = ''
        Freeform attrset rendered to `/etc/fips/fips.yaml` as YAML. The
        full schema is documented in
        <https://fips.network/docs/reference/configuration> — five
        top-level sections: `node`, `tun`, `dns`, `transports`,
        `peers`, plus the `gateway` block read only by `fips-gateway`.

        These settings are deep-merged over the module's defaults
        (persistent identity, TUN up, DNS on, UDP/TCP listeners on the
        documented ports), so you only need to override keys that differ.

        Never put a secret `node.identity.nsec` here: the rendered YAML
        lives in the world-readable Nix store. Keep
        `node.identity.persistent: true` (the default) and let the
        daemon generate `/etc/fips/fips.key` at runtime.
      '';
      example = {
        node.leaf_only = true;
        peers = [
          {
            npub = "npub1tdwa4vjrjl33pcjdpf2t4p027nl86xrx24g4d3avg4vwvayr3g8qhd84le";
            alias = "node-b";
            addresses = [
              {
                transport = "udp";
                addr = "172.20.0.11:2121";
              }
            ];
          }
        ];
      };
    };

    tun.name = lib.mkOption {
      type = lib.types.str;
      default = "fips0";
      description = ''
        Name of the TUN virtual interface. Used by the module to template
        the nftables baseline, the `fips-gateway` readiness wait, and the
        generated `tun.name` config key. Keep consistent with
        `services.fips.settings.tun.name` if you override either.
      '';
    };

    dns.bindAddr = lib.mkOption {
      type = lib.types.str;
      default = "::1";
      description = ''
        Address the FIPS DNS responder binds to. Mirrors `dns.bind_addr`
        in the YAML. The default `::1` matches the upstream
        `fips-dns-setup` global-drop-in backend, which is what
        `services.fips.dns.resolved.enable` wires up declaratively.
      '';
    };

    dns.port = lib.mkOption {
      type = lib.types.port;
      default = 5354;
      description = ''
        Port the FIPS DNS responder listens on. Mirrors `dns.port` in the
        YAML and the upstream `fips-dns-setup` default.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the documented peer-to-peer mesh ports in the NixOS host
        firewall (`networking.firewall`): UDP 2121 and TCP 8443, matching
        `packaging/systemd/README.install.md`. The mesh-interface
        `fips0` baseline is a separate concern — see
        `services.fips.firewall.enable`.
      '';
    };

    firewall.enable =
      lib.mkEnableOption "the `fips0` mesh-interface nftables default-deny baseline"
      // {
        description = ''
          Install and load the shipped `fips.nft` baseline
          (packaging/common/fips.nft) as a `fips-firewall.service` oneshot.
          The baseline polices only the mesh interface (default `fips0`),
          leaving Docker, Tor, and the host firewall untouched; inbound on
          the mesh interface is denied except for established replies,
          ICMPv6 echo-request, and the operator drop-ins from
          `services.fips.firewall.extraRules`. Outbound is unrestricted.
        '';
      };

    firewall.extraRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        nftables rule lines written to `/etc/fips/fips.d/extra.nft` and
        included inline into the baseline `inbound` chain — e.g.
        `tcp dport 22 accept` to permit SSH over the mesh. Reload with
        `systemctl restart fips-firewall`.
      '';
      example = ''
        tcp dport 22 accept
        tcp dport 80 accept
      '';
    };

    gateway.enable =
      lib.mkEnableOption "the `fips-gateway` LAN bridge service"
      // {
        description = ''
          Enable `fips-gateway.service`, which folds an unmodified LAN into
          the mesh (outbound DNS-proxy + virtual-IP NAT, and optional
          inbound port forwards). Requires a `gateway.*` block in
          `services.fips.settings` (`gateway.enabled: true`, `gateway.pool`,
          `gateway.lan_interface`). The unit `Requires=fips.service` and
          waits up to 30s for the TUN interface to appear. Linux only.
        '';
      };

    dns.resolved.enable =
      lib.mkEnableOption "declarative `.fips` forwarding to systemd-resolved"
      // {
        description = ''
          Write `/etc/systemd/resolved.conf.d/fips.conf` declaratively so
          systemd-resolved forwards the `.fips` zone to the FIPS DNS
          responder at `services.fips.dns.bindAddr:port`. This is the
          NixOS-native equivalent of the upstream `fips-dns-setup` script's
          preferred "global drop-in" backend, and avoids running the
          bash probe at runtime. A `fips-dns.service` oneshot restarts
          resolved after the daemon is up so the drop-in takes effect.

          Only enable this on hosts actually running systemd-resolved.
        '';
      };
  };

  config = lib.mkIf cfg.enable {
    users.groups.fips = {};

    environment.systemPackages = [cfg.package];

    # Static hosts roster (no secret) is fine to symlink from the store.
    environment.etc."fips/hosts".source = fipsHosts;

    # Host-firewall ports for peer-to-peer mesh traffic (UDP 2121, TCP 8443).
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedUDPPorts = [2121];
      allowedTCPPorts = [8443];
    };

    # Declarative resolved drop-in for the .fips zone (NixOS-native path,
    # replacing the upstream fips-dns-setup bash probe's preferred backend).
    environment.etc."systemd/resolved.conf.d/fips.conf" = lib.mkIf cfg.dns.resolved.enable {
      text = ''
        # Managed by services.fips.dns.resolved.enable — do not edit.
        [Resolve]
        DNS=[${cfg.dns.bindAddr}]:${toString cfg.dns.port}
        Domains=~fips
      '';
    };

    # Operator nftables drop-in for the mesh-interface baseline.
    environment.etc."fips/fips.d/extra.nft" = lib.mkIf cfg.firewall.enable {
      text = cfg.firewall.extraRules;
    };

    systemd.packages = [cfg.package];

    systemd.services = {
      # Seeds /etc/fips/fips.yaml (mode 0600) from the generated store
      # YAML on every start so the config tracks the NixOS declaration,
      # while leaving the daemon-generated /etc/fips/fips.key untouched.
      # Skipped when the operator provides an explicit `configFile`.
      fips-init = lib.mkIf (cfg.configFile == null) {
        description = "Render FIPS daemon configuration";
        before = ["fips.service"];
        requiredBy = ["fips.service"];
        partOf = ["fips.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0750 -o root -g fips /etc/fips
          install -m 0600 -o root -g fips ${generatedConfigYaml} /etc/fips/fips.yaml
        '';
      };

      fips = {
        description = "FIPS Mesh Network Daemon";
        after = ["network-online.target"] ++ lib.optional (cfg.configFile == null) "fips-init.service";
        wants = ["network-online.target"];
        requires = lib.optional (cfg.configFile == null) "fips-init.service";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.package}/bin/fips --config ${configFilePath}";
          Restart = "on-failure";
          RestartSec = 5;
          # /run/fips — group-accessible so `fips` group members can use
          # fipsctl/fipstop against the control socket.
          RuntimeDirectory = "fips";
          RuntimeDirectoryMode = "0750";
          Group = "fips";
          # /var/log/fips — tick-body profiler capture dir.
          LogsDirectory = "fips";
          # Security hardening (daemon runs as root for TUN + raw sockets).
          ProtectHome = "yes";
          PrivateTmp = "yes";
          ProtectKernelModules = "yes";
          ProtectKernelTunables = "no";
        };
      };

      # Restart resolved so the declarative .fips drop-in takes effect,
      # after the daemon is up and listening on the configured port.
      fips-dns = lib.mkIf cfg.dns.resolved.enable {
        description = "Apply .fips DNS forwarding to systemd-resolved";
        after = ["fips.service"];
        requires = ["fips.service"];
        wantedBy = ["fips.service"];
        partOf = ["fips.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.systemd}/bin/systemctl restart systemd-resolved.service";
        };
        unitConfig.ConditionPathExists = "/etc/systemd/resolved.conf.d/fips.conf";
      };

      fips-gateway = lib.mkIf cfg.gateway.enable {
        description = "FIPS Outbound LAN Gateway";
        after = ["fips.service"];
        requires = ["fips.service"];
        wantedBy = ["multi-user.target"];
        # Wait up to 30s for the TUN interface to appear — the gateway
        # hard-fails on a missing interface and this avoids a noisy
        # restart cycle on fresh boot while still surfacing real failures.
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "${pkgs.bash}/bin/sh -c 'for i in $(seq 1 30); do ${pkgs.iproute2}/bin/ip link show ${cfg.tun.name} >/dev/null 2>&1 && exit 0; sleep 1; done; echo \"${cfg.tun.name} did not appear within 30s\" >&2; exit 1'";
          ExecStart = "${cfg.package}/bin/fips-gateway --config ${configFilePath}";
          Restart = "on-failure";
          RestartSec = 5;
          StandardOutput = "journal";
          StandardError = "journal";
          TimeoutStopSec = 15;
          # Needs CAP_NET_ADMIN for nftables + proxy NDP.
          ProtectHome = "yes";
          PrivateTmp = "yes";
          ProtectKernelModules = "yes";
          ProtectKernelTunables = "no";
        };
      };

      fips-firewall = lib.mkIf cfg.firewall.enable {
        description = "FIPS mesh-interface nftables baseline";
        documentation = ["file:///etc/fips/fips.nft"];
        before = ["fips.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.nftables}/bin/nft -f ${fipsNft}";
          ExecStop = "-${pkgs.nftables}/bin/nft delete table inet fips";
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };
    };
  };
}
