# Nixflix Deploy Cheatsheet

Full guide: `docs/hetzner-deploy.md`

---

## One-time setup

```bash
# Generate age key (keep private key safe)
age-keygen -o ~/.config/sops/age/keys.txt
# Public key is printed to stdout — add it to .sops.yaml

# Encrypt secrets
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/mullvad.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/arr.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/admin.yaml
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/local.yaml

# Generate deploy/local.nix from local.yaml
./deploy/scripts/init-local.sh
```

---

## Fresh deploy

```bash
# Hetzner Robot (microVM — recommended for production)
# 1. Enable rescue mode in Robot web UI, reboot server
# 2. Run deploy
nix run .#deploy -- <server-ip> -c hetzner-bare-microvm

# Hetzner Cloud (bare)
HETZNER_CLOUD_TOKEN=<token> nix run .#deploy -- <server-ip>

# Custom age key path
nix run .#deploy -- <server-ip> -c hetzner-bare-microvm --age-key ~/.config/sops/age/keys.txt
```

> **Robot only:** disable rescue mode in the web UI while the deploy is running,
> before the server reboots at the end.

If you see an SSH host key warning after deploy:
```bash
ssh-keygen -R <server-ip>
```

---

## Incremental rebuild

```bash
# Push a config change without reinstalling
nix run .#rebuild -- hetzner-bare-microvm <server-ip>

# Always restart Mullvad after rebuild — nftables reload clears its ip rules
ssh root@<server-ip> systemctl restart mullvad-daemon.service
```

---

## Status

```bash
nix run .#status -- <server-ip>
```

---

## Integration tests

```bash
bash deploy/tests/integration-microvm.sh <server-ip>
```

---

## Edit secrets

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/<file>.yaml

# After editing local.yaml, regenerate local.nix
./deploy/scripts/init-local.sh
```

| File | Contents |
|------|----------|
| `mullvad.yaml` | `account_number` |
| `arr.yaml` | arr API keys, `arr_admin_password` |
| `admin.yaml` | `jellyfin_admin_password`, `jellyseerr_admin_password`, `sabnzbd_api_key`, `qbittorrent_password` |
| `local.yaml` | SSH keys, domain, ACME email, disk device, server IP |

---

## Troubleshooting

```bash
# Mullvad not routing after rebuild
ssh root@<server-ip> systemctl restart mullvad-daemon.service
ssh root@<server-ip> mullvad status

# Mullvad too many devices
# Revoke old device at mullvad.net/account/devices, then:
ssh root@<server-ip> systemctl restart mullvad-config.service

# Arr service returns 500 after fresh deploy
# Postgres migration can take up to 10 min on first boot — wait it out

# Check a microVM's services
ssh root@<server-ip> systemctl status "microvm@sonarr.service"
ssh root@<server-ip> journalctl -u sonarr.service -n 50

# ZFS pool degraded
ssh root@<server-ip> zpool status -v rpool

# Secrets not decrypting at boot
ssh root@<server-ip> ls -la /var/lib/sops-nix/key.txt
ssh root@<server-ip> journalctl -u sops-nix.service
```
