# Multi-Node Sentry Self-Hosted (Docker Swarm)

This guide describes the operator workflow for the 3-node Swarm deployment shipped
in this repo (`docker-stack.yml`, `scripts/swarm-init.sh`, `scripts/swarm-bootstrap-sentry.sh`).

Upstream `self-hosted` is a single-node Docker Compose project. The files in this
repo extend it with a Swarm-friendly stack and placement constraints — useful when
a single BM cannot hold all 72 services. This is NOT covered by Sentry's official
support: read the [optional-modifications/README.md](../optional-modifications/README.md)
warning before relying on it for production.

---

## Hardware target

| Role | Label | RAM | Disk | Services |
|------|-------|-----|------|----------|
| BM1  | `sentry.role=data` | 64 GB | 500 GB NVMe (root) + 500 GB NVMe (`/mnt/clickhouse`) | ClickHouse, Kafka, Postgres, pgbouncer, all Snuba consumers, snuba-api |
| BM2  | `sentry.role=app`  | 48 GB | 500 GB NVMe | sentry-web, worker, taskworker, taskbroker, SeaweedFS, symbolicator, vroom, all Sentry ingest consumers, cron |
| BM3  | `sentry.role=edge` | 32 GB | 500 GB NVMe | nginx (public), relay, redis, memcached, smtp, uptime-checker |

Total: 144 GB RAM, ~89 GB committed by service `resources.limits.memory`.

Sized for **100 000 users/day with session replays enabled**. See `docker-stack.yml`
for per-service memory budgets.

---

## Disk layout (critical)

100 000 users/day with replays will fill 500 GB fast under default retention.
Apply all three mitigations before going live:

1. **`SENTRY_EVENT_RETENTION_DAYS=7`** (already set in `.env`). Drops ClickHouse and
   SeaweedFS bucket lifecycle to 7 days. With the upstream default of 90, you'd be
   at ~30 TB of replay blobs — physically impossible on these BMs.
2. **SDK-side replay sampling.** In your Sentry org Project Settings (after first
   bootstrap), set `replaysSessionSampleRate: 0.1` and `replaysOnErrorSampleRate: 1.0`.
   With 10% sampling + 7-day retention, BM2's `sentry-data` volume stays under ~60 GB.
3. **(Optional) External S3 for blobs.** If you want to keep BM2's local NVMe free
   for other workloads, point `filestore.profiles-options.endpoint_url` (in
   `sentry/config.yml`) and `SENTRY_NODESTORE_OPTIONS.endpoint_url` (in
   `sentry/sentry.conf.py`) at MinIO / S3 / R2 / B2. The in-cluster `seaweedfs`
   service can stay running for the small remaining bucket usage. Comments in both
   files mark the lines to change.

### Why BM1 gets the second NVMe

ClickHouse is the largest (~250–350 GB at 7-day retention) and most I/O-intensive
consumer (constant merges). Mounting a second NVMe at `/mnt/clickhouse` and pinning
`sentry-clickhouse` + `sentry-clickhouse-log` to it gives ClickHouse capacity headroom
AND keeps merge I/O off the same spindle as Kafka log writes / Postgres WAL.

**Do NOT** RAID-0 the two BM1 NVMes — a single-disk failure would lose everything.
Keep them as independent ext4 filesystems.

Before running `swarm-init.sh`, mount the second NVMe:

```bash
mkfs.ext4 /dev/nvme1n1
mkdir -p /mnt/clickhouse
echo '/dev/nvme1n1 /mnt/clickhouse ext4 defaults,noatime 0 2' >> /etc/fstab
mount -a
```

`swarm-init.sh` auto-detects `/mnt/clickhouse` and bind-mounts the volumes correctly.

---

## Step-by-step deployment

### Prerequisites

- Docker Engine ≥ 24.x on all 3 BMs
- Private network connectivity between BM1, BM2, BM3 (open ports 2377/tcp,
  7946/tcp+udp, 4789/udp for Swarm overlay)
- Passwordless SSH from BM1 to BM2 and BM3 (used by `swarm-init.sh` to ship
  images, and by every rsync recipe in §"Updating config" below). Set up a
  dedicated keypair on BM1 and authorise the public key on BM2/BM3, e.g.
  ```bash
  # On BM1, as root (or whichever user will run the swarm scripts):
  ssh-keygen -t ed25519 -f /root/.ssh/sentry-swarm -N ''
  for host in $BM2_IP $BM3_IP; do
    ssh-copy-id -i /root/.ssh/sentry-swarm.pub root@$host
  done
  ```
  Then export `SSH_KEY=/root/.ssh/sentry-swarm` (and optionally
  `SSH_USER=<remote-user>` if not `root`) — `swarm-init.sh` and
  `swarm-bootstrap-sentry.sh` both honour those vars and bake them into the
  rsync hints they print.
