# NixOS module for the FIPS mesh network daemon.
#
# Exposed as nixosModules.default in flake.nix, which also provides the
# package default. Consumers enable it with:
#
#   { inputs, ... }: {
#     imports = [ inputs.fips.nixosModules.default ];
#     services.fips.enable = true;
#   }
#
# --- Declarative config ---
#
# The daemon config is rendered from Nix. Typed options (tun.name,
# dns.enable, gateway.enable, persistentIdentity, identityKeyFile)
# contribute module defaults, and the freeform
# services.fips.settings attrset — 1:1 with the daemon's yaml schema —
# is deep-merged over them, so explicit settings keys always win. The
# merged attrset is rendered to a world-readable store file and
# symlinks to /etc/fips/fips.yaml on every start, so the Nix
# configuration supersedes whatever is on the machine.
# services.fips.configFile is the escape hatch: a complete yaml the
# module symlinks verbatim, ignoring settings and peers.
#
# The merge is lib.recursiveUpdate in a let binding, not mkDefault
# injections into the option: the module system only discharges
# property wrappers at option-definition level, so a leaf-wise
# mkDefault inside a flat attrset option would survive to the merged
# value as raw { _type = "override"; ... } sets. Consequence: settings
# values must be plain — a property wrapper anywhere inside settings
# trips an eval-time warning, because recursiveUpdate would ignore it
# and the renderer would emit garbage yaml.
#
# The daemon is always launched with --config /etc/fips/fips.yaml —
# never the store path — because it derives the key paths
# (fips.key/fips.pub) from the config path's parent directory
# (src/config/mod.rs key_file_path: lexical, never canonicalized).
# A symlink at the /etc path keeps the keys in /etc/fips/ either way;
# passing a store path directly would aim them at the read-only store.
#
# The hosts file and ACL files (peers.allow, peers.deny) stay real
# writable files at /etc/fips/ because fips hardcodes those paths on
# Linux (DEFAULT_HOSTS_PATH, DEFAULT_PEERS_ALLOW_PATH,
# DEFAULT_PEERS_DENY_PATH). They are runtime state — fipsctl peer
# approvals write peers.allow — not declarative config, so they are
# seeded once and then owned by the operator and the daemon.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fips;

  # Module defaults mirroring the shipped fips.yaml's active content
  # (packaging/common/fips.yaml: TUN up, DNS responder on, UDP/TCP
  # listeners on the documented ports) plus the typed options.
  # cfg.settings is deep-merged over these, so users only override the
  # keys they care about. Identity is deliberately NOT defaulted here:
  # upstream is ephemeral; a persistent identity is opted into via
  # settings.node.identity.persistent.
  defaultSettings =
    {
      tun = {
        enabled = true;
        name = cfg.tun.name;
        mtu = 1280;
      };
      dns.enabled = cfg.dns.enable;
      transports.udp.bind_addr = "0.0.0.0:2121";
      transports.tcp.bind_addr = "0.0.0.0:8443";
    }
    // lib.optionalAttrs cfg.gateway.enable {
      gateway.enabled = true;
    };

  # The typed peers list concatenates with settings.peers; every other
  # settings key deep-merges over the defaults (recursiveUpdate: nested
  # attrsets merge key-wise, later wins).
  finalSettings =
    (lib.recursiveUpdate defaultSettings (builtins.removeAttrs cfg.settings [ "peers" ]))
    // {
      peers = cfg.peers ++ (cfg.settings.peers or [ ]);
    };

  # Single source of truth for the mesh interface name and the DNS
  # responder address: the FINAL merged settings, so settings.tun.name
  # or settings.dns.* overrides stay consistent with the nft template,
  # the gateway's interface wait and the resolved drop-in below.
  meshInterface = finalSettings.tun.name or "fips0";
  dnsBindAddr = finalSettings.dns.bind_addr or "::1";
  dnsPort = finalSettings.dns.port or 5354;

  # The rendered config. Store files are world-readable, which is why
  # settings must never carry a secret nsec (warned at eval time) —
  # identity belongs in /etc/fips/fips.key via identityKeyFile, or in
  # the daemon's own persistent key generation.
  generatedConfigYaml = pkgs.writeText "fips.yaml" (
    lib.generators.toYAML { } finalSettings
  );

  # What /etc/fips/fips.yaml points at: the operator's configFile
  # escape hatch, or the yaml rendered from settings.
  configTarget = if cfg.configFile != null then cfg.configFile else generatedConfigYaml;

  # The shipped mesh-interface nftables baseline, with the interface
  # name templated to the final merged tun.name so a non-default name
  # still matches (the upstream file targets fips0).
  fipsNft = pkgs.writeText "fips.nft" (
    lib.replaceStrings
      [ ''define fips_if = "fips0"'' ]
      [ ''define fips_if = "${meshInterface}"'' ]
      (builtins.readFile ../common/fips.nft)
  );

  # Deep-scan settings for module-system property wrappers
  # (mkDefault/mkForce/mkIf/mkMerge leaves): recursiveUpdate ignores
  # them and the renderer would emit garbage yaml, so warn instead.
  findPropWrappers =
    v:
    if lib.isAttrs v then
      if v ? _type && builtins.elem v._type [ "override" "if" "merge" ] then
        [ v._type ]
      else
        lib.concatMap findPropWrappers (builtins.attrValues v)
    else
      [ ];
