# danny-vps-infra

Personal Hetzner VPS running multiple Docker-based services behind [Caddy](https://caddyserver.com/) (reverse proxy + automatic TLS).

## Architecture

- **One VPS** (Hetzner CX22, Ubuntu 24.04) with a Hetzner Storage Volume mounted at `/mnt/data` for persistent state.
- **One Caddy** container terminating TLS (Let's Encrypt) and reverse-proxying by hostname.
- **N service containers**, each in its own repo with its own `docker-compose.yml`. Every service joins the shared Docker network `caddy-net` so Caddy can route to it by container name.
- **DNS** on DNSimple. Each service gets an A record pointing at the VPS IP. No Cloudflare proxy — Caddy handles TLS directly.

```
                  ┌──────────────────────────────────────┐
  user ──443──▶   │ Caddy (host :80/:443)                │
                  │   server.danny.is → respond "hello"  │
                  │   v.danny.is      → loom-clone:3000  │
                  │   *.danny.is      → …                │
                  └──────────┬───────────────────────────┘
                             │ caddy-net (Docker network)
                  ┌──────────┴───────────┬──────────────┐
                  ▼                      ▼              ▼
              loom-clone              n8n           (future…)
```

## Initial setup (one-time, on a fresh VPS)

1. **Provision** a Hetzner CX22 with Ubuntu 24.04 in Falkenstein. Add your SSH key. Attach a Storage Volume.
2. **Create DNS A record**: `server.danny.is` → VPS IP (on DNSimple).
3. **Copy this repo to the VPS** as root (or clone it):
   ```sh
   scp -r . root@<vps-ip>:/root/danny-vps-infra
   ssh root@<vps-ip>
   cd /root/danny-vps-infra
   ```
4. **Run `setup.sh`** as root. Pass the volume device path so it gets mounted at `/mnt/data`:
   ```sh
   # Find the attached volume path (stable symlink under /dev/disk/by-id/):
   ls -l /dev/disk/by-id/ | grep HC_Volume

   # First run on a fresh volume — formats it as ext4:
   VOLUME_DEVICE=/dev/disk/by-id/scsi-0HC_Volume_<id> VOLUME_FORMAT=1 ./setup.sh

   # Subsequent re-runs (already formatted) — no VOLUME_FORMAT needed:
   VOLUME_DEVICE=/dev/disk/by-id/scsi-0HC_Volume_<id> ./setup.sh
   ```
   The script is idempotent — safe to re-run.
5. **Test SSH as `danny` before closing the root session**:
   ```sh
   ssh danny@<vps-ip>
   ```
6. **Clone this repo as `danny`** and start Caddy:
   ```sh
   git clone git@github.com:<user>/danny-vps-infra.git ~/danny-vps-infra
   cd ~/danny-vps-infra/caddy
   docker compose up -d
   ```
7. **Verify**: `https://server.danny.is` should return `Hello from danny-vps-infra` with a valid Let's Encrypt cert (may take ~30s on first request while Caddy fetches the cert).

## Adding a new service

Each service lives in its own repo with its own `docker-compose.yml`. To add one:

1. **DNS**: create an A record for `<subdomain>.danny.is` → VPS IP.
2. **In the service's `docker-compose.yml`**:
   - Give the service container a stable `container_name` (e.g. `loom-clone-server`).
   - Join it to the external `caddy-net` network.
   - Do **not** expose ports to the host — Caddy reaches it over the Docker network.

   Example:
   ```yaml
   services:
     loom-clone-server:
       image: …
       container_name: loom-clone-server
       restart: unless-stopped
       networks:
         - caddy-net

   networks:
     caddy-net:
       external: true
   ```
3. **Add a block to `caddy/Caddyfile`**:
   ```
   v.danny.is {
       reverse_proxy loom-clone-server:3000
   }
   ```
4. **Reload Caddy** (from `caddy/` on the VPS):
   ```sh
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
   (Or `docker compose restart caddy` if you prefer.)

Persistent data for the service should live under `/mnt/data/<service-name>/` — bind-mount into the container.

## What's on the box

| | |
|---|---|
| OS | Ubuntu 24.04 LTS |
| User | `danny` (sudo, passwordless, SSH key from root) |
| Firewall | UFW — 22/tcp, 80/tcp, 443/tcp+udp open |
| Intrusion | fail2ban (SSH jail) |
| Updates | unattended-upgrades (security patches automatic) |
| Docker | Engine + Compose plugin, log rotation 10m×3 |
| Network | `caddy-net` (shared, external) |
| Storage | `/mnt/data` (Hetzner Volume, ext4) |
| Cron | Weekly Docker prune (Sundays 04:00 UTC) |
| Tools | `gh`, `bun`, `claude` (Claude Code) |

## Files

- `setup.sh` — one-time VPS bootstrap. Idempotent.
- `configure-bash.sh` — bash environment for `danny` (git prompt, Ghostty TERM, history). Called by `setup.sh`.
- `caddy/docker-compose.yml` — Caddy service definition.
- `caddy/Caddyfile` — Caddy config (add a block per service).

## DNS requirements

| Record | Target |
|---|---|
| `server.danny.is` A | VPS IP |
| `<subdomain>.danny.is` A | VPS IP (per service) |