- Repo cloned to `/opt/sentry/self-hosted` on **all three** BMs (rsync from BM1
  after every config edit)

### 1. On BM1 — initialise and ship images

```bash
cd /opt/sentry/self-hosted

# Mount the dedicated NVMe at /mnt/clickhouse FIRST (see §"Disk layout")
# Then:
export BM1_IP=<bm1-private-ip>
export BM2_IP=<bm2-private-ip>
export BM3_IP=<bm3-private-ip>
export SSH_KEY=/root/.ssh/sentry-swarm        # absolute path, authorised on BM2/BM3
export SSH_USER=root                          # optional, defaults to root
# Optional: export REGISTRY=registry.example.com:5000  (otherwise images go via ssh+save)

# `sudo` strips env vars by default — use `sudo -E` (or `sudo -i` then re-export)
# so swarm-init.sh sees BM*_IP / SSH_KEY / SSH_USER:
sudo -E bash scripts/swarm-init.sh
sudo systemctl restart docker     # apply daemon.json ulimits
```

The script prints the join command for BM2 and BM3 at the end.

### 2. On BM2 and BM3 — join, set ulimits, create volumes

On **each** of BM2 and BM3:

```bash
# Use the join command printed by swarm-init.sh
docker swarm join --token <token> <BM1_IP>:2377

# Write daemon.json (same content as BM1)
sudo tee /etc/docker/daemon.json <<'JSON'
{
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 262144, "Hard": 262144 }
  }
}
JSON
sudo systemctl restart docker

# Clone the repo
sudo mkdir -p /opt/sentry
sudo rsync -a <BM1>:/opt/sentry/self-hosted/ /opt/sentry/self-hosted/
```

Then on **BM2 only**:
```bash
docker volume create sentry-data
docker volume create sentry-seaweedfs
docker volume create sentry-symbolicator
docker volume create sentry-vroom
docker volume create sentry-taskbroker
```

On **BM3 only**:
```bash
docker volume create sentry-redis
docker volume create sentry-smtp
docker volume create sentry-smtp-log
docker volume create sentry-nginx-cache
docker volume create sentry-nginx-www
```

### 3. On BM1 — label nodes and deploy

```bash
docker node ls           # confirm 3 managers visible
docker node update --label-add sentry.role=app  <BM2-hostname>
docker node update --label-add sentry.role=edge <BM3-hostname>

# Export env vars FIRST. `docker stack deploy` (unlike `docker compose`) does
# NOT auto-load .env files. Skip this and deploy aborts with:
#   error while interpolating services.<svc>.healthcheck.retries:
#   failed to cast to expected type: strconv.Atoi: parsing "": invalid syntax
# .env.custom is generated by the bootstrap step below; the test is so step 4's
# re-deploy can reuse the same one-liner.
set -a; source .env; [ -f .env.custom ] && source .env.custom; set +a

# Deploy the stack
docker stack deploy --compose-file docker-stack.yml sentry
```

Wait ~2 minutes, then:

```bash
docker stack services sentry
# every REPLICAS should be 1/1 (snuba-replays-consumer 2/2). Tasks may be
# "starting" or "shutdown" while ClickHouse/Postgres come up — let it stabilise.
```

A few services will crash-loop until step 4 finishes — that's expected:
- `sentry_web` — missing `SENTRY_SYSTEM_SECRET_KEY` (created in step 4a)
- `sentry_relay` — missing `relay/credentials.json` (step 4d)
- `sentry_nginx` — can't yet resolve `relay`/`web`; self-recovers when they're up
- All `sentry_*-consumer` services — missing Kafka topics (created in step 4e by `sentry upgrade --create-kafka-topics`)

### 4. Bootstrap application state

The bootstrap script can only drive what it can `docker exec` into from BM1
(postgres, kafka, clickhouse, snuba-api). Everything that lives on BM2
(seaweedfs, web, sentry consumers) or BM3 (relay) has to be done by hand on
those nodes. Follow the substeps in order.

#### 4a. On BM1 — generate secrets, GeoIP, snuba migrations

```bash
# Wait until snuba-api task shows "Running" before this — the script tries to
# exec into it. Usually ~60s after `stack deploy`.
docker service ps sentry_snuba-api --filter desired-state=running

bash scripts/swarm-bootstrap-sentry.sh
```

This writes `.env.custom` with `SENTRY_SYSTEM_SECRET_KEY`, downloads (an empty
placeholder of) the GeoIP DB, and runs `snuba bootstrap` + `snuba migrations
migrate`. It does NOT generate relay credentials, create Kafka topics, run
`sentry upgrade`, or create the SeaweedFS buckets — those need 4b–4f.

#### 4b. On BM1 — re-deploy so `SENTRY_SYSTEM_SECRET_KEY` reaches the `web` container

