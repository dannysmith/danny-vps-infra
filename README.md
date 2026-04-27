# danny-vps-infra

Infrastructure for a single Hetzner VPS that hosts several personal Docker-based services behind one shared [Caddy](https://caddyserver.com/) reverse proxy. Caddy terminates TLS (via Let's Encrypt) and routes each hostname to the right container over a shared Docker network called `caddy-net`. Each service lives in its own repo in `~/` with its own `docker-compose.yml`. Adding a new service means joining the service's container to `caddy-net`, adding a block to the Caddyfile here, and pointing a DNS subdomain at the VPS as needed. Persistent state lives on a Hetzner Storage Volume mounted at `/mnt/data`, whose data survives VPS destruction and can be moved to a bigger box later if needed.

**This repo is the cannonical source for the Caddy stack deployed to the server.** It is cloned into `~/` on the server.

It also contains:

- This README with instructions for:
  - Adding new services to the VPS & caddy stack.
  - Bootstrap an new VPS.
- One-time scripts to help with bootstrapping new VPS (`setup.sh` & `configure-bash.sh`).

## Currently Deployed Services

- `server.danny.is` - Simple test endpoint
- `v.danny.is` - Reverse Proxied to `loom-clone` container
- `origin.v.danny.is` - Reverse Proxied to `loom-clone` container


## Adding a new service

Each service should live in its own GitHub repo and contain its own `docker-compose.yml`. To add a service to the VPS:

1. Create an A record for `<subdomain>.danny.is` → VPS IP.
2. Ensure the service is dockerised and add or update its `docker-compose.yml` to:
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
3. SSH into the server and clone the new services repo into `~/`, then start it with an appropriate `docker compose up` command. 
4. Add a suitable block to `caddy/Caddyfile` in this repo:
   ```
   v.danny.is {
       reverse_proxy loom-clone-server:3000
   }
   ```
5. SSH into the VPS and run:
   ```sh
   cd ~/danny-vps-infra/caddy
   git pull
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
   (Or `docker compose restart caddy` if you prefer.)

Persistent data for the service should live under `/mnt/data/<service-name>/` and be bind-mounted into the container.

## Setting up a new box

1. **Provision a new Ubuntu server** in Hetzner Cloud and add suitable SSH keys.

2. **Create a Storage Volume** (same location as the server, attach to it). **Don't** tick "Automatically mount and format" — `setup.sh` handles both.

3. **Create an A record** on DNSimple (eg. `server.danny.is`) pointing at the server's IPv4 address.

4. **SSH in as root** and bootstrap. Keep this session open until the next step passes.
   ```sh
   ssh root@<vps-ip>

   # find the volume path — use the `scsi-0HC_...` one (not `scsi-SHC_...`)
   ls -l /dev/disk/by-id/ | grep HC_Volume

   apt-get update && apt-get install -y git
   git clone https://github.com/dannysmith/danny-vps-infra.git /root/danny-vps-infra
   cd /root/danny-vps-infra
   VOLUME_DEVICE=/dev/disk/by-id/scsi-0HC_Volume_<id> VOLUME_FORMAT=1 ./setup.sh
   ```
   `VOLUME_FORMAT=1` is only needed on the first run (fresh volume). The script is idempotent; re-runs are safe.

5. **Before closing the root session**, open a second terminal and verify `danny` SSH + sudo + docker all work:
   ```sh
   ssh danny@<vps-ip>
   sudo whoami        # prints 'root', no prompt
   docker ps          # works (empty list is fine)
   ```
   `setup.sh` has already disabled root SSH for new connections — if any of the above fails, fix it from the still-open root session. Once the above passes, close the root SSH session.

6. In your SSH session as `danny`, **start Caddy** as `danny`:
   ```sh
   git clone https://github.com/<your-user>/danny-vps-infra.git ~/danny-vps-infra
   cd ~/danny-vps-infra/caddy
   docker compose up -d
   docker compose logs -f caddy      # wait for 'certificate obtained successfully'
   ```

7. Verify from your local machine: `curl https://server.danny.is` → `Hello from danny-vps-infra`. Check the padlock in a browser too.


## What's on the box after running setup?

|           |                                                  |
| --------- | ------------------------------------------------ |
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
| Tools     | `gh`, `bun`, `claude`                            |

## Files in this repo

- `setup.sh` — one-time VPS bootstrap. Idempotent.
- `configure-bash.sh` — configures bash environment for `danny` (git prompt, Ghostty TERM, history). Called by `setup.sh`.
- `caddy/docker-compose.yml` — Caddy service definition.
- `caddy/Caddyfile` — Caddy config (add a block per service).

## DNS requirements

| Record                   | Target               |
| ------------------------ | -------------------- |
| `server.danny.is` A      | VPS IP               |
| `<subdomain>.danny.is` A | VPS IP (per service) |
