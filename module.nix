{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.fips;

  peerAddressToSettings = address: {
    inherit (address) transport addr priority;
  };

  peerToSettings = peer: {
    inherit (peer) npub;
    alias = peer.alias;
    addresses = map peerAddressToSettings peer.addresses;
    connect_policy = peer.connectPolicy;
    auto_reconnect = peer.autoReconnect;
    via_nostr = peer.viaNostr;
  };

  udpSettings = optionalAttrs cfg.transports.udp.enable {
    bind_addr = cfg.transports.udp.bindAddr;
    mtu = cfg.transports.udp.mtu;
    recv_buf_size = cfg.transports.udp.recvBufSize;
    send_buf_size = cfg.transports.udp.sendBufSize;
    advertise_on_nostr = cfg.transports.udp.advertiseOnNostr;
    public = cfg.transports.udp.public;
    external_addr = cfg.transports.udp.externalAddr;
    outbound_only = cfg.transports.udp.outboundOnly;
    accept_connections = cfg.transports.udp.acceptConnections;
  };

  tcpSettings = optionalAttrs cfg.transports.tcp.enable {
    bind_addr = cfg.transports.tcp.bindAddr;
    mtu = cfg.transports.tcp.mtu;
    connect_timeout_ms = cfg.transports.tcp.connectTimeoutMs;
    nodelay = cfg.transports.tcp.nodelay;
    keepalive_secs = cfg.transports.tcp.keepaliveSecs;
    recv_buf_size = cfg.transports.tcp.recvBufSize;
    send_buf_size = cfg.transports.tcp.sendBufSize;
    max_inbound_connections = cfg.transports.tcp.maxInboundConnections;
    advertise_on_nostr = cfg.transports.tcp.advertiseOnNostr;
    external_addr = cfg.transports.tcp.externalAddr;
  };

  gatewaySettings = optionalAttrs cfg.gateway.enable {
    gateway = {
      enabled = true;
      pool = cfg.gateway.pool;
      lan_interface = cfg.gateway.lanInterface;
      dns = {
        listen = cfg.gateway.dns.listen;
        upstream = cfg.gateway.dns.upstream;
        ttl = cfg.gateway.dns.ttl;
      };
      pool_grace_period = cfg.gateway.poolGracePeriod;
      conntrack = {
        tcp_established = cfg.gateway.conntrack.tcpEstablished;
        udp_timeout = cfg.gateway.conntrack.udpTimeout;
        udp_assured = cfg.gateway.conntrack.udpAssured;
        icmp_timeout = cfg.gateway.conntrack.icmpTimeout;
      };
      port_forwards = cfg.gateway.portForwards;
    };
  };

  generatedSettings =
    recursiveUpdate
    {
      node = {
        identity = {
          nsec = cfg.node.identity.nsec;
          persistent = cfg.node.identity.persistent;
        };
      };

      tun = {
        enabled = cfg.tun.enable;
        name = cfg.tun.name;
        mtu = cfg.tun.mtu;
      };

      dns = {
        enabled = cfg.dns.enable;
        bind_addr = cfg.dns.bindAddr;
        port = cfg.dns.port;
        ttl = cfg.dns.ttl;
      };

      transports = {
        udp = udpSettings;
        tcp = tcpSettings;
      };

      peers = map peerToSettings cfg.peers;
    }
    gatewaySettings;

  finalSettings = recursiveUpdate generatedSettings cfg.settings;
  generatedConfig = pkgs.writeText "fips.yaml" (builtins.toJSON finalSettings);
  configFile =
    if cfg.configFile != null
    then cfg.configFile
    else generatedConfig;

  fipsArgs =
    "--config /etc/fips/fips.yaml"
    + optionalString (cfg.extraFlags != []) (" " + concatStringsSep " " (map escapeShellArg cfg.extraFlags));

  waitForFips0 = pkgs.writeShellScript "fips-wait-for-fips0" ''
    i=0
    while [ "$i" -lt 30 ]; do
      if ${pkgs.iproute2}/bin/ip link show fips0 >/dev/null 2>&1; then
        exit 0
      fi
      i=$((i + 1))
      sleep 1
    done
    echo "fips0 did not appear within 30s" >&2
    exit 1
  '';
in {
  options.services.fips = {
    enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Enable FIPS mesh network services.";
    };

    package = lib.mkOption {
      type = types.package;
      default = pkgs.fips;
      defaultText = literalExpression "pkgs.fips";
      description = ''
        The FIPS package to use. The package provides the FIPS binaries,
        immutable examples/assets under share/fips, and private helper scripts
        under libexec/fips. Runtime integration is declared by this module.
      '';
    };

    daemon.enable = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Enable the FIPS daemon systemd service.";
    };

    firewall.enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Enable the FIPS mesh nftables firewall baseline service.";
    };

    node.identity.persistent = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Persist the node identity across restarts. When enabled, FIPS stores
        fips.key/fips.pub next to the active configuration file.
      '';
    };

    node.identity.nsec = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Explicit node private key as nsec bech32 or hex. This is serialized into
        the generated Nix store config and is therefore world-readable; prefer a
        custom configFile or a future secret-management option for production.
      '';
    };

    tun.enable = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Enable the FIPS TUN interface in the daemon config.";
    };

    tun.name = lib.mkOption {
      type = types.str;
      default = "fips0";
      description = "FIPS TUN interface name.";
    };

    tun.mtu = lib.mkOption {
      type = types.ints.between 576 65535;
      default = 1280;
      description = "FIPS TUN interface MTU.";
    };

    dns.enable = lib.mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable FIPS DNS support. This both sets dns.enabled in the generated
        daemon config and enables fips-dns.service to wire .fips resolution into
        the host resolver.
      '';
    };

    dns.bindAddr = lib.mkOption {
      type = types.nullOr types.str;
      default = "::1";
      description = "Address for the FIPS daemon DNS responder to bind.";
    };

    dns.port = lib.mkOption {
      type = types.port;
      default = 5354;
      description = "Port for the FIPS daemon DNS responder.";
    };

    dns.ttl = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "DNS response TTL in seconds. Null uses the daemon default.";
    };

    transports.udp.enable = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Enable the default UDP transport instance.";
    };

    transports.udp.bindAddr = lib.mkOption {
      type = types.str;
      default = "0.0.0.0:2121";
      description = "UDP transport bind address.";
    };

    transports.udp.mtu = lib.mkOption {
      type = types.nullOr (types.ints.between 1 65535);
      default = null;
      description = "UDP MTU. Null uses the daemon default.";
    };

    transports.udp.recvBufSize = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "UDP receive buffer size in bytes. Null uses the daemon default.";
    };

    transports.udp.sendBufSize = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "UDP send buffer size in bytes. Null uses the daemon default.";
    };

    transports.udp.advertiseOnNostr = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Advertise the UDP transport on Nostr overlay discovery.";
    };

    transports.udp.public = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Advertise UDP as directly reachable instead of NAT-rendezvous when
        advertiseOnNostr is enabled.
      '';
    };

    transports.udp.externalAddr = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Explicit public UDP address to advertise.";
    };

    transports.udp.outboundOnly = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Run UDP in outbound-only mode with an ephemeral bind port.";
    };

    transports.udp.acceptConnections = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Accept inbound UDP handshakes from new peers.";
    };

    transports.tcp.enable = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Enable the default TCP transport instance.";
    };

    transports.tcp.bindAddr = lib.mkOption {
      type = types.nullOr types.str;
      default = "0.0.0.0:8443";
      description = "TCP transport listen address. Null makes TCP outbound-only.";
    };

    transports.tcp.mtu = lib.mkOption {
      type = types.nullOr (types.ints.between 1 65535);
      default = null;
      description = "TCP MTU. Null uses the daemon default.";
    };

    transports.tcp.connectTimeoutMs = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "TCP outbound connect timeout in milliseconds.";
    };

    transports.tcp.nodelay = lib.mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Enable TCP_NODELAY. Null uses the daemon default.";
    };

    transports.tcp.keepaliveSecs = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "TCP keepalive interval in seconds. Null uses the daemon default.";
    };

    transports.tcp.recvBufSize = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "TCP receive buffer size in bytes. Null uses the daemon default.";
    };

    transports.tcp.sendBufSize = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "TCP send buffer size in bytes. Null uses the daemon default.";
    };

    transports.tcp.maxInboundConnections = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "Maximum simultaneous inbound TCP connections.";
    };

    transports.tcp.advertiseOnNostr = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Advertise the TCP transport on Nostr overlay discovery.";
    };

    transports.tcp.externalAddr = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Explicit public TCP address to advertise.";
    };

    gateway.enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the FIPS gateway. This both sets gateway.enabled in the generated
        daemon config and enables the fips-gateway systemd service.
      '';
    };

    gateway.pool = lib.mkOption {
      type = types.str;
      default = "fd01::/112";
      description = "Gateway virtual IP pool CIDR.";
    };

    gateway.lanInterface = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "eth0";
      description = "LAN-facing interface for gateway proxy ARP/NDP. Required when gateway.enable is true.";
    };

    gateway.dns.listen = lib.mkOption {
      type = types.nullOr types.str;
      default = "[::1]:5353";
      description = "Gateway DNS resolver listen address.";
    };

    gateway.dns.upstream = lib.mkOption {
      type = types.nullOr types.str;
      default = "[::1]:5354";
      description = "Upstream FIPS daemon DNS resolver address used by the gateway.";
    };

    gateway.dns.ttl = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 60;
      description = "Gateway DNS record TTL in seconds.";
    };

    gateway.poolGracePeriod = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 60;
      description = "Gateway pool grace period in seconds.";
    };

    gateway.conntrack.tcpEstablished = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 432000;
      description = "Gateway TCP established conntrack timeout in seconds.";
    };

    gateway.conntrack.udpTimeout = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 30;
      description = "Gateway UDP unreplied conntrack timeout in seconds.";
    };

    gateway.conntrack.udpAssured = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 180;
      description = "Gateway UDP assured conntrack timeout in seconds.";
    };

    gateway.conntrack.icmpTimeout = lib.mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 30;
      description = "Gateway ICMP conntrack timeout in seconds.";
    };

    gateway.portForwards = lib.mkOption {
      type = types.listOf types.attrs;
      default = [];
      description = ''
        Raw gateway port-forward entries. Each entry is serialized directly to
        gateway.port_forwards; use keys like listen_port, proto, and target.
      '';
    };

    peers = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          npub = lib.mkOption {
            type = types.str;
            description = "Peer Nostr public key in npub or hex format.";
          };

          alias = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional human-readable peer alias.";
          };

          addresses = lib.mkOption {
            type = types.listOf (types.submodule {
              options = {
                transport = lib.mkOption {
                  type = types.str;
                  description = "Transport type, such as udp or tcp.";
                };

                addr = lib.mkOption {
                  type = types.str;
                  description = "Transport-specific peer address.";
                };

                priority = lib.mkOption {
                  type = types.ints.between 0 255;
                  default = 100;
                  description = "Address selection priority; lower values are preferred.";
                };
              };
            });
            default = [];
            description = "Transport addresses for reaching this peer.";
          };

          connectPolicy = lib.mkOption {
            type = types.enum ["auto_connect" "on_demand" "manual"];
            default = "auto_connect";
            description = "Peer connection policy.";
          };

          autoReconnect = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Automatically reconnect after link-dead removal.";
          };

          viaNostr = lib.mkOption {
            type = types.bool;
            default = false;
            description = "Append Nostr-advertised endpoints when dialing this peer.";
          };
        };
      });
      default = [];
      description = "Static peers to connect to.";
    };

    configFile = lib.mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a complete fips.yaml to expose as /etc/fips/fips.yaml. If null,
        this module renders typed options plus services.fips.settings as JSON.
        The YAML parser accepts JSON.

        If configFile is set, typed daemon-config options are not rendered into
        /etc/fips/fips.yaml; keep the file consistent with service toggles such
        as services.fips.dns.enable and services.fips.gateway.enable.
      '';
    };

    settings = lib.mkOption {
      type = types.attrs;
      default = {};
      description = ''
        Raw FIPS daemon settings as an attribute set. These are recursively
        merged over the config generated from typed NixOS options, then
        serialized to JSON. Use this as an escape hatch for options not yet
        modeled by this module.
      '';
      example = literalExpression ''
        {
          node.discovery.nostr.enabled = true;
          transports.udp.advertise_on_nostr = true;
        }
      '';
    };

    extraFlags = lib.mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra CLI flags to pass to the FIPS daemon.";
    };

    user = lib.mkOption {
      type = types.str;
      default = "fips";
      description = "User to run the FIPS daemon as.";
    };

    group = lib.mkOption {
      type = types.str;
      default = "fips";
      description = "Group to run the FIPS daemon as.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !cfg.gateway.enable
          || cfg.gateway.lanInterface != null
          || cfg.configFile != null
          || (cfg.settings.gateway or {}) ? lan_interface;
        message = "services.fips.gateway.lanInterface is required when services.fips.gateway.enable is true.";
      }
    ];

    users.groups.${cfg.group} = {};

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/fips";
      description = "FIPS mesh network daemon user";
    };

    environment.systemPackages = [cfg.package];

    # The package only carries immutable assets. The NixOS module owns /etc.
    environment.etc."fips/fips.yaml" = {
      source = configFile;
      mode = "0644";
    };

    systemd.services.fips = lib.mkIf cfg.daemon.enable {
      description = "FIPS Mesh Network Daemon";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"] ++ optional cfg.firewall.enable "fips-firewall.service";
      wants = ["network-online.target"] ++ optional cfg.firewall.enable "fips-firewall.service";

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/fips ${fipsArgs}";
        Restart = "on-failure";
        RestartSec = "5";

        RuntimeDirectory = "fips";
        RuntimeDirectoryMode = "0750";
        StateDirectory = "fips";
        StateDirectoryMode = "0750";

        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = false;

        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_SYS_ADMIN"];
        AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW"];

        ReadWritePaths = ["/etc/fips" "/var/lib/fips"];

        User = cfg.user;
        Group = cfg.group;
      };
    };

    systemd.services.fips-dns = lib.mkIf cfg.dns.enable {
      description = "Configure DNS routing for .fips domain";
      wantedBy = ["multi-user.target"];
      after = ["fips.service"];
      requires = ["fips.service"];
      path = with pkgs; [
        coreutils
        gawk
        gnugrep
        iproute2
        systemd
        networkmanager
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/libexec/fips/fips-dns-setup";
        ExecStop = "${cfg.package}/libexec/fips/fips-dns-teardown";
        RemainAfterExit = true;
      };
    };

    systemd.services.fips-firewall = lib.mkIf cfg.firewall.enable {
      description = "FIPS mesh-interface nftables baseline";
      wantedBy = ["multi-user.target"];
      before = ["fips.service"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.nftables}/bin/nft -f ${cfg.package}/share/fips/fips.nft";
        ExecStop = "-${pkgs.nftables}/bin/nft delete table inet fips";
        StandardOutput = "journal";
        StandardError = "journal";
        RemainAfterExit = true;
      };
    };

    systemd.services.fips-gateway = lib.mkIf cfg.gateway.enable {
      description = "FIPS Outbound LAN Gateway";
      wantedBy = ["multi-user.target"];
      after = ["fips.service"];
      requires = ["fips.service"];

      serviceConfig = {
        Type = "simple";
        ExecStartPre = waitForFips0;
        ExecStart = "${cfg.package}/bin/fips-gateway --config /etc/fips/fips.yaml";
        Restart = "on-failure";
        RestartSec = "5";
        TimeoutStopSec = "15";

        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" "CAP_NET_RAW"];
        AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW"];

        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = false;

        ReadWritePaths = ["/etc/fips"];
        User = cfg.user;
        Group = cfg.group;
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/fips 0750 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/fips 0750 ${cfg.user} ${cfg.group} - -"
    ];
  };
}