```bash
set -a; source .env; source .env.custom; set +a
docker stack deploy --compose-file docker-stack.yml sentry
```

Now `sentry_web` stops crash-looping on `ImproperlyConfigured: SECRET_KEY`.

#### 4c. Kafka topics — handled by `sentry upgrade --create-kafka-topics` in 4e

Previous versions of this guide had a "create 13 ingest topics" step here. That
list always drifted behind upstream — most importantly it never included the
downstream topics (`events`, `snuba-commit-log`, `snuba-transactions-commit-log`,
`snuba-generic-events-commit-log`, `outcomes`, `outcomes-billing`,
`group-attributes`, `shared-resources-usage`, …) that the post-process
forwarders rely on. The visible symptom was: events land in ClickHouse and
appear in Discover/raw search, but the Issues stream stays empty and no
notification emails get sent, because `post-process-forwarder-errors` cannot
synchronize on a `snuba-commit-log` topic that doesn't exist.

The canonical fix is the same one the single-node `install.sh` uses:
`sentry upgrade --create-kafka-topics`. It is idempotent and creates every
topic Sentry needs (ingest, downstream, commit-log, monitors, uptime, etc.).
It runs in step 4e below from BM2 (where the `sentry_web` container is
pinned). Nothing to do here.

#### 4d. On BM3 — relay config + credentials

Relay needs BOTH `config.yml` AND `credentials.json` in `/opt/sentry/self-hosted/relay/`.
With only credentials present, relay logs `launching relay without config
folder` and ignores the credentials, then dies on `relay has no credentials,
which are required in managed mode`.

```bash
cd /opt/sentry/self-hosted

# 1. Drop in the config (idempotent — example uses overlay-DNS hostnames
#    `web:9000`, `kafka:9092`, `redis://redis:6379` which work as-is)
sudo cp -n relay/config.example.yml relay/config.yml

# 2. Generate credentials. Note `--stdout`, not `-o` (relay CLI rejects -o).
sudo docker run --rm \
  --entrypoint relay \
  ghcr.io/getsentry/relay:26.4.2 \
  credentials generate --stdout > relay/credentials.json

ls -la relay/credentials.json   # ~160 bytes is normal
```

Relay self-recovers within ~30 s.

#### 4e. On BM2 — sentry upgrade, SeaweedFS buckets, superuser

```bash
WEB=$(sudo docker ps -qf "label=com.docker.swarm.service.name=sentry_web")
SEAWEED=$(sudo docker ps -qf "label=com.docker.swarm.service.name=sentry_seaweedfs")

# Schema migrations + Kafka topic creation (idempotent — matches what
# install/set-up-and-migrate-database.sh runs for the single-node deploy).
# The --create-kafka-topics flag is REQUIRED: it creates `events`,
# `snuba-commit-log`, `outcomes`, `group-attributes`, and the rest of the
# downstream topics the post-process forwarders need. Without it, issues
# silently never get grouped and notification emails never fire.
sudo docker exec "$WEB" sentry upgrade --noinput --create-kafka-topics

# SeaweedFS buckets with 7-day lifecycle (matches SENTRY_EVENT_RETENTION_DAYS)
sudo docker exec "$SEAWEED" apk add --no-cache s3cmd
S3="sudo docker exec $SEAWEED s3cmd --access_key=sentry --secret_key=sentry \
    --no-ssl --region=us-east-1 --host=localhost:8333 \
    --host-bucket=localhost:8333/%(bucket)"
for b in nodestore profiles; do $S3 mb "s3://$b"; done
for b in profiles nodestore; do
  sudo docker exec "$SEAWEED" sh -c "cat > /tmp/$b-lc.xml <<EOF
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<LifecycleConfiguration>
  <Rule><ID>Sentry-$b-Rule</ID><Status>Enabled</Status><Filter></Filter>
    <Expiration><Days>7</Days></Expiration></Rule>
</LifecycleConfiguration>
EOF"
  $S3 setlifecycle "/tmp/$b-lc.xml" "s3://$b"
done

# First superuser (interactive — prompts for email + password)
sudo docker exec -it "$WEB" sentry createuser --superuser
```

#### 4f. On BM1 — set `system.url-prefix` and force-restart `web`

Without this, the browser hits a `CSRF Validation Failed` page on login.
Sentry defaults `system.url-prefix` to `http://localhost:9000` and refuses
POSTs from any other Origin.

```bash
sed -i "s|^# system.url-prefix:.*|system.url-prefix: 'http://<BM3-IP>:9000'|" \
  sentry/config.yml

# config.yml is bind-mounted from each node's local disk, so push to BM2
rsync -a sentry/config.yml root@<BM2-IP>:/opt/sentry/self-hosted/sentry/config.yml

docker service update --force sentry_web
```