in
{
  options.services.fips = {
    enable = lib.mkEnableOption "FIPS mesh network daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fips or (throw ''
        services.fips.package: pkgs.fips does not exist. Import this
        module via the flake's nixosModules.default (which provides the
        package), or apply the fips overlay (overlays.default), or set
        services.fips.package explicitly.
      '');
      defaultText = lib.literalExpression "pkgs.fips";
      description = ''
        The fips package to use. The flake's nixosModules.default sets
        this to its own build automatically; when importing the raw
        module, apply the fips flake overlay (overlays.default) or set
        this option explicitly.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Escape hatch: an absolute path to a complete fips.yaml that the
        module symlinks to /etc/fips/fips.yaml verbatim. When set,
        services.fips.settings and services.fips.peers are ignored —
        the module cannot see inside your file, so everything the
        daemon reads comes from it. Typed service-level options
        (dns.enable, firewall.*, gateway.enable) still apply: they
        drive module-side units, not the yaml. Use this to manage the
        config outside Nix — e.g. a secrets-rendering tool that needs
        an inline nsec, which settings must never carry because the
        rendered yaml lands in the world-readable store. Pass a path
        literal for a file you manage in your config tree (it is
        copied into the store), or a plain string for runtime paths
        like /run/secrets/...: a path literal must exist at eval time,
        which a runtime-rendered secret does not.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Freeform attrset rendered to fips.yaml — the full daemon
        schema, 1:1 with the shipped packaging/common/fips.yaml: the
        node, tun, dns, transports, peers and gateway sections. These
        settings are deep-merged over the module's defaults (TUN up,
        DNS responder on, UDP/TCP listeners on the documented ports),
        so you only override the keys that differ — and an explicit
        key here always wins over the typed options (tun.name,
        dns.enable, gateway.enable, persistentIdentity). Values must
        be plain (no mkDefault/mkForce: the merge is not the module
        system's, so properties would be ignored — warned at eval
        time).

        Never put a secret node.identity.nsec here: the rendered yaml
        lives in the world-readable Nix store. Provision
        /etc/fips/fips.key via services.fips.identityKeyFile (a runtime
        secrets path) or let the daemon generate the key with
        services.fips.persistentIdentity instead.
      '';
      example = {
        node.rendezvous.nostr = {
          enabled = true;
          policy = "configured_only";
        };
      };
    };

    peers = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
      description = ''
        Static outbound peers for bootstrapping — the config's
        top-level peers list — concatenated with any settings.peers
        entries. Each entry maps 1:1 to the daemon's peer schema
        (npub, alias, via_nostr, addresses with transport/addr,
        connect_policy); the daemon validates entries and fails the
        start on a malformed one. Inbound approvals are separate
        runtime state (peers.allow, written by fipsctl) and are not
        managed here.
      '';
      example = [
        {
          npub = "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98";
          alias = "gateway";
          addresses = [ { transport = "udp"; addr = "gw.example.com:2121"; } ];
          connect_policy = "auto_connect";
        }
      ];
    };

    tun.name = lib.mkOption {
      type = lib.types.str;
      default = "fips0";
      description = ''
        Mesh TUN interface name. Part of the module defaults (an
        explicit settings.tun.name wins); the nftables baseline, the
        gateway's interface wait and the daemon all read the final
        merged value, so a rename stays consistent everywhere.
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
          (packaging/common/fips.nft, templated to the configured
          tun.name) as a fips-firewall.service oneshot. The baseline
          polices only the mesh interface, leaving Docker, Tor, and the
          host firewall untouched; inbound on the mesh interface is
          denied except for established replies, ICMPv6 echo-request,
          and the operator drop-ins from
          services.fips.firewall.extraRules. Outbound is unrestricted.
          Note that accepts in extraRules do not bypass the NixOS host
          firewall (networking.firewall, enabled by default) — a packet
          must pass both. Open the port in both places, or set
          networking.firewall.trustedInterfaces to the mesh interface
          name and let this baseline be the sole policy for it.
        '';
      };

      extraRules = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          nftables rule lines written to /etc/fips/fips.d/extra.nft and
          included inline into the baseline inbound chain — e.g.
          `tcp dport 22 accept` to permit SSH over the mesh. Reload with
          `systemctl reload fips-firewall`` (gapless: the table is
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
          Route .fips queries to the fips DNS responder via a
          systemd-resolved drop-in (the DNS= line follows the final
          merged settings.dns bind_addr/port). Presupposes the host is
          running systemd-resolved; the module does not force it on so
          an operator's own resolver choice (dnsmasq, NetworkManager)
          is left undisturbed. Without this, .fips hostnames don't
          resolve on the host. Also defaults the config's dns.enabled —
          an explicit settings.dns.enabled wins. Disabling removes the
          drop-in on the next rebuild, but systemd-resolved keeps the
          old routing in memory until it is restarted.
        '';
      };
    };

    gateway = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the outbound LAN gateway: renders
          settings.gateway.enabled = true and starts fips-gateway,
          letting non-fips hosts on the LAN reach mesh destinations via
          DNS-allocated virtual IPs and kernel NAT. The required
          gateway.pool and gateway.lan_interface (and the optional
          gateway.dns tuning) are set via services.fips.settings —
          the daemon refuses to start a gateway without them. Requires
          the fips daemon running with DNS.
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

    warnings =
      # .fips resolution presupposes systemd-resolved; surface a missing
      # resolver at eval time instead of only a failed fips-dns unit at boot.
      lib.optionals (cfg.dns.enable && !config.services.resolved.enable) [
        "services.fips.dns.enable is true but services.resolved.enable is false — .fips names will not resolve. Enable systemd-resolved, or forward the .fips zone to [::1]:5354 in your own resolver and ignore this warning."
      ]
      # Property wrappers inside settings are silently ignored by the
      # recursiveUpdate merge and would render as garbage yaml.
      ++ lib.optionals (cfg.configFile == null && findPropWrappers cfg.settings != [ ]) [
        "services.fips.settings contains module-system properties (mkDefault/mkForce/mkIf/mkMerge), which this option does not support: the merge is not the module system's, so they would be ignored and rendered as garbage. Use plain values — an explicit settings key always wins over the typed options anyway."
      ]
      # With a configFile the module cannot render anything — say which
      # knobs are silently dropped.
      ++ lib.optionals (cfg.configFile != null && cfg.settings != { }) [
        "services.fips.configFile is set; services.fips.settings is ignored — the module symlinks your file verbatim."
      ]
      ++ lib.optionals (cfg.configFile != null && cfg.peers != [ ]) [
        "services.fips.configFile is set; services.fips.peers is ignored — declare the peers in the configFile itself."
      ]
      ++ lib.optionals (cfg.configFile != null && !lib.hasPrefix "/" (toString cfg.configFile)) [
        "services.fips.configFile must be an absolute path; a relative path cannot be resolved by the service unit."
      ]
      # The daemon refuses to start a gateway without pool/lan_interface.
      ++ lib.optionals (cfg.configFile == null && cfg.gateway.enable && (finalSettings.gateway.pool or null) == null) [
        "services.fips.gateway.enable is set but settings.gateway.pool (and lan_interface) are missing; the daemon refuses to start a gateway without them."
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

      preStart = ''
        # Point /etc/fips/fips.yaml at the declarative config: the yaml
        # rendered from services.fips.settings, or the operator's
        # configFile escape hatch. The daemon is always launched with
        # the /etc path — never a store path — because it derives the
        # key file paths (fips.key/fips.pub) from the config path's
        # parent directory, and a store path would put them in the
        # read-only, world-readable store.
        if [ -f /etc/fips/fips.yaml ] && [ ! -L /etc/fips/fips.yaml ]; then
          # A regular file here is an operator-owned config from the
          # earlier hybrid model of this module (or a manual edit):
          # never destroy it silently — keep it beside the symlink and
          # say so loudly.
          cp -a /etc/fips/fips.yaml "/etc/fips/fips.yaml.manual-$(date +%s)"
          echo "WARNING: /etc/fips/fips.yaml is now a symlink managed by NixOS (services.fips.settings or services.fips.configFile); the previous file was backed up beside it. Port any manual edits into the Nix configuration." >&2
        fi
        ln -sfn "${configTarget}" /etc/fips/fips.yaml

        # Seed hosts file (fips hardcodes /etc/fips/hosts on Linux).
        # 0644 root:root — world-readable so fipsctl can load it without
        # privileges; it holds only hostname → npub mappings. Unlike the
        # config, hosts stays a real writable file: it is runtime state
        # the operator and daemon extend, not declarative config.
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
    # .fips queries to the daemon's DNS responder. This is the
    # NixOS-native equivalent of the upstream fips-dns-setup script's
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
        DNS=[${dnsBindAddr}]:${toString dnsPort}
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
          ${pkgs.iproute2}/bin/ip link show ${meshInterface} >/dev/null 2>&1 && exit 0
          sleep 1
        done
        echo "${meshInterface} did not appear within 30s" >&2
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
      documentation = [ "file://${fipsNft}" ];
      before = [ "fips.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${fipsNft}";
        # Reapplies the ruleset in place: fips.nft adds then flushes the
        # table, so one nft run replaces it in a single transaction, with
        # no moment without it. A restart, by contrast, runs ExecStop
        # (delete table) before ExecStart, leaving a gap.
        ExecReload = "${pkgs.nftables}/bin/nft -f ${fipsNft}";
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
