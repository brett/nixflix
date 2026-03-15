---
title: Hetzner Deployment
---

# Deploying Nixflix on Hetzner

This guide covers the end-to-end workflow for deploying a Nixflix media server to a
Hetzner bare-metal or cloud server using
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere).

The target configuration (`hetzner-bare`) sets up the full Nixflix stack
(Prowlarr, Sonarr, Radarr, Lidarr, qBittorrent, Mullvad VPN) with nginx, ZFS,
and secrets managed by sops-nix.

---

## Prerequisites

### Tools

Install the following tools before proceeding:

=== "NixOS / nix-shell"

    ```bash
    nix shell nixpkgs#hcloud nixpkgs#age nixpkgs#sops nixpkgs#ssh-to-age
    ```

=== "System packages"

    | Tool | Purpose |
    |------|---------|
    | [hcloud CLI](https://github.com/hetznercloud/cli) | Provision and manage Hetzner Cloud servers |
    | [age](https://github.com/FiloSottile/age) | Encryption for secrets at rest |
    | [sops](https://github.com/getsops/sops) | Secret management (wraps age) |
    | [ssh-to-age](https://github.com/Mic92/ssh-to-age) | Derive an age key from an SSH host key |
    | [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) | Remote NixOS installation |

### Nix with flakes

Flakes must be enabled:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

### Hetzner API token

Create an API token in the [Hetzner Cloud Console](https://console.hetzner.cloud/) and
export it:

```bash
export HCLOUD_TOKEN="your-api-token"
```

---

## Step 1 — Generate the age key

Secrets in `deploy/secrets/` are encrypted with an age key. The deploy script injects
this key onto the server at install time so the server can decrypt secrets at boot.
A single operator key is used for both local management and the deployed server.

### Generate a new key

```bash
age-keygen -o ~/.config/sops/age/keys.txt
# Public key: age1... (printed to stdout — copy it)
```

The private key file is git-ignored. Store it safely.

### Register the public key in `.sops.yaml`

Create `.sops.yaml` at the repository root (this file is git-ignored — do not commit it):

```yaml
keys:
  - &operator-age age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

creation_rules:
  - path_regex: deploy/secrets/.*\.yaml$
    key_groups:
      - age:
          - *operator-age
```

The deploy script copies your age private key to `/var/lib/sops-nix/key.txt` on the
target host at install time, so the server uses the same key to decrypt secrets at boot.
No separate host key derivation step is required.

---

## Step 2 — Encrypt secrets

The files under `deploy/secrets/` contain placeholder values. Replace them with real
credentials before deploying.

### Edit a secrets file

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops deploy/secrets/mullvad.yaml
```

This decrypts the file in-memory, opens your `$EDITOR`, and re-encrypts on save.

| File | Keys |
|------|------|
| `deploy/secrets/mullvad.yaml` | `account_number` — Mullvad VPN account number |
| `deploy/secrets/arr.yaml` | `prowlarr_api_key`, `sonarr_api_key`, `sonarr_anime_api_key`, `radarr_api_key`, `lidarr_api_key` |
| `deploy/secrets/admin.yaml` | `jellyfin_admin_password`, `jellyseerr_admin_password`, `sabnzbd_api_key` |
| `deploy/secrets/local.yaml` | SSH keys, domain, ACME email, disk device, server IP |

### Populate local configuration

SSH keys, domain, ACME email, disk device, and server IP are stored in `deploy/secrets/local.yaml`
(sops-encrypted). Run the init script to decrypt it and generate `deploy/local.nix`:

```bash
./deploy/scripts/init-local.sh
```

The script also runs `git update-index --skip-worktree deploy/local.nix` so the generated file
with real values is never accidentally committed.

To update any of these values, edit `local.yaml` with sops, then re-run `init-local.sh`:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/local.yaml
./deploy/scripts/init-local.sh
```

### Add a wildcard DNS record

Before deploying, add a wildcard A record pointing to your server IP. Each arr service
is reachable at its own subdomain (e.g. `sonarr.media.example.com`). Let's Encrypt
requires all subdomains to resolve for the HTTP-01 challenge.

```
*.media.example.com.  300  IN  A  <server-ip>
```

Without this record, ACME cert issuance will fail and nginx will serve self-signed certs.

---

## Step 3 — Provision a server

### Create a Hetzner Cloud server

```bash
hcloud server create \
  --name nixflix \
  --type cx22 \
  --location fsn1 \
  --image debian-12
```

!!! note
    nixos-anywhere installs NixOS over the existing OS via SSH — the initial image
    only needs to be reachable over SSH. Any Debian/Ubuntu image works.

Record the server IP:

```bash
hcloud server list
```

### Enable rescue mode

Hetzner Cloud VMs must be in **rescue mode** for nixos-anywhere to install NixOS.
The deploy script will automatically disable rescue mode after installation if you
provide an API token (recommended). To enable it:

```bash
hcloud server enable-rescue nixflix --type linux64
hcloud server reboot nixflix
```

Or use the [Hetzner Cloud Console](https://console.hetzner.cloud/).

### Verify SSH access

```bash
ssh root@<server-ip> echo "ok"
```

---

## Step 4 — Run the deploy script

```bash
# With automatic rescue-mode disable (recommended):
HETZNER_CLOUD_TOKEN=<your-api-token> ./deploy/scripts/deploy.sh <server-ip>

# Without API token (you must manually disable rescue mode before rebooting):
./deploy/scripts/deploy.sh <server-ip>
```

The script:

1. Injects your age key to `/var/lib/sops-nix/key.txt` on the target via `nixos-anywhere --extra-files`
2. Partitions the disk with disko (BIOS/GRUB + ZFS layout below)
3. Installs NixOS with the `hetzner-bare` configuration
4. If a Hetzner Cloud API token is set: disables rescue mode via the API, then reboots
5. Otherwise: exits after install — reboot manually after disabling rescue mode
6. Waits for the server to come back online after reboot
7. Waits for Let's Encrypt to issue TLS certificates, then reloads nginx

### ZFS layout

| Dataset | Mount point | Purpose |
|---------|-------------|---------|
| `rpool/nixos/nixflix` | `/var/lib/nixflix` | Nixflix service state (snapshotable) |
| `rpool/data/media` | `/data/media` | Media files |
| `rpool/data/downloads` | `/data/downloads` | Download scratch space |

### Age key on the server

The deploy script copies your local age private key (`~/.config/sops/age/keys.txt` by
default) to `/var/lib/sops-nix/key.txt` on the server. sops-nix reads this file at boot
to decrypt secrets. No separate host-key derivation step is needed — the server uses
the same operator key that encrypted the secrets.

To use a different age key path:

```bash
HETZNER_CLOUD_TOKEN=<token> ./deploy/scripts/deploy.sh <server-ip> \
  --age-key ~/.config/sops/age/keys.txt
```

---

## Step 5 — Incremental updates

After the initial deploy, push configuration changes without a full reinstall:

```bash
nix run .#rebuild -- hetzner-bare-microvm <server-ip>
```

This builds the new config locally, copies it to the server, and activates it in-place.
No reboot required unless the kernel changes.

For a quick health overview after deploying:

```bash
nix run .#status -- <server-ip>
```

---

## Step 6 — Run integration tests

After a successful deploy, verify the stack end-to-end:

```bash
bash deploy/tests/integration-microvm.sh <server-ip>
```

The script runs 121 checks across these categories:

- Host services and microVM services are active with no crash loops
- VPN routing and Mullvad kill switch
- Arr API health endpoints
- ZFS pool health
- Postgres firewall rules
- qBittorrent connectivity

The script exits non-zero on any failure. Review the output for details.

---

## Step 7 — Tear down

To destroy the server when you are done testing:

```bash
hcloud server delete nixflix
```

!!! warning
    This permanently deletes the server and all data on it. Take ZFS snapshots or
    export media data before tearing down if you want to preserve state.

---

## Troubleshooting

### nixos-anywhere failures

**Deploy fails on the stock image**

Hetzner Cloud VMs must be in rescue mode for nixos-anywhere to install. If you
see SSH failures or kexec errors, make sure the server is in rescue mode:

```bash
hcloud server enable-rescue nixflix --type linux64
hcloud server reboot nixflix
```

Then re-run the deploy script.

**SSH host key changes after install**

nixos-anywhere replaces the OS, so the host key changes. Remove the stale entry:

```bash
ssh-keygen -R <server-ip>
```

**Secrets not decrypting at boot**

The server reads its age key from `/var/lib/sops-nix/key.txt`. Check that the file
exists and that the corresponding public key is a recipient in `.sops.yaml`:

```bash
# On the server
ls -la /var/lib/sops-nix/key.txt
journalctl -u sops-nix.service
```

If the file is missing, re-run the deploy script (it injects the key via `--extra-files`).
If the key exists but sops logs `age: no identity matched`, the public key in `.sops.yaml`
does not match the private key on the server — re-encrypt secrets with the correct key.

---

### ZFS issues

**`zpool status` shows DEGRADED or FAULTED**

```bash
# On the server
zpool status -v rpool
zpool scrub rpool          # Queue a scrub to check data integrity
journalctl -k | grep zfs   # Kernel messages
```

**Dataset not mounted at boot**

Nixflix requires the ZFS datasets to be mounted before services start. Check:

```bash
systemctl status zfs-mount.service
zfs list
```

If a dataset is missing, create it and mount it:

```bash
zfs create -o mountpoint=/var/lib/nixflix rpool/nixos/nixflix
zfs create -o mountpoint=/data/media rpool/data/media
zfs create -o mountpoint=/data/downloads rpool/data/downloads
```

Then restart the Nixflix services:

```bash
systemctl restart nixflix.service
```

**ZFS encryption passphrase prompt at boot**

`boot.zfs.requestEncryptionCredentials` is `false` in the base config, so encrypted
datasets will not prompt at boot by default. If you enable ZFS native encryption and
set this to `true`, the server will require a passphrase on boot. For headless
deployments, either leave encryption off or use a keyfile stored on a separate volume.

---

### Service startup issues

**Arr service fails to start**

Check that the sops secret path is correct and the file exists:

```bash
ls -la /run/secrets/
journalctl -u sonarr.service -n 50
```

**Mullvad not connecting**

```bash
mullvad status
mullvad account get          # Verify the account number was applied
journalctl -u mullvad-daemon -n 50
```

**SSH or nginx unreachable after Mullvad connects**

Mullvad routes all traffic through the VPN tunnel by default. The `bypassPorts` option
punches exceptions for specific TCP ports so they exit via the server's physical interface.
Ensure `bypassPorts` includes all ports that must remain reachable on the public IP:

```nix
mullvad.bypassPorts = [ 22 80 443 ];
```

A persistent ip rule (`mullvad-bypass-route.service`) is installed alongside the nftables
bypass chains to ensure the bypass routing survives Mullvad relay rotations. Check its
status if connectivity is lost after Mullvad reconnects:

```bash
systemctl status mullvad-bypass-route.service
ip rule show   # should include: 50: from all fwmark 0x6d6f6c65 lookup main
```

After an incremental deploy (`switch-to-configuration`), nftables reloads and previously
this would clear Mullvad's ip rules, breaking DNS. This is now fixed automatically:
`mullvad-daemon` restarts after every nftables reload via
`systemd.services.mullvad-daemon.restartTriggers`. If the issue persists unexpectedly:

```bash
systemctl restart mullvad-daemon.service
```

**Port not responding**

Check the firewall and that the service is listening:

```bash
systemctl status sonarr.service
ss -tlnp | grep 8989
nft list ruleset | grep 8989
```