When you later switch to a real domain, re-run this with the new URL and
force-restart web again.

### 5. Verify

```bash
curl http://<BM3-IP>:9000/_health/        # → "ok" (HTTP 200, plain text)
docker stack services sentry | awk '$4 != "1/1" && $4 != "2/2"'
# Only the header row should print — every service is 1/1 except
# snuba-replays-consumer (2/2).
```

Open `http://<BM3-IP>:9000` in a browser. Log in with the superuser from 4e.
Create an org, create a project, copy the DSN, send a test event, see it land
in Issues. Full verification steps below.

---

## Verification

### Stack health

```bash
docker stack services sentry
docker stack ps sentry --filter desired-state=Running --no-trunc | grep -v Running
# expect: empty (no failed tasks)

# Per-node container check
for bm in BM1 BM2 BM3; do
  echo "=== $bm ==="
  ssh "$bm" 'docker ps --format "{{.Names}}\t{{.Status}}" | grep -v "Up "'
done
```

### Overlay DNS

```bash
WEB=$(docker ps -qf "name=sentry_web")     # on BM2
docker exec "$WEB" python -c "
import socket
for h in ['kafka','clickhouse','postgres','redis','seaweedfs']:
    print(h, '->', socket.gethostbyname(h))
"
# All should resolve to 10.x.x.x overlay IPs.
```

### Replay end-to-end

1. In the UI: open the project's Replays settings, enable Session Replay.
2. In a browser SDK init (temporarily for the test):
   ```javascript
   Sentry.init({ dsn: "...", replaysSessionSampleRate: 1.0 });
   ```
3. Load a page, click around, navigate.
4. Within 60 s the replay should appear in the Replays tab.

Pipeline checks:
```bash
# On BM1 — Kafka consumer lag for replay-recordings
KAFKA=$(docker ps -qf "name=sentry_kafka")
docker exec "$KAFKA" kafka-consumer-groups --bootstrap-server localhost:9092 \
  --group ingest-replay-recordings --describe
# LAG ~ 0 indicates the consumer is keeping up.

# On BM1 — ClickHouse replays row count
CH=$(docker ps -qf "name=sentry_clickhouse")
docker exec "$CH" clickhouse-client --query \
  "SELECT count() FROM replays_local WHERE timestamp > now() - 600"
# should match what you generated.
```

### Memory & disk monitoring

```bash
# ClickHouse ceiling (should stay below ~38 GB)
docker exec "$CH" clickhouse-client --query \
  "SELECT formatReadableSize(value) FROM system.metrics WHERE metric='MemoryTracking'"

# Kafka lag across all consumer groups
docker exec "$KAFKA" kafka-consumer-groups --bootstrap-server localhost:9092 \
  --all-groups --describe | awk '$5 ~ /^[0-9]+$/ && $5 > 1000 {print}'

# Disk usage per node
for bm in BM1 BM2 BM3; do
  echo "=== $bm ==="
  ssh "$bm" 'df -h /var/lib/docker /mnt/clickhouse 2>/dev/null'
done
```

Steady-state milestones:
- **24 h**: replays still ingesting, no Kafka lag > 1000, disk usage stable
- **7 d**: `sentry-cleanup` cron has dropped ClickHouse partitions older than 7 days
  (check `system.parts` for min/max partition dates)
- **14 d**: disk usage flat on every BM; SeaweedFS volume on BM2 < 50 GB

---

## Operations

### Updating config and applying changes

The mental model has two pieces:

1. **`docker-stack.yml` is the source of truth for what Swarm runs.** Service
   image, env vars, healthchecks, placement, resource limits — all live here.
   Changes to this file only take effect via `docker stack deploy`.

2. **Config files are bind-mounted from each node's local disk** (no Configs
   secret store, no shared volume). E.g., `sentry/config.yml` mounts as
   `/opt/sentry/self-hosted/sentry:/etc/sentry` — so `web` (on BM2) reads BM2's
   copy, `worker` (also on BM2) reads BM2's copy, and editing the file on BM1
   has *no effect* until you rsync it to BM2. That's why every recipe below
   has an rsync step.

The right action depends on which file you changed:

