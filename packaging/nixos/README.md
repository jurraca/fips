# NixOS Packaging

NixOS module and flake outputs for FIPS.

## Quick Start (flake consumers)

Add fips as a flake input and enable the service:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    fips = {
      url = "github:jmcorgan/fips";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, fips, ... }@inputs: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./configuration.nix
        fips.nixosModules.default     # ← import the module
        {
          services.fips.enable = true; # ← enable the daemon
        }
      ];
    };
  };
}
```

Apply with:

```sh
sudo nixos-rebuild switch --flake .#myhost
```

The module defaults its package to the flake's own build — no overlay
is needed. Apply `overlays.default` only if you want `pkgs.fips`
available elsewhere in your package set.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `services.fips.enable` | bool | `false` | Enable the FIPS mesh network daemon |
| `services.fips.package` | package | flake's own build | The fips package (set automatically by `nixosModules.default`) |
| `services.fips.settings` | attrs | `{}` | Freeform attrset rendered to `fips.yaml` (deep-merged over the module defaults; explicit keys win) |
| `services.fips.peers` | list of attrs | `[]` | Static outbound peers, concatenated with `settings.peers` |
| `services.fips.configFile` | path (or string) | `null` | Escape hatch: a complete `fips.yaml` symlinked verbatim, ignoring `settings`/`peers` |
| `services.fips.tun.name` | str | `"fips0"` | Mesh TUN interface name (templated into the nft baseline and gateway wait) |
| `services.fips.persistentIdentity` | bool | `false` | Render `node.identity.persistent: true` (first start mints the key, kept in `/etc/fips/fips.key`) |
| `services.fips.identityKeyFile` | str | `null` | Runtime path to a private key (bare nsec); provisions `/etc/fips/fips.key` every start |
| `services.fips.openFirewall` | bool | `true` | Open UDP 2121 + TCP 8443 |
| `services.fips.firewall.enable` | bool | `false` | Load the mesh-interface nftables baseline (`fips-firewall.service`) |
| `services.fips.firewall.extraRules` | lines | `""` | nftables rule lines included in the baseline's inbound chain |
| `services.fips.dns.enable` | bool | `true` | Route `.fips` queries to the fips DNS responder via a systemd-resolved drop-in |
| `services.fips.gateway.enable` | bool | `false` | Enable the outbound LAN gateway (`fips-gateway.service`); pool/lan_interface via `settings.gateway.*` |

## Declarative config

The daemon config is rendered from your Nix configuration: the typed
options contribute module defaults, the freeform
`services.fips.settings` attrset (1:1 with the daemon's yaml schema —
see the shipped `packaging/common/fips.yaml` for the reference) is
deep-merged over them, and the result is symlinked to
`/etc/fips/fips.yaml` on every start. An explicit settings key always
wins over a typed option; values must be plain (no `mkDefault` and
friends — warned at eval time, since the merge is not the module
system's).

```nix
services.fips = {
  enable = true;
  persistentIdentity = true;

  # Static outbound peers — the common fleet case has its own option:
  peers = [{
    npub = "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98";
    alias = "gateway";
    addresses = [{ transport = "udp"; addr = "gw.example.com:2121"; }];
    connect_policy = "auto_connect";
  }];

  # Everything else in the yaml schema, keyed exactly as the daemon
  # reads it:
  settings.node.rendezvous.nostr = {
    enabled = true;
    policy = "configured_only";
  };
};
```

`nix eval` shows the merged view; the rendered yaml is generated in
the store (world-readable — never put an inline `nsec` in settings,
use `identityKeyFile` instead).

### The `configFile` escape hatch

If you manage the config outside Nix — e.g. a secrets-rendering tool
that must inline an `nsec` — point the module at your complete yaml:

```nix
services.fips.configFile = "/etc/my-fips.yaml";  # a string for runtime paths
```

The module symlinks it to `/etc/fips/fips.yaml` verbatim:
`settings`, `peers` and `persistentIdentity` are ignored (warned when
set), while the module-side options (`dns.enable`, `firewall.*`,
`gateway.enable`) keep driving their units. With `identityKeyFile`,
the file must itself carry `node.identity.persistent: true` — checked
at start, since the module cannot see inside your file.

## What it does

- Puts the `fips`, `fipsctl`, `fipstop`, and `fips-gateway` binaries on `PATH`
- Creates a `fips` group for control-socket access (add your user for
  non-sudo `fipsctl`/`fipstop`); it does not grant edit rights on
  `/etc/fips`
- Renders `/etc/fips/fips.yaml` from `services.fips.settings` (a
  symlink to the store render) and seeds `/etc/fips/hosts` from the
  shipped default on first run only
- Runs `fips` as a systemd service (`fips.service`) as `root:fips`
  (root is required for TUN interfaces and raw sockets)
- Routes `.fips` DNS queries to the fips responder (the drop-in's
  `DNS=` line follows `settings.dns.bind_addr`/`port`; enabled by
  default, disable with `services.fips.dns.enable = false`)
- Optionally loads the mesh-interface nftables baseline
  (`services.fips.firewall.enable`, off by default)
- Optionally runs the outbound LAN gateway (`fips-gateway.service`)
- Opens firewall ports for UDP (2121) and TCP (8443) transports

## Design choices and gotchas

These are deliberate, but they will surprise an unprepared operator.
Read before relying on the module in production.

### 1. Identity is ephemeral by default

The shipped `fips.yaml` leaves `node.identity.persistent` commented
out, so **every service restart generates a new identity** — a new npub
and a new mesh IPv6. Peers will treat the node as brand new each time,
and any ACL or allowlist keyed to the old npub stops matching. On
NixOS this bites more often than you might expect: a flake update
changes the package, the unit restarts, and the identity churns — and
`Restart=on-failure` crash loops churn identities exactly when you
least want it.

On NixOS the configuration is the source of truth, so the native fix
is to **bring your own identity**:

```nix
services.fips.identityKeyFile = "/run/secrets/fips/fips.key";
```

The file must hold a bare bech32 nsec with a trailing newline, exactly
as `fipsctl keygen` writes it. The module provisions
`/etc/fips/fips.key` from it on every start (rotation propagates) and
enables `node.identity.persistent: true`, so a rebuild — or a full
reinstall from this configuration plus your secrets — reproduces the
same identity. The path must be a runtime secret path (sops-nix,
agenix, ...), never a store path: the Nix store is world-readable,
which is also why the module offers no inline `nsec` option. Replacing
an existing, different key backs the old one up beside the config
(`fips.key.replaced-<timestamp>`) and warns in the journal.

Without a secrets store, opt into generate-and-persist:

```nix
services.fips.persistentIdentity = true;
```

The first start mints a keypair into `/etc/fips/fips.key` (0600) and
keeps it across restarts and rebuilds. Fully declarative: removing the
option reverts the node to the ephemeral default on the next start
(the old `fips.key` stays on disk, unused).

Or set it in the freeform settings directly:

```nix
services.fips.settings.node.identity.persistent = true;
```

Recognizing the state you are in:

- The daemon logs `Using ephemeral identity (new keypair each start)`
  at info level on every ephemeral start — check `journalctl -u fips`.
- `fipsctl keygen` generates a keypair and prints the reminder to set
  `persistent: true`; it is the upstream-blessed way to mint an
  identity out-of-band (handy for feeding a secrets store).
- A `fips.key` found in ephemeral mode is never destroyed: the daemon
  moves it aside to `fips.key.unused` and warns. Set `persistent: true`
  and move it back to adopt it.

The default matches the Debian/AUR packaging; the module does not
diverge from the shipped config unless you ask it to.

### 2. State lives in /etc/fips — breaking change from earlier revisions

Earlier revisions of this module kept `fips.yaml` and the identity keys
in `/var/lib/fips/`. Everything now lives in `/etc/fips/`, matching the
daemon's Linux system-config directory and the Debian layout. There is
**no automatic migration**: upgrading a host that ran the old layout
without moving the keys re-generates — with
`node.identity.persistent: true` — a **new identity that peers
allowlisting the old npub will refuse**. (The config itself no longer
needs moving: it is rendered from your Nix configuration.) Before
upgrading, copy the identity state across:

```sh
sudo systemctl stop fips
sudo cp -a /var/lib/fips/fips.key /var/lib/fips/fips.pub /etc/fips/ 2>/dev/null || true
sudo systemctl start fips
```

(`fips.key`/`fips.pub` only exist if the node ran with
`persistent: true`.) Remove the leftover `/var/lib/fips` once the node
is healthy.

### 3. systemd-resolved is presupposed, not forced

`services.fips.dns.enable = true` (the default) writes
`/etc/systemd/resolved.conf.d/fips.conf` and restarts systemd-resolved
once the daemon is up — but it does **not** enable systemd-resolved,
so an operator's own resolver choice is left undisturbed. Consequences:

- On a host not running systemd-resolved, `fips-dns.service` fails
  loudly: a missing dependency should be visible, not silent. Enable
  `services.resolved.enable = true`, or wire your resolver by hand.
- dnsmasq/unbound/other resolvers: forward the `.fips` zone to
  `[::1]:5354` yourself, e.g. for dnsmasq:
  `server=/fips/::1#5354`.
