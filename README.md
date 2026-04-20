# danny-vps-infra

Infrastructure for a single Hetzner VPS that hosts several personal Docker-based services behind one shared [Caddy](https://caddyserver.com/) reverse proxy. Caddy terminates TLS (via Let's Encrypt — fully automatic) and routes each hostname to the right container over a shared Docker network called `caddy-net`.

Each service lives in its own repo with its own `docker-compose.yml`. Adding one means joining the service's container to `caddy-net`, adding a block to the Caddyfile here, and pointing DNS at the VPS. Persistent state lives on a Hetzner Storage Volume mounted at `/mnt/data`, so it survives VPS destruction and can be moved to a bigger box later.

This repo contains the one-time VPS bootstrap (`setup.sh`) and the Caddy stack (`caddy/`).

## Currently Deployed Services

See the Caddyfile for an authoritative list

- `server.danny.is` - Simple test endpoint
- `v.danny.is` - Reverse Proxied to `loom-clone` container

## Setting up a new box

1. **Push this repo to GitHub** (public — nothing sensitive lives here).

2. **Upload your SSH key to Hetzner** (Cloud Console → Security → SSH Keys).

3. **Provision the server** in Hetzner Cloud:
   - Type: **CX33** (4 vCPU, 8 GB RAM, 80 GB NVMe)
   - Location: Falkenstein
   - Image: Ubuntu 24.04
   - SSH Keys: tick the one from step 2

4. **Create a Storage Volume** (same location as the server, attach to it). **Don't** tick "Automatically mount and format" — `setup.sh` handles both.

5. **Create an A record** on DNSimple: `server.danny.is` → VPS IPv4. Set TTL low while you iterate. Wait for propagation (`dig +short server.danny.is` from your local machine returns the IP).

6. **SSH in as root** and bootstrap. Keep this session open until step 7 passes.
   ```sh
   ssh root@<vps-ip>

   # find the volume path — use the `scsi-0HC_...` one (not `scsi-SHC_...`)
   ls -l /dev/disk/by-id/ | grep HC_Volume

   apt-get update && apt-get install -y git
   git clone https://github.com/<your-user>/danny-vps-infra.git /root/danny-vps-infra
   cd /root/danny-vps-infra
   VOLUME_DEVICE=/dev/disk/by-id/scsi-0HC_Volume_<id> VOLUME_FORMAT=1 ./setup.sh
   ```
   `VOLUME_FORMAT=1` is only needed on the first run (fresh volume). The script is idempotent; re-runs are safe.

7. **Before closing the root session**, open a second terminal and verify `danny` SSH + sudo + docker all work:
   ```sh
   ssh danny@<vps-ip>
   sudo whoami        # prints 'root', no prompt
   docker ps          # works (empty list is fine)
   ```
   `setup.sh` has already disabled root SSH for new connections — if any of the above fails, fix it from the still-open root session. Once the above passes, close root.

8. **Start Caddy** as `danny`:
   ```sh
   git clone https://github.com/<your-user>/danny-vps-infra.git ~/danny-vps-infra
   cd ~/danny-vps-infra/caddy
   docker compose up -d
   docker compose logs -f caddy      # wait for 'certificate obtained successfully'
   ```

9. **Verify from your local machine**: `curl https://server.danny.is` → `Hello from danny-vps-infra`. Check the padlock in a browser too.

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

|           |                                                  |
| --------- | ------------------------------------------------ |
| Host      | Hetzner CX33, Falkenstein                        |
| OS        | Ubuntu 24.04 LTS                                 |
| User      | `danny` (sudo, passwordless, SSH key from root)  |
| Firewall  | UFW — 22/tcp, 80/tcp, 443/tcp+udp open           |
| Intrusion | fail2ban (SSH jail)                              |
| Updates   | unattended-upgrades (security patches automatic) |
| Docker    | Engine + Compose plugin, log rotation 10m×3      |
| Network   | `caddy-net` (shared, external)                   |
| Storage   | `/mnt/data` (Hetzner Volume, ext4)               |
| Kernel    | UDP buffers raised to 7.5 MB for Caddy HTTP/3    |
| Cron      | Weekly Docker prune (Sundays 04:00 UTC)          |
| Tools     | `gh`, `bun`, `claude` (Claude Code)              |

## Files

- `setup.sh` — one-time VPS bootstrap. Idempotent.
- `configure-bash.sh` — bash environment for `danny` (git prompt, Ghostty TERM, history). Called by `setup.sh`.
- `caddy/docker-compose.yml` — Caddy service definition.
- `caddy/Caddyfile` — Caddy config (add a block per service).

## DNS requirements

| Record                   | Target               |
| ------------------------ | -------------------- |
| `server.danny.is` A      | VPS IP               |
| `<subdomain>.danny.is` A | VPS IP (per service) |
