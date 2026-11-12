# RUNBOOK: MyCow on an Oracle Always Free VPS

Do one phase at a time and check its **Done when** before moving on. Commands marked
**(laptop)** run in PowerShell on Windows; everything else runs on the server over SSH.

Names used below. Replace them with yours everywhere:
- `mycow.co.ke`: the domain you buy; the app lives at `app.mycow.co.ke`
- `203.0.113.10`: the VM's public IP

---

## Phase 0: Domain, Cloudflare, Oracle account
1. Buy the domain (a `.co.ke` from a KENIC registrar, or a `.com`).
2. Create a free Cloudflare account and **Add a site**, then pick the Free plan. At your registrar, replace the nameservers with the two Cloudflare gives you. This can take up to 24 h.
3. Create an Oracle Cloud account at cloud.oracle.com. Pick a **home region** close to Kenya with ARM capacity, e.g. *Johannesburg* or *Jeddah*. It can't be changed later.
4. In Oracle: **Billing → Upgrade to Pay As You Go**. Staying inside the Always Free limits still costs nothing, and it stops Oracle reclaiming "idle" free VMs.

**Done when** Cloudflare shows the site as *Active*, and you can log in to the Oracle console.

## Phase 1: Create the VM
1. Oracle console → Compute → Instances → **Create instance**:
   - Image: **Canonical Ubuntu 24.04**
   - Shape: **Ampere → VM.Standard.A1.Flex**, 2 OCPU, 12 GB memory
   - Networking: create a new VCN with a public subnet, and assign a public IPv4
   - SSH keys: upload your public key. **(laptop)** If you don't have one: `ssh-keygen -t ed25519`, then upload `~\.ssh\id_ed25519.pub`.
   - Boot volume: 100 GB (the free tier allows 200 GB in total)

   If it says *Out of capacity*, try again later or pick another availability domain.
2. Open the ports in Oracle's cloud firewall: Instance → Subnet → **Security List** → *Add Ingress Rules*. Source `0.0.0.0/0`, TCP, destination ports **80** and **443**, plus UDP **443**.
3. **(laptop)** `ssh ubuntu@203.0.113.10`
4. Oracle's Ubuntu image also blocks ports in the VM's own iptables. Open them there and save:
   ```bash
   sudo iptables -I INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
   sudo iptables -I INPUT -p udp --dport 443 -j ACCEPT
   sudo netfilter-persistent save
   ```
   Don't enable `ufw` on Oracle: it fights with these rules.

**Done when** you can SSH in as `ubuntu`.

## Phase 2: Harden the server
```bash
sudo apt update && sudo apt -y full-upgrade
sudo apt -y install unattended-upgrades fail2ban rclone curl git
sudo dpkg-reconfigure -plow unattended-upgrades          # answer Yes

# 2 GB swap: headroom while TensorFlow loads
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Keys only: no passwords, no root
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/; s/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# The account the app and GitHub deploys run as
sudo adduser --disabled-password --gecos "" deploy
sudo mkdir -p /srv/mycow && sudo chown deploy:deploy /srv/mycow
sudo reboot
```
**Done when** you can SSH back in after the reboot, and `free -h` shows 2 GB swap.

## Phase 3: Docker
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker deploy
sudo -iu deploy docker run --rm hello-world
```
**Done when** hello-world prints *Hello from Docker!* and says `(arm64v8)`.

## Phase 4: DNS
Cloudflare → DNS → **Add record**: type `A`, name `app`, IPv4 `203.0.113.10`, proxy status **DNS only (grey cloud)**.
Keep it grey: Caddy needs to reach Let's Encrypt directly to get the certificate.

**Done when** **(laptop)** `nslookup app.mycow.co.ke` returns your IP.

## Phase 5: First start
1. Images for ARM. The CI change that adds arm64 only affects **new** tags, so push a new tag in each repo once:
   **(laptop)** in my-cow-rest, my-cow-client and my-cow-py: `git tag vN` then `git push origin vN`. Use the next free number in each repo.
   On Docker Hub, the tag should list both `linux/amd64` and `linux/arm64`.
2. Put the deploy files on the server. Make `deploy-app` its own private GitHub repo `my-cow-deploy` first, then:
   ```bash
   sudo -iu deploy
   git clone https://github.com/Charmzyy/my-cow-deploy.git /srv/mycow   # private repo: use a GitHub token as the password
   cd /srv/mycow && chmod +x *.sh
   cp .env.example .env && nano .env
   ```
   In `.env`:
   - set `DOMAIN`, `APP_URL`, `FRONTEND_URL` and `CORS_ALLOWED_ORIGINS` to your domain;
   - set the three tags to the ones you just pushed;
   - set `DB_PASSWORD` to the output of `openssl rand -base64 24`.
3. App key, start, database:
   ```bash
   docker compose pull
   docker compose run --rm --no-deps app php artisan key:generate --show   # paste into APP_KEY in .env
   docker compose up -d
   docker compose ps                                                       # wait for all healthy (model takes ~2 min)
   docker compose exec app php artisan migrate --force
   docker compose exec app php artisan db:seed --force
   docker compose exec app php artisan db:seed --class=DemoSeeder --force  # optional demo accounts
   ```

**Done when** https://app.mycow.co.ke opens with a padlock, you can log in, and a breed check on a photo returns a result.

## Phase 6 (optional): Bring over your WSL data
**In WSL**, from your old deploy folder:
```bash
docker compose exec -T mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --no-tablespaces "$MYSQL_DATABASE"' | gzip > wsl-db.sql.gz
docker run --rm -v "$(docker compose ps -q app | xargs docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/storage/app/public"}}{{.Name}}{{end}}{{end}}')":/data:ro -v "$PWD":/b alpine tar czf /b/wsl-uploads.tar.gz -C /data .
scp wsl-db.sql.gz wsl-uploads.tar.gz deploy@203.0.113.10:/srv/mycow/backups/
```
**On the server**, run `./restore.sh db backups/wsl-db.sql.gz cowbreed --yes`, then `./restore.sh uploads backups/wsl-uploads.tar.gz --yes`, then `docker compose exec app php artisan migrate --force`.

**Done when** your old animals and their photos show up.

## Phase 7: Backups off the server, and an uptime alert
1. Cloudflare → **R2** → create the bucket `mycow-backups`. Then *Manage API tokens* → create a token with **Object Read & Write** on that bucket only. Note the Access Key ID, the Secret and the account endpoint.
2. As `deploy`, run `rclone config`:
   - new remote → name `r2`
   - type `s3`, provider `Cloudflare`
   - paste the keys
   - endpoint `https://<accountid>.r2.cloudflarestorage.com`

   Check it: `rclone lsd r2:` lists the bucket.
