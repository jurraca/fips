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
| `services.fips.configFile` | path | shipped default | Default `fips.yaml` used to seed `/etc/fips/fips.yaml` on first run |
| `services.fips.openFirewall` | bool | `true` | Open UDP 2121 + TCP 8443 |
| `services.fips.firewall.enable` | bool | `false` | Load the `fips0` mesh-interface nftables baseline (`fips-firewall.service`) |
| `services.fips.firewall.extraRules` | lines | `""` | nftables rule lines included in the baseline's inbound chain |
| `services.fips.dns.enable` | bool | `true` | Route `.fips` queries to the fips DNS responder via a systemd-resolved drop-in |
| `services.fips.gateway.enable` | bool | `false` | Enable the outbound LAN gateway (`fips-gateway.service`) |

## What it does

- Puts the `fips`, `fipsctl`, `fipstop`, and `fips-gateway` binaries on `PATH`
- Creates a `fips` group for control-socket access (add your user for
  non-sudo `fipsctl`/`fipstop`); it does not grant edit rights on
  `/etc/fips`
- Seeds `/etc/fips/fips.yaml` and `/etc/fips/hosts` from the shipped
  defaults on first run only — operator edits are never clobbered
- Runs `fips` as a systemd service (`fips.service`) as `root:fips`
  (root is required for TUN interfaces and raw sockets)
- Routes `.fips` DNS queries to the fips responder on `[::1]:5354` via a
  systemd-resolved drop-in (enabled by default; disable with
  `services.fips.dns.enable = false`)
- Optionally loads the `fips0` mesh-interface nftables baseline
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
and any ACL or allowlist keyed to the old npub stops matching. For a
long-lived NixOS mesh node, edit `/etc/fips/fips.yaml`:

```yaml
node:
  identity:
    persistent: true
```

The keypair is then written to `/etc/fips/fips.key` (mode 0600) and
`/etc/fips/fips.pub` next to the config, surviving restarts and
rebuilds. This matches the Debian/AUR packaging default; the module
does not diverge from the shipped config.

### 2. State lives in /etc/fips — breaking change from earlier revisions

Earlier revisions of this module kept `fips.yaml` and the identity keys
in `/var/lib/fips/`. Everything now lives in `/etc/fips/`, matching the
daemon's Linux system-config directory and the Debian layout. There is
**no automatic migration**: upgrading a host that ran the old layout
without moving these files re-seeds the config and — with
`persistent: true` — gives the node a **new identity that peers
allowlisting the old npub will refuse**. Before upgrading, copy the
state across:

```sh
sudo systemctl stop fips
sudo cp -a /var/lib/fips/fips.yaml /etc/fips/
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

### 5. The config is imperative after the first seed

`services.fips.configFile` only matters on the first start: it seeds
`/etc/fips/fips.yaml` and is never consulted again. Rebuilds do not
touch the file. Changes to the daemon's configuration happen by
editing `/etc/fips/fips.yaml` and restarting the service — not through
NixOS options. This is the hybrid seed-once pattern: declarative
defaults, operator-owned runtime state.

### 6. The `fips` group is for the control socket, not file edits

Group membership lets a user run `fipsctl`/`fipstop` without sudo (the
daemon's control socket is group-reachable in `/run/fips/`) and read
the config (`fips.yaml` is `0640 root:fips`). It does **not** allow
editing anything under `/etc/fips` — files are root-owned and editing
requires sudo, matching the Debian/AUR posture. The config drives a
root daemon (TUN devices, raw sockets, and — with the gateway —
nftables), so write access to it is admin-equivalent and is not handed
out with the group.

## Config file layout (hybrid pattern)

| Path | Purpose | Owner:mode | Seeded from |
|---|---|---|---|
| `/etc/fips/fips.yaml` | Main config | `root:fips` 0640 | `services.fips.configFile` (first run only) |
| `/etc/fips/fips.key` | Node identity (private) | `root:fips` 0600 | generated by fips on first start with `persistent: true` |
| `/etc/fips/fips.pub` | Node identity (public) | `root:fips` 0644 | written by fips on every start |
| `/etc/fips/hosts` | Static hostname → npub map | `root:root` 0644 | shipped `hosts` (first run only) |
| `/etc/fips/peers.allow` | Peer allowlist (ACL) | operator-chosen | operator-created |
| `/etc/fips/peers.deny` | Peer denylist (ACL) | operator-chosen | operator-created |
| `/etc/fips/fips.d/extra.nft` | nftables drop-in rules | store symlink | `services.fips.firewall.extraRules` |
| `/etc/fips/fips.d/*.nft` | additional operator drop-ins | operator-chosen | operator-created |

Everything lives under `/etc/fips/` because that is the daemon's
system config directory on Linux: identity key paths are derived from
the config file's parent directory, and the hosts/ACL paths are
hardcoded (`DEFAULT_HOSTS_PATH`, `DEFAULT_PEERS_ALLOW_PATH`,
`DEFAULT_PEERS_DENY_PATH`). All files are root-owned; the operator
edits them as root.

The `fips.nft` baseline itself is **not** copied to `/etc/fips/` —
unlike the Debian layout — but loaded from the package
(`$out/share/fips/fips.nft`), so package upgrades bring security fixes
to the baseline. Only the drop-in rules are operator-owned.

### Why not `environment.etc`?

NixOS `environment.etc` creates symlinks into the read-only Nix store.
That makes files immutable at runtime and would clobber operator edits
on every rebuild. The module therefore seeds real writable files via a
`preStart` script that only runs when the target file is absent. The
one exception is `fips.d/extra.nft`: it is deliberately declarative
(`services.fips.firewall.extraRules`), so a store symlink is exactly
right there. Operators who want extra drop-in files can still create
additional `*.nft` files in the writable `/etc/fips/fips.d/` directory.

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

### Editing config at runtime

```sh
sudo nano /etc/fips/fips.yaml    # edit main config
sudo nano /etc/fips/hosts         # add static hostname mappings
sudo nano /etc/fips/peers.allow  # add peers to the allowlist
sudo systemctl restart fips       # apply changes
```

Files are root-owned (`fips.yaml` is `0640 root:fips`, `hosts` is
`0644 root:root`); editing requires sudo. The `fips` group grants
control-socket access and config read, not edits.

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