- Disabling the option removes the drop-in on the next rebuild, but
  systemd-resolved keeps the old routing in memory until it is
  restarted.
- The build warns when `services.fips.dns.enable` is set but
  `services.resolved.enable` is not.

### 4. The mesh firewall is default-deny — and separate from the NixOS firewall

`services.fips.firewall.enable = true` loads the shipped `fips.nft`
baseline as `fips-firewall.service`. It polices **only** the `fips0`
mesh interface and denies all inbound except established replies,
ICMPv6 echo-requests, and the rules from
`services.fips.firewall.extraRules`. Enabling it without extra rules
cuts off inbound SSH and every other listener over the mesh.

`extraRules` accepts also do not bypass NixOS's own firewall
(`networking.firewall`, enabled by default) — a packet must pass both.
Either open the port in both places, or make the baseline the sole
mesh policy:

```nix
networking.firewall.trustedInterfaces = [ "fips0" ];
services.fips.firewall = {
  enable = true;
  extraRules = ''
    tcp dport 22 accept
  '';
};
```

Apply rule edits gaplessly with `systemctl reload fips-firewall`.

### 5. The config is fully declarative — machine state is superseded

`/etc/fips/fips.yaml` is a symlink to the yaml rendered from
`services.fips.settings` (or your `configFile` escape hatch). Every
start re-points it, so a rebuild supersedes whatever is on the
machine: there is no seed-once and no runtime editing of the config —
change it in Nix and rebuild. Hand-edits to `/etc/fips/fips.yaml` are
impossible (the symlink target is read-only store), and a regular
file left there by the earlier hybrid model of this module — or a
manual `rm` of the symlink followed by an edit — is backed up to
`fips.yaml.manual-<timestamp>` beside it (with a journal warning) on
the next start, never destroyed silently.