3. Run a backup and **prove it restores**:
   ```bash
   ./backup.sh && rclone ls r2:mycow-backups
   ./restore.sh db backups/db-nightly-*.sql.gz restore_test        # compare the row counts with the live DB
   docker compose exec mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE restore_test"'
   ```
4. Run it every night: `crontab -e` as `deploy`, then add:
   `0 2 * * * /srv/mycow/backup.sh >> /srv/mycow/backups/backup.log 2>&1`
5. UptimeRobot (free) → new HTTP(s) monitor on `https://app.mycow.co.ke/api/health`, every 5 min, alerting to your email.

**Done when** R2 shows a `db-nightly-…` and an `uploads-…` file, and UptimeRobot shows *Up*.

## Phase 8: Deploy automatically on a release tag
1. **(laptop)** make a key used only for deploys: `ssh-keygen -t ed25519 -f mycow-deploy -N '""'`
2. On the server, let that key run deploy.sh and nothing else:
   ```bash
   sudo -iu deploy
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   echo 'restrict,command="/srv/mycow/deploy.sh" <paste the one line from mycow-deploy.pub>' >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```
3. In each of the 3 GitHub repos, open Settings → Secrets and variables → Actions:
   - Secrets:
     - `VPS_HOST` = `203.0.113.10`
     - `VPS_USER` = `deploy`
     - `VPS_SSH_KEY` = the whole content of the private file `mycow-deploy`
   - Variables: `DEPLOY_ENABLED` = `true`
4. Push the next tag in my-cow-client, the quickest build, and watch Actions → *deploy*.
5. Test both safety nets once, by hand:
   - **Bad tag:** `./deploy.sh client v0` should stop at *could not pull*, leave `CLIENT_TAG` in `.env` unchanged and keep the site up.
   - **Failed health check:** stop the API so `/api/health` fails, then deploy:
     ```bash
     docker compose stop app
     ./deploy.sh client "$(grep ^CLIENT_TAG= .env | cut -d= -f2)"   # expect: never became healthy ... ROLLING BACK
     docker compose start app
     ```
     This takes about 8 minutes: it waits the full time, rolls back, then waits again. Since the API is
     still stopped, it ends with *rollback is unhealthy too*. That's expected here.

**Done when** a pushed tag appears live without you touching the server, and the deploy job's log ends with `deploy: client is live on vN`.

## Phase 9: Switch over
1. Run `docker compose down` in WSL and stop the quick tunnel.
2. In the app: Farm → **Print ear-tag QR stickers**. The new sheets carry the permanent domain. Re-stick any tags printed with the old tunnel URL.
3. Certificate PDFs draw their QR when downloaded, so they pick up the new domain on their own.
4. Optional: in Cloudflare, switch `app` to **Proxied** (orange cloud) and set SSL/TLS to **Full (strict)**. This hides the server IP and adds caching. Check that uploads and the QR scanner still work.

---

## Everyday commands (as `deploy`, in /srv/mycow)
| What | Command |
|---|---|
| Status | `docker compose ps` |
| Logs of one service | `docker compose logs -f --tail 100 app` |
| Deploy / roll back by hand | `./deploy.sh rest v15` (to roll back, deploy the previous tag) |
| Backup now | `./backup.sh` |
| Disk space | `df -h /` and `docker system df` |
| Update the server | `sudo apt update && sudo apt -y upgrade` (security updates install by themselves) |