| File you edited | What it affects | Action |
|-----------------|-----------------|--------|
| `sentry/config.yml`, `sentry/sentry.conf.py` | Sentry app config (read by `web`, `worker`, `taskworker`, ingest consumers — all on BM2) | rsync to BM2 → `docker service update --force` on the affected services (see recipe A) |
| `relay/config.yml` | Relay config (BM3 only) | rsync to BM3 → `docker service update --force sentry_relay` |
| `nginx.conf` | nginx routes (BM3 only) | rsync to BM3 → `docker service update --force sentry_nginx` |
| `clickhouse/config.xml`, `clickhouse/default-password.xml` | ClickHouse config (BM1) | edit in place on BM1 → `docker service update --force sentry_clickhouse` |
| `redis.conf` | Redis config (BM3) | rsync to BM3 → `docker service update --force sentry_redis` |
| `symbolicator/config.yml` | symbolicator (BM2) | rsync to BM2 → `docker service update --force sentry_symbolicator` |
| `.env` or `.env.custom` | Env-var values that `docker-stack.yml` interpolates | `docker stack deploy` again (recipe B) — there is no per-service shortcut |
| `docker-stack.yml` itself | Anything Swarm-managed (image, env, healthcheck, placement, resources, secrets) | `docker stack deploy` (recipe C) |
| Built images (`sentry-self-hosted-local`, etc.) | Sentry / Snuba code | rebuild → distribute to nodes → bump tag in `.env` → `docker stack deploy` (recipe D) |

#### Recipe A — Edit a bind-mounted config file (most common)

`sentry/config.yml` is the textbook example. The file is bind-mounted from
each node's local disk, so the edit has to be present on every node that runs
a service consuming the file.

```bash
# 1. Edit on BM1 (source of truth)
vim /opt/sentry/self-hosted/sentry/config.yml

# 2. Sync to every node that runs a service consuming this file. For sentry/*
#    that's BM2 (web, worker, taskworker, all ingest consumers, cron). For
#    config files specific to one role you only sync to that node.
rsync -a /opt/sentry/self-hosted/sentry/ root@<BM2-IP>:/opt/sentry/self-hosted/sentry/

# 3. Force-restart each service that has this file open. Swarm will roll a new
#    task that re-reads the mounted file.
for svc in sentry_web sentry_worker sentry_taskworker \
           sentry_events-consumer sentry_attachments-consumer \
           sentry_transactions-consumer sentry_metrics-consumer \
           sentry_generic-metrics-consumer sentry_ingest-occurrences \
           sentry_ingest-profiles sentry_ingest-replay-recordings \
           sentry_ingest-feedback-events sentry_process-segments \
           sentry_process-spans sentry_post-process-forwarder-errors \
           sentry_post-process-forwarder-transactions \
           sentry_post-process-forwarder-issue-platform \
           sentry_subscription-consumer-events \
           sentry_subscription-consumer-transactions \
           sentry_subscription-consumer-metrics \
           sentry_subscription-consumer-generic-metrics \
           sentry_subscription-consumer-eap-items \
           sentry_uptime-results sentry_monitors-clock-tick \
           sentry_monitors-clock-tasks sentry_sentry-cleanup; do
  docker service update --force "$svc"
done
```

For most edits to `config.yml` / `sentry.conf.py`, just restarting `sentry_web`
is enough to see UI-level effects — the consumer fleet picks up the change the
next time it restarts on its own or when you do a full rollout. Force them all
only when the change must take effect *immediately* everywhere (e.g., a
filestore endpoint change).

#### Recipe B — Change an env var (`.env` or `.env.custom`)