The **runtime** state files are deliberately outside this model and
stay editable as root: `/etc/fips/hosts`, `peers.allow`, `peers.deny`
(fipsctl approvals), and additional `fips.d/*.nft` drop-ins.

### 6. The `fips` group is for the control socket, not file edits

Group membership lets a user run `fipsctl`/`fipstop` without sudo (the
daemon's control socket is group-reachable in `/run/fips/`). It does
**not** allow editing anything under `/etc/fips` — files are
root-owned and editing requires sudo, matching the Debian/AUR
posture. The config drives a root daemon (TUN devices, raw sockets,
and — with the gateway — nftables), so write access to it is
admin-equivalent and is not handed out with the group. The rendered
config itself is world-readable (it lives in the store), which is why
settings must never carry an inline `nsec`.

## Config file layout

| Path | Purpose | Owner:mode | Source |
|---|---|---|---|
| `/etc/fips/fips.yaml` | Main config | symlink → store render (world-readable) | `services.fips.settings` / `configFile`, re-pointed every start |
| `/etc/fips/fips.key` | Node identity (private) | `root:fips` 0600 | generated by fips on first start with `persistent: true`, or provisioned from `identityKeyFile` |
| `/etc/fips/fips.pub` | Node identity (public) | `root:fips` 0644 | written by fips on every start |
| `/etc/fips/hosts` | Static hostname → npub map | `root:root` 0644 | shipped `hosts` (first run only), then operator/daemon-owned |
| `/etc/fips/peers.allow` | Peer allowlist (ACL) | operator-chosen | operator/fipsctl-created |
| `/etc/fips/peers.deny` | Peer denylist (ACL) | operator-chosen | operator-created |
| `/etc/fips/fips.d/extra.nft` | nftables drop-in rules | store symlink | `services.fips.firewall.extraRules` |
| `/etc/fips/fips.d/*.nft` | additional operator drop-ins | operator-chosen | operator-created |

Everything lives under `/etc/fips/` because that is the daemon's
system config directory on Linux: identity key paths are derived from
the config file's parent directory (the daemon is always launched
with the `/etc` path, never the store path, so keys land in
`/etc/fips/` even though the config is a symlink), and the hosts/ACL
paths are hardcoded (`DEFAULT_HOSTS_PATH`, `DEFAULT_PEERS_ALLOW_PATH`,
`DEFAULT_PEERS_DENY_PATH`).

