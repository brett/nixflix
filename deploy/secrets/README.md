# Nixflix Secrets

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix) using [age](https://age-encryption.org/) keys.
Encrypted secret files are committed to the repository. The private key is never committed.

## Secret Files

| File | Contents |
|------|----------|
| `mullvad.yaml` | Mullvad VPN account number |
| `arr.yaml` | API keys for Sonarr, Radarr, Prowlarr, Lidarr |
| `admin.yaml` | Admin passwords for Jellyfin, Jellyseerr, SABnzbd |
| `local.yaml` | SSH keys, domain, ACME email, disk device, server IP |

## Key Structure

`.sops.yaml` contains the encryption rules. It is **git-ignored** — create it locally
before encrypting or editing secrets. A minimal example:

```yaml
keys:
  - &operator-age age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

creation_rules:
  - path_regex: deploy/secrets/.*\.yaml$
    key_groups:
      - age:
          - *operator-age
```

The age private key is injected to `/var/lib/sops-nix/key.txt` on the target server by
the deploy script, so the server uses the same operator key to decrypt secrets at boot.

## Generating a New Age Key

```bash
# Generate a new age keypair (default path expected by deploy.sh)
age-keygen -o ~/.config/sops/age/keys.txt

# The public key is printed to stdout — add it to .sops.yaml under keys:
```

The deploy script reads the private key from `~/.config/sops/age/keys.txt` by default
(override with `--age-key`). Keep this file private and never commit it.

## Re-encrypting Secrets

After adding a new recipient key to `.sops.yaml`, re-encrypt all secrets:

```bash
# Update a single file
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys deploy/secrets/mullvad.yaml

# Update all secret files at once
for f in deploy/secrets/*.yaml; do
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys "$f"
done
```

## Editing Secrets

```bash
# Edit a secrets file (decrypts in-memory, re-encrypts on save)
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/mullvad.yaml
```

## Replacing Placeholder Values

The files in this directory contain placeholder (zeroed-out) values. Before deploying:

1. Edit each file with `sops` and replace placeholders with real values.
2. Add your production host's age public key (from `/etc/ssh/ssh_host_ed25519_key.pub`
   via `ssh-to-age`) to `.sops.yaml` under `prod-age`.
3. Run `sops updatekeys` on all files to include the production key.

### Getting an age key from an SSH host key

```bash
# On the target host (or using the public key)
nix shell nixpkgs#ssh-to-age --command \
  ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

## Local Configuration

`deploy/local.nix` is tracked in git with placeholder values. To generate it with real values,
run:

```bash
./deploy/scripts/init-local.sh
```

The script decrypts `local.yaml` and overwrites `deploy/local.nix` with the real values. It
also runs `git update-index --skip-worktree deploy/local.nix` so git ignores the local changes
and they are never accidentally committed.

To update values: edit `local.yaml` with sops, then re-run `init-local.sh`:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops deploy/secrets/local.yaml
./deploy/scripts/init-local.sh
```

## NixOS Configuration

In your NixOS flake that imports nixflix, enable sops-nix and wire up secrets:

```nix
{
  inputs.nixflix.url = "github:your-org/nixflix";
  inputs.sops-nix.url = "github:Mic92/sops-nix";

  outputs = { nixpkgs, nixflix, sops-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        sops-nix.nixosModules.sops
        nixflix.nixosModules.nixflix
        {
          sops.defaultSopsFile = ./deploy/secrets/mullvad.yaml;
          sops.age.keyFile = "/root/.config/sops/age/keys.txt";

          sops.secrets.account_number = {};

          nixflix.mullvad = {
            enable = true;
            accountNumber._secret = config.sops.secrets.account_number.path;
          };
        }
      ];
    };
  };
}
```