Env-var values are interpolated at deploy time. Running services don't see
edits until you re-deploy. (Note: `.env` lives only on BM1 because the stack
deploys from BM1 — there's nothing to rsync.)

```bash
# 1. Edit on BM1
vim /opt/sentry/self-hosted/.env            # or .env.custom

# 2. Re-source and re-deploy. Swarm diffs the new env against running services
#    and only restarts the ones whose env actually changed.
set -a; source .env; [ -f .env.custom ] && source .env.custom; set +a
docker stack deploy --compose-file docker-stack.yml sentry
```

#### Recipe C — Change `docker-stack.yml`

This is the only way to change image, ports, healthcheck, placement, or
resource limits. The YAML file itself only needs to exist on BM1 (the node
you run `stack deploy` from); BM2 and BM3 never read it directly.

```bash
# 1. Edit on BM1
vim /opt/sentry/self-hosted/docker-stack.yml

# 2. Re-deploy
set -a; source .env; [ -f .env.custom ] && source .env.custom; set +a
docker stack deploy --compose-file docker-stack.yml sentry
```

Swarm performs a rolling update — only the services whose definitions actually
changed get new tasks. The rest are untouched.

Common gotchas:
- **Service name change**: Swarm treats it as a delete + create. The old
  service is removed; the new one starts from scratch. State that lived in
  the old service's overlay attachments / DNS entry is lost briefly.
- **Memory limit decrease below current RSS**: the new task OOMs immediately.
  Watch `docker service ps <svc>` after the deploy.
- **Healthcheck change**: takes effect on the next task replacement — the
  current task keeps its old healthcheck until it's replaced.
- **Adding a new env var that another service depends on**: re-deploy alone
  won't restart the depender unless its own definition changed. Force-restart
  it explicitly: `docker service update --force sentry_<depender>`.

#### Recipe D — Upgrade Sentry version

```bash
# On BM1
cd /opt/sentry/self-hosted

# 1. Pull new code or bump tag in install/...
#    Then rebuild local images (see install/build-docker-images.sh).
# 2. Distribute the new images to BM2 and BM3 (swarm-init.sh has the ssh+save logic;
#    or push to your private registry if you set REGISTRY=...).
# 3. Bump SENTRY_VERSION in .env
sed -i "s|^SENTRY_VERSION=.*|SENTRY_VERSION=<new>|" .env

# 4. Re-deploy
set -a; source .env; source .env.custom; set +a
docker stack deploy --compose-file docker-stack.yml sentry

# 5. Run any new migrations on BM2 (since web is pinned there)
ssh root@<BM2-IP> 'docker exec $(docker ps -qf name=sentry_web) sentry upgrade --noinput'

# 6. On BM1, run snuba migrations
docker exec $(docker ps -qf name=sentry_snuba-api) snuba migrations migrate
```

Always check the upstream Sentry self-hosted release notes for breaking changes
between your current version and the target.

#### Verifying a change applied

```bash
# 1. Confirm the new task is running (CurrentState says "Running" and has a
#    fresh timestamp).
docker service ps sentry_<service> --no-trunc | head -3

# 2. For a sentry/config.yml change, exec into the running container and
#    grep the file to confirm the new content is mounted.
CID=$(docker ps -qf "label=com.docker.swarm.service.name=sentry_web")
docker exec "$CID" grep -F "<your-edit>" /etc/sentry/config.yml

# 3. For an env-var change, check the running container's env directly.
docker service inspect sentry_<service> \
  --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' \
  | grep -i <VARNAME>

# 4. Watch logs immediately after to catch startup errors. Many invalid
#    configs (typos in sentry.conf.py, malformed YAML) only surface here.
docker service logs sentry_<service> --tail 30 --follow
```

#### Rollback

If a deploy goes bad:

```bash
# Roll back the last update to a single service
docker service rollback sentry_<service>

# For a docker-stack.yml change, your "rollback" is to `git checkout` the
# previous version and re-deploy. There is no built-in stack-level rollback.
git -C /opt/sentry/self-hosted checkout docker-stack.yml
set -a; source .env; source .env.custom; set +a
docker stack deploy --compose-file docker-stack.yml sentry
```

For config-file edits, keep `git` clean so `git diff` always shows what's
changed and `git checkout -- <file>` is your rollback.

### Scaling a service up

```bash
# e.g., add a second replay consumer
docker service scale sentry_snuba-replays-consumer=3
```

Stateful singletons (postgres, redis, kafka, clickhouse, seaweedfs) MUST stay at
`replicas: 1`. Their volumes are bound to a single node; scaling them up will
fail.

### Failing over a stateful service

Not supported by this configuration — spread-only HA. If BM1 dies, ClickHouse +
Kafka + Postgres are down until BM1 is recovered. Backup `sentry-postgres`,
`sentry-clickhouse`, `sentry-kafka` volumes externally (see `scripts/backup.sh`)
to allow restore on a replacement BM1.

### Tearing down

```bash
docker stack rm sentry
# Volumes persist on each node until you remove them manually.
```

---

## Where to look when things break

### Bootstrap-time failures (first deploy)

| Symptom | Cause / fix |
|---------|-------------|
| `docker stack deploy` aborts with `failed to cast to expected type: parsing "": invalid syntax` on `healthcheck.retries` | `.env` wasn't sourced into the shell. `docker stack deploy` does not auto-load `.env` files (unlike `docker compose`). Run `set -a; source .env; [ -f .env.custom ] && source .env.custom; set +a` first. |
| `docker stack deploy` rejects a service: name too long | Swarm caps service names at 63 chars *including* the `sentry_` stack prefix. Shorten the YAML key in `docker-stack.yml`. (The original `snuba-subscription-consumer-generic-metrics-distributions` was already shortened here.) |
| `sentry_web` crash-loops with `ImproperlyConfigured: The SECRET_KEY setting must not be empty` | Bootstrap step 4a hasn't run, or 4b hasn't re-deployed after `.env.custom` was created. |
| Events received but Issues stream stays empty AND no notification emails fire | Most likely `snuba-commit-log` got broker-auto-created with >1 partition before `snuba bootstrap` ran, so the post-process-forwarder's SynchronizedConsumer stalls (commit-log keys hash across partitions, watermarks never advance). `snuba-commit-log` declares `enforced_partition_count: 1` in sentry-kafka-schemas. Diagnose on BM1: `docker exec $(docker ps -qf name=sentry_kafka) kafka-topics --bootstrap-server localhost:9092 --describe --topic snuba-commit-log` — if `PartitionCount` is not `1`, you've hit this. Fix: stop the affected consumer groups, delete the topic, let snuba recreate it, then restart. See "Repairing a misaligned snuba-commit-log" below. Root cause was `KAFKA_NUM_PARTITIONS: "12"` in `docker-stack.yml` combined with broker `auto.create.topics.enable=true` — the 12 setting is now removed. |
| Consumers crash-loop with `KafkaError{code=UNKNOWN_TOPIC_OR_PART, ..., <topic>}` | Topic was never created. Re-run step 4e (`sentry upgrade --noinput --create-kafka-topics`) — idempotent. |
| `sentry_relay` says `relay has no credentials, which are required in managed mode` even though `relay/credentials.json` exists | Relay also needs `relay/config.yml` to recognise `/work/.relay/` as a config folder. Run 4d. |
| `sentry_seaweedfs` cycles every 3–4 min with healthcheck failures | Healthcheck must use `localhost`, not the service VIP. The Swarm VIP can route back to the same starting task during the `start_period` window. Already fixed in `docker-stack.yml`. |
| Login fails with `CSRF Validation Failed` after typing credentials | `system.url-prefix` in `sentry/config.yml` is not set (or doesn't match the URL in the browser). Run 4f. |
| 80%+ CPU on BM2 with no traffic | Ingest consumers on BM2 are crash-looping every 3–6 s and burning Python startup. Almost always means Kafka topics are missing — re-run 4e. |
| `SENTRY_SELF_HOSTED_ERRORS_ONLY` is unexpectedly `True` (transactions/replays/issue-platform features look disabled even though their consumers are running) | `COMPOSE_PROFILES` env var wasn't propagated to sentry containers. `docker-stack.yml`'s `x-sentry-defaults` now sets `COMPOSE_PROFILES: ${COMPOSE_PROFILES:-feature-complete}`. Re-source `.env` and `docker stack deploy` to roll the sentry services. |

### Runtime failures (after bootstrap)

| Symptom | Where to look |
|---------|---------------|
| Replays not appearing | `docker service logs sentry_ingest-replay-recordings` (BM2), `docker service logs sentry_snuba-replays-consumer` (BM1) |
| 502 from nginx | `docker service logs sentry_nginx` (BM3); confirm `web` is healthy on BM2 |
| Events stuck | Kafka consumer lag (`kafka-consumer-groups --describe --all-groups`); look for groups with LAG > 1000 |
| ClickHouse OOM | `docker service logs sentry_clickhouse`; reduce `MAX_MEMORY_USAGE_RATIO` in `docker-stack.yml` |
| Postgres slow | `docker exec $(docker ps -qf name=sentry_postgres) psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE state='active'"` |
| SeaweedFS full | `docker exec $(docker ps -qf name=sentry_seaweedfs) df -h /data`; consider externalizing buckets (§"Disk layout" #3) |
| Cross-node service can't resolve another | Confirm overlay DNS (`docker exec ... python -c "import socket; ..."`). If broken, restart docker on the affected node. |

### Repairing a misaligned `snuba-commit-log`

If `kafka-topics --describe --topic snuba-commit-log` shows a `PartitionCount` other than 1, the post-process-forwarder is stalling silently. Repair on BM1:

```bash
KAFKA=$(docker ps -qf "label=com.docker.swarm.service.name=sentry_kafka")

# 1. Stop the consumer groups that read/write the commit log so we can recreate the topic.
#    (Pausing services on BM1 + BM2; tasks queue up safely.)
for svc in sentry_snuba-errors-consumer \
           sentry_snuba-transactions-consumer \
           sentry_snuba-issue-occurrence-consumer \
           sentry_post-process-forwarder-errors \
           sentry_post-process-forwarder-transactions \
           sentry_post-process-forwarder-issue-platform; do
  docker service scale "$svc"=0
done

# 2. Delete the misaligned topic (only the commit-log, NOT the events topic).
docker exec "$KAFKA" kafka-topics --bootstrap-server localhost:9092 --delete --topic snuba-commit-log
# If you also see PartitionCount != 1 on snuba-transactions-commit-log or
# snuba-generic-events-commit-log, delete those too with the same command.

# 3. Re-bootstrap snuba so it recreates the commit-log topics with the correct
#    partition count (snuba hardcodes num_partitions=1 for these).
SNUBA=$(docker ps -qf "label=com.docker.swarm.service.name=sentry_snuba-api")
docker exec "$SNUBA" snuba bootstrap --force --no-migrate

# 4. Confirm partition count is now 1.
docker exec "$KAFKA" kafka-topics --bootstrap-server localhost:9092 --describe --topic snuba-commit-log
# → PartitionCount: 1

# 5. Bring the consumers back.
for svc in sentry_snuba-errors-consumer \
           sentry_snuba-transactions-consumer \
           sentry_snuba-issue-occurrence-consumer \
           sentry_post-process-forwarder-errors \
           sentry_post-process-forwarder-transactions \
           sentry_post-process-forwarder-issue-platform; do
  docker service scale "$svc"=1
done

# 6. On BM2, force-roll the consumer-side state.
ssh <BM2> 'for svc in sentry_post-process-forwarder-errors \
                       sentry_post-process-forwarder-transactions \
                       sentry_post-process-forwarder-issue-platform \
                       sentry_taskworker; do
  docker service update --force "$svc"
done'
```

Send a test event; the next `post-process-forwarder-errors` log line should show it being grouped, and notification emails should start firing for matching alert rules.

---

## Differences from the upstream single-node deploy

Read this if you're familiar with the upstream `install.sh` flow:

- **`docker-stack.yml`** replaces `docker-compose.yml`. The upstream compose file is
  kept for local single-node dev only.
- **No `install.sh`**. The script runs `docker compose up` and `docker exec` which
  do not work in Swarm mode. Use `swarm-init.sh` + `swarm-bootstrap-sentry.sh`.
  Both reuse fragments from `install/` for secrets, relay credentials, and GeoIP.
- **Swarm doesn't gate services on `profiles:`** — all 72 services always run.
  But `COMPOSE_PROFILES` is still propagated into sentry containers via
  `x-sentry-defaults`, because `sentry/sentry.conf.example.py` reads it to
  decide `SENTRY_SELF_HOSTED_ERRORS_ONLY`. Leave it at `feature-complete`
  (the default in `.env`) unless you genuinely want errors-only behaviour;
  otherwise transactions / replay / issue-platform notification handlers
  silently no-op.
- **All `ulimits:` blocks removed**. Set globally in `/etc/docker/daemon.json`
  because Swarm doesn't honour service-level ulimits.
- **`build:` removed**. Local images are pre-built and distributed (or pushed to
  a private registry) before `stack deploy`.
- **`depends_on:` removed**. Services use healthchecks + Swarm restart policies
  to converge.
- **Memory limits added**. Every service has a `deploy.resources.limits.memory`
  sized for the target BM. Without these one service could starve the others.
- **`snuba-replays-consumer` runs 2 replicas**. The heaviest consumer; partitions
  are shared via the Kafka consumer group.
- **`sentry/config.yml` and `sentry/sentry.conf.py`** are checked in (not generated
  from `*.example` by `install.sh`). Edit them directly; rsync to BM2/BM3; redeploy.

### Swarm gotchas that bit us during first deploy

- **`docker stack deploy` does not auto-load `.env`.** Must `set -a; source .env;
  set +a` (and `.env.custom` once 4a created it) before deploy. Otherwise it
  errors on healthcheck retries env interpolation.
- **Service-name limit is 63 chars including the `sentry_` stack prefix** — so
  the YAML key has to be ≤ 56 chars. One service has already been shortened.
- **Service-level healthchecks that hit the service VIP (`http://<svc>:<port>`)
  can kill the same task they're meant to probe.** During `start_period`,
  Swarm's IPVS may route the probe back to the just-starting task and fail
  before it's ready. Use `http://localhost:<port>` for the container's own
  healthcheck.
- **Kafka topic creation is split between `snuba bootstrap` and broker
  auto-create — both have to land 1-partition topics for `snuba-commit-log`
  to work.** `snuba bootstrap` uses `AdminClient.create_topics(NewTopic(..., num_partitions=1))`
  for `snuba-commit-log`, `events`, `outcomes`, `group-attributes`, etc.
  Ingest-side and taskworker-side topics aren't in that list and rely on
  broker auto-create. The Sentry flag `sentry upgrade --create-kafka-topics`
  is misnamed (getsentry/sentry#103438) — it doesn't create, it `wait_for_topics`,
  but its metadata requests carry `allow_auto_topic_creation=true`, so the
  broker creates them with its `num.partitions` default. Keep that default
  at 1 — the prior `KAFKA_NUM_PARTITIONS: "12"` in `docker-stack.yml` caused
  any commit-log topic that lost the race with `snuba bootstrap` to come up
  with 12 partitions, silently stalling the post-process-forwarder
  (sentry-kafka-schemas marks the commit-log topics with
  `enforced_partition_count: 1`). See step 4e and the "Repairing a misaligned
  snuba-commit-log" recipe.
- **Relay needs both `config.yml` AND `credentials.json`** in `/work/.relay/`.
  Upstream's `install/ensure-relay-credentials.sh` copies example → real
  before generating credentials. The swarm bootstrap script currently does
  not (see step 4d).
- **Sentry's CSRF check uses `system.url-prefix`.** If it's commented out (as
  in the checked-in `sentry/config.yml`), the default is `http://localhost:9000`
  and any browser POST from the BM3 IP gets rejected. See step 4f.