The `fips.nft` baseline itself is **not** copied to `/etc/fips/` —
unlike the Debian layout — but loaded from a store render (the
shipped `packaging/common/fips.nft` with the interface name templated
to the final `tun.name`), so package upgrades bring security fixes to
the baseline. Only the drop-in rules are operator-owned.

### Why a preStart symlink, not `environment.etc`?

`environment.etc` would be the idiomatic way to plant the rendered
config, but it **collision-fails at activation time** when a regular
file already sits at `/etc/fips/fips.yaml` — exactly the situation an
upgrade from the earlier hybrid model leaves behind. The preStart
handles it politely: the operator-owned file is backed up to
`fips.yaml.manual-<timestamp>` with a journal warning, then the
symlink replaces it. Regular re-points are a plain idempotent
`ln -sfn`.

### Why `--config /etc/fips/fips.yaml`?

fips has a config search path (`./fips.yaml`, `~/.fips.yaml`,
`~/.config/fips/fips.yaml`, `/etc/fips/fips.yaml`). Passing `--config`
explicitly bypasses that search path entirely, so fips loads **only**
the operator-managed file — a config in the working directory or a
user's home can never shadow it.

## Usage after install

```sh
sudo journalctl -u fips -f     # follow logs
fipsctl show status            # check status (needs fips group membership)
fipstop                        # live monitoring
```

To use `fipsctl`/`fipstop` without sudo, add your user to the `fips` group:

```nix
users.users.myuser.extraGroups = [ "fips" ];
```

Log out and back in for the group change to take effect.

### Changing the config

The daemon config changes in Nix (`services.fips.settings` /
`configFile`), then `nixos-rebuild switch`; there is no runtime config
editing (see gotcha 5). Runtime state files stay editable as root:

```sh
sudo nano /etc/fips/hosts         # add static hostname mappings
sudo nano /etc/fips/peers.allow   # add peers to the allowlist
sudo systemctl restart fips       # apply changes
```

Files are root-owned (`hosts` is `0644 root:root`); editing requires
sudo. The `fips` group grants control-socket access, not edits.

## Files

```
packaging/nixos/
├── default.nix   # NixOS module (services.fips.*)
└── README.md     # this file
```

The flake also exposes:

- `overlays.default` — adds `pkgs.fips` (optional convenience; the
  module does not need it)
- `nixosModules.default` — the NixOS module, with its package default
  wired to the flake's own build
