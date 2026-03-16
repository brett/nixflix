---
title: Hetzner Deployment
---

# Deploying Nixflix on Hetzner

This guide covers deploying Nixflix to Hetzner using
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere).

Two target types are supported:

| Target | Config | Server type | Isolation |
|--------|--------|-------------|-----------|
| **Bare** | `hetzner-bare` | Cloud VPS or Robot dedicated | All services on the host |
| **MicroVM** | `hetzner-bare-microvm` | Robot dedicated (recommended) | Each service in its own microVM |

The microVM target is recommended for production. The bare target is simpler and useful
for testing or lower-resource servers.

---

## Prerequisites

### Tools

=== "NixOS / nix-shell"

    ```bash
    nix shell nixpkgs#age nixpkgs#sops nixpkgs#ssh-to-age
    # For Hetzner Cloud servers only:
    nix shell nixpkgs#hcloud
    ```

=== "System packages"

    | Tool | Purpose |
    |------|---------|
    | [age](https://github.com/FiloSottile/age) | Encryption for secrets at rest |
    | [sops](https://github.com/getsops/sops) | Secret management (wraps age) |
    | [ssh-to-age](https://github.com/Mic92/ssh-to-age) | Derive an age key from an SSH host key (optional — only needed if using the server's SSH host key as the age key) |
    | [hcloud CLI](https://github.com/hetznercloud/cli) | Hetzner Cloud servers only |

nixos-anywhere is invoked via `nix run` and does not need to be installed separately.

### Nix with flakes

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

### Hetzner Cloud API token (Cloud only)

Create an API token in the [Hetzner Cloud Console](https://console.hetzner.cloud/) and export it:

```bash
export HETZNER_CLOUD_TOKEN="your-api-token"
```

---

## Step 1 — Generate the age key

Secrets are encrypted with an age key. The deploy script injects this key onto the server
at install time so it can decrypt secrets at boot.

```bash
age-keygen -o ~/.config/sops/age/keys.txt
# Public key: age1... (printed to stdout — copy it)
```

Register the public key in `.sops.yaml` at the repo root (git-ignored — do not commit):

```yaml
keys:
  - &operator-age age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

creation_rules:
  - path_regex: deploy/secrets/.*\.yaml$
    key_groups:
      - age:
          - *operator-age
```

---

## Step 2 — Encrypt secrets

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops deploy/secrets/mullvad.yaml
```

| File | Keys |
|------|------|
| `deploy/secrets/mullvad.yaml` | `account_number` — Mullvad VPN account number |
| `deploy/secrets/arr.yaml` | `prowlarr_api_key`, `sonarr_api_key`, `sonarr_anime_api_key`, `radarr_api_key`, `lidarr_api_key` |
| `deploy/secrets/admin.yaml` | `arr_admin_password`, `sabnzbd_api_key`, `qbittorrent_password` |
| `deploy/secrets/local.yaml` | SSH keys, domain, ACME email, disk device, server IP |

### Populate local configuration

Run the init script to decrypt `local.yaml` and generate `deploy/local.nix`:

```bash
./deploy/scripts/init-local.sh
```

This also runs `git update-index --skip-worktree deploy/local.nix` so the file with real
values is never accidentally committed. To update values, edit `local.yaml` with sops and
re-run:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/local.yaml
./deploy/scripts/init-local.sh
```

### Add a wildcard DNS record

Add a wildcard A record pointing to your server IP before deploying. Each service is
reachable at its own subdomain (e.g. `sonarr.media.example.com`).

```
*.media.example.com.  300  IN  A  <server-ip>
```

Without this, ACME cert issuance will fail and nginx will serve self-signed certs.

---

## Step 3 — Provision a server

=== "Hetzner Cloud (bare target)"

    ```bash
    hcloud server create \
      --name nixflix \
      --type cx22 \
      --location fsn1 \
      --image debian-12
    hcloud server list   # note the IP
    ```

    !!! note
        nixos-anywhere installs NixOS over the existing OS via SSH — the initial image
        only needs to be reachable over SSH. Any Debian/Ubuntu image works.

    Enable rescue mode so nixos-anywhere can install:

    ```bash
    hcloud server enable-rescue nixflix --type linux64
    hcloud server reboot nixflix
    ```

    Verify SSH access:

    ```bash
    ssh root@<server-ip> echo "ok"
    ```

=== "Hetzner Robot dedicated (microVM target)"

    Order a dedicated server in the [Hetzner Robot console](https://robot.hetzner.com/).

    Enable rescue mode in the Robot web UI: go to the server → **Reset** tab →
    select **Linux (64 bit)** rescue → **Send** → reboot the server.

    !!! note
        Robot has no API for rescue mode — you must enable and **disable** it manually
        in the web UI. Unlike Cloud, the deploy script cannot automate this step.

    Verify SSH access:

    ```bash
    ssh root@<server-ip> echo "ok"
    ```

---

## Step 4 — Run the deploy

Use `nix run .#deploy` from the repo root. nixos-anywhere is provided by the flake and
does not need to be installed separately.

=== "Hetzner Cloud (bare target)"

    ```bash
    HETZNER_CLOUD_TOKEN=<your-api-token> \
      nix run .#deploy -- <server-ip>
    ```

    With the API token set, the script automatically disables rescue mode and reboots
    after installation. Without it you must disable rescue mode manually before the
    server reboots.

    To skip the automatic rescue disable (e.g. you'll reboot manually):

    ```bash
    nix run .#deploy -- <server-ip>
    ```

=== "Hetzner Robot dedicated (microVM target)"

    ```bash
    nix run .#deploy -- <server-ip> -c hetzner-bare-microvm
    ```

    No API token is needed or used for Robot servers.

    !!! warning
        **Disable rescue mode in the Robot web UI while the deploy is running** — after
        nixos-anywhere finishes installing, the server reboots. If rescue mode is still
        active at that point, it boots back into rescue and the install is lost. You have
        several minutes during the install to log into the Robot web UI and turn it off.

To use a non-default age key path, add `--age-key <path>`:

```bash
nix run .#deploy -- <server-ip> -c hetzner-bare-microvm --age-key ~/.config/sops/age/keys.txt
```

The deploy script:

1. Checks SSH connectivity
2. Detects the primary disk on the rescue console
3. Injects your age key to `/var/lib/sops-nix/key.txt` via `nixos-anywhere --extra-files`
4. Partitions the disk with disko (BIOS/GRUB + ZFS)
5. Installs NixOS with the selected configuration
6. Reboots the server (Cloud only: disables rescue mode via API first)
7. Waits for the server to come back online
8. Waits for ACME certificates, then reloads nginx

### SSH host key change

nixos-anywhere replaces the OS so the host key changes. If you see a warning:

```bash
ssh-keygen -R <server-ip>
```

### ZFS layout

| Dataset | Mount point | Purpose |
|---------|-------------|---------|
| `rpool/local/root` | `/` | Root filesystem |
| `rpool/local/nix` | `/nix` | Nix store |
| `rpool/local/var` | `/var` | Variable data |
| `rpool/safe/home` | `/home` | Home directories |
| `rpool/nixos/nixflix` | `/var/lib/nixflix` | Nixflix service state |
| `rpool/data/media` | `/data/media` | Media files |
| `rpool/data/downloads` | `/data/downloads` | Download scratch space |

---

## Step 5 — Incremental updates

After the initial deploy, push configuration changes without a full reinstall:

=== "MicroVM target"

    ```bash
    nix run .#rebuild -- hetzner-bare-microvm <server-ip>
    ssh root@<server-ip> systemctl restart mullvad-daemon.service
    ```

    !!! warning
        Always restart `mullvad-daemon` after rebuilding. When `switch-to-configuration`
        reloads nftables, Mullvad's ip rules are cleared. The VPN stays "Connected" but
        DNS resolution breaks for all microVMs. Restarting the daemon restores routing
        cleanly.

=== "Bare target"

    ```bash
    nix run .#rebuild -- hetzner-bare <server-ip>
    ```

For a quick health overview:

```bash
nix run .#status -- <server-ip>
```

---

## Step 6 — Run integration tests (microVM target)

```bash
bash deploy/tests/integration-microvm.sh <server-ip>
```

Covers: host services, microVM services, bridge networking, VPN routing, arr API health,
postgres firewall, qBittorrent, ZFS pool health, ACME certificates.

---

## Step 7 — Tear down (Cloud only)

```bash
hcloud server delete nixflix
```

!!! warning
    Permanently deletes the server and all data. Take ZFS snapshots or export data first.

---

## Troubleshooting

### nixos-anywhere failures

**SSH host key warning**

```bash
ssh-keygen -R <server-ip>
```

**Server not in rescue mode**

nixos-anywhere requires rescue mode. For Cloud:

```bash
hcloud server enable-rescue nixflix --type linux64
hcloud server reboot nixflix
```

For Robot: enable rescue in the web UI and reboot from the Reset tab.

**Secrets not decrypting at boot**

```bash
# On the server
ls -la /var/lib/sops-nix/key.txt
journalctl -u sops-nix.service
```

If the key file is missing, re-run the deploy (it injects the key via `--extra-files`).
If the key exists but sops logs `age: no identity matched`, the public key in `.sops.yaml`
doesn't match the private key on the server — re-encrypt secrets with the correct key.

---

### Mullvad VPN

**Not connecting after boot**

```bash
mullvad status
mullvad account get          # verify account number was applied
journalctl -u mullvad-config.service -b
```

**Too many devices on account**

If `mullvad-config.service` logs "too many devices", a device from a prior install is
still registered on the account. Revoke it at
[mullvad.net/account/devices](https://mullvad.net/account/devices), then:

```bash
systemctl restart mullvad-config.service
```

The `nix run .#status` output will surface this warning if detected.

**SSH or nginx unreachable after Mullvad connects**

Mullvad routes all traffic through the VPN by default. Ensure `bypassPorts` includes all
ports that must remain reachable on the public IP:

```nix
nixflix.mullvad.bypassPorts = [ 22 80 443 ];
```

**Lost connectivity after incremental deploy**

nftables reloads during `switch-to-configuration` clear Mullvad's ip rules. Always
restart mullvad-daemon after an incremental deploy:

```bash
systemctl restart mullvad-daemon.service
ip rule show   # should include: fwmark 0x6d6f6c65 lookup main
```

A persistent ip rule (`mullvad-bypass-route.service`) ensures bypass routing survives
Mullvad relay rotations. If connectivity is lost after a relay change:

```bash
systemctl status mullvad-bypass-route.service
```

---

### ZFS issues

**`zpool status` shows DEGRADED or FAULTED**

```bash
zpool status -v rpool
zpool scrub rpool
journalctl -k | grep zfs
```

**Dataset not mounted at boot**

```bash
systemctl status zfs-mount.service
zfs list
```

If a dataset is missing, create it manually:

```bash
zfs create -o mountpoint=/var/lib/nixflix rpool/nixos/nixflix
zfs create -o mountpoint=/data/media rpool/data/media
zfs create -o mountpoint=/data/downloads rpool/data/downloads
```

---

### Service startup issues

**Arr service returns HTTP 500 after fresh install**

Postgres migration can take several minutes on first boot. The arr services will return
500 until migration completes. Wait up to 10 minutes before investigating further.

**Arr service fails to start**

```bash
ls -la /run/secrets/
journalctl -u sonarr.service -n 50
```

**Port not responding**

Check the firewall and that the service is listening:

```bash
systemctl status sonarr.service
ss -tlnp | grep 8989
nft list ruleset | grep 8989
```
