#!/usr/bin/env bash
#
# Initialise a Docker Swarm cluster across 3 bare-metal nodes for Sentry self-hosted.
#
# Run this script once, from BM1 (the chosen manager-bootstrap node). It will:
#   1. Initialise Swarm on BM1 and print the join command for BM2/BM3.
#   2. Label the local node as sentry.role=data after a successful init.
#   3. Pre-build the three locally-derived images (sentry, clickhouse, sentry-cleanup).
#   4. Push them to a private registry OR save+ssh+load to BM2/BM3 (toggle via env).
#   5. Create the per-node named volumes on the LOCAL node (you must re-run the
#      volume-create section on BM2 and BM3 — see comments).
#   6. Write /etc/docker/daemon.json with system-wide nofile=262144 on this node
#      (you must repeat this on BM2/BM3 manually then restart docker).
#
# Required env:
#   BM1_IP, BM2_IP, BM3_IP — private-network IPs of the three bare metals
#
# Optional env:
#   REGISTRY — if set (e.g. "registry.example.com:5000"), images are pushed instead
#              of saved+ssh-loaded. Recommended for production.
#   SENTRY_VERSION — defaults to 26.4.2 (matches .env's SENTRY_IMAGE tag).
#   SSH_KEY — absolute path to a private SSH key authorised on BM2 and BM3
#             (e.g. /root/.ssh/sentry-swarm). Used for the `docker save | ssh`
#             image-distribution step and printed into the operator's rsync /
#             ssh hints. If unset, ssh uses whatever the running user's default
#             agent / key chain resolves — fine if you've already set up
#             passwordless ssh another way.
#   SSH_USER — remote user on BM2 / BM3 (default: root). Must own a writable
#              /opt/sentry/self-hosted and be in the docker group on the
#              remote node.
#
# Run BM2/BM3 join + their own volume/daemon.json steps manually after this finishes;
# search for "RUN-ON-BM2" and "RUN-ON-BM3" tags below for the exact commands to copy.

set -euo pipefail

: "${BM1_IP:?Set BM1_IP to the private IP of BM1 (this node)}"
: "${BM2_IP:?Set BM2_IP to the private IP of BM2}"
: "${BM3_IP:?Set BM3_IP to the private IP of BM3}"
SENTRY_VERSION="${SENTRY_VERSION:-26.4.2}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"

# Build SSH/RSYNC command prefixes that respect SSH_KEY/SSH_USER. We disable
# strict host-key checking on first contact because the operator just pointed
# at three IPs — there's no opportunity to TOFU before this runs. If you've
# already collected fingerprints in known_hosts, this is a no-op.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
if [[ -n "$SSH_KEY" ]]; then
  if [[ ! -r "$SSH_KEY" ]]; then
    echo "SSH_KEY=$SSH_KEY is not readable. Set it to an absolute path or unset it." >&2
    exit 1
  fi
  SSH_OPTS+=(-i "$SSH_KEY")
fi

ssh_to()  { ssh   "${SSH_OPTS[@]}" "${SSH_USER}@$1" "${@:2}"; }
# Hint string we'll print into operator-facing rsync/ssh examples so they
# match what the script itself uses.
if [[ -n "$SSH_KEY" ]]; then
  SSH_HINT="ssh -i $SSH_KEY ${SSH_USER}@"
  RSYNC_HINT="rsync -a -e 'ssh -i $SSH_KEY' "
else
  SSH_HINT="ssh ${SSH_USER}@"
  RSYNC_HINT="rsync -a "
fi
export SSH_KEY SSH_USER SSH_HINT RSYNC_HINT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf "\n\033[1;36m[%s]\033[0m %s\n" "swarm-init" "$*"; }

# Sanity-check ssh to BM2 and BM3 before we burn time building images we
# can't ship. Cheaper to fail here than at the `docker save | ssh` step.
for host in "$BM2_IP" "$BM3_IP"; do
  log "Verifying ssh ${SSH_USER}@${host}"
  if ! ssh_to "$host" 'echo ok' >/dev/null 2>&1; then
    echo "Could not ssh to ${SSH_USER}@${host} with the configured key." >&2
    echo "Either fix the key/agent and re-run, or set SSH_KEY to an absolute path." >&2
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# 0. Make sure sentry/config.yml and sentry/sentry.conf.py exist
#    (they're gitignored upstream — when cloning fresh, seed them from examples).
# ------------------------------------------------------------------------------
for pair in "sentry/sentry.conf.py:sentry/sentry.conf.example.py" \
            "sentry/config.yml:sentry/config.example.yml" \
            "symbolicator/config.yml:symbolicator/config.example.yml"; do
  target="${pair%%:*}"
  example="${pair##*:}"
  if [[ ! -f "$target" ]]; then
    log "Seeding $target from $example"
    cp "$example" "$target"
    log "  $target was created from the example. Review it for multinode-specific"
    log "  tweaks (uwsgi workers, retention, etc.) — see docs/multinode-setup.md."
  fi
done

# ------------------------------------------------------------------------------
# 1. Swarm init (on BM1)
# ------------------------------------------------------------------------------
if docker info 2>/dev/null | grep -q "Swarm: active"; then
  log "Swarm already active on this node; skipping init."
else
  log "Initialising Swarm with advertise-addr=$BM1_IP"
  docker swarm init --advertise-addr "$BM1_IP"
fi

log "Manager join token (paste into BM2 and BM3):"
echo "------"
docker swarm join-token manager | tail -3
echo "------"
echo
echo "RUN-ON-BM2 / RUN-ON-BM3:"
echo "  $(docker swarm join-token manager -q | head -1 >/dev/null || true)"
echo "  # use the 'docker swarm join --token ...' command printed above on BM2 and BM3"
echo

# ------------------------------------------------------------------------------
# 2. Node labels (rerun after BM2 + BM3 join — see comment below)
# ------------------------------------------------------------------------------
log "Labelling local node as sentry.role=data"
docker node update --label-add sentry.role=data "$(docker node ls --filter "role=manager" --format '{{.Hostname}}' | head -1)"

cat <<'EOF'

After BM2 and BM3 have joined, run on BM1:

  docker node ls                     # confirm 3 managers visible
  docker node update --label-add sentry.role=app  <BM2-hostname>
  docker node update --label-add sentry.role=edge <BM3-hostname>

EOF

# ------------------------------------------------------------------------------
# 3. Build local images (BM1 only — distribute to BM2/BM3 below)
# ------------------------------------------------------------------------------
log "Building sentry-self-hosted-local:${SENTRY_VERSION}"
docker build -t "sentry-self-hosted-local:${SENTRY_VERSION}" \
  --build-arg "SENTRY_IMAGE=ghcr.io/getsentry/sentry:${SENTRY_VERSION}" \
  ./sentry

log "Building clickhouse-self-hosted-local:${SENTRY_VERSION}"
docker build -t "clickhouse-self-hosted-local:${SENTRY_VERSION}" \
  --build-arg "BASE_IMAGE=altinity/clickhouse-server:25.3.6.10034.altinitystable" \
  ./clickhouse

log "Building sentry-cleanup-self-hosted-local:${SENTRY_VERSION}"
docker build -t "sentry-cleanup-self-hosted-local:${SENTRY_VERSION}" \
  --build-arg "BASE_IMAGE=sentry-self-hosted-local:${SENTRY_VERSION}" \
  ./cron

# ------------------------------------------------------------------------------
# 4. Distribute images to BM2 and BM3
# ------------------------------------------------------------------------------
LOCAL_IMAGES=(
  "sentry-self-hosted-local:${SENTRY_VERSION}"
  "clickhouse-self-hosted-local:${SENTRY_VERSION}"
  "sentry-cleanup-self-hosted-local:${SENTRY_VERSION}"
)

if [[ -n "${REGISTRY:-}" ]]; then
  log "Pushing images to $REGISTRY"
  for img in "${LOCAL_IMAGES[@]}"; do
    docker tag "$img" "${REGISTRY}/${img}"
    docker push "${REGISTRY}/${img}"
  done
  echo
  echo "RUN-ON-BM2 and RUN-ON-BM3 (pull each image):"
  for img in "${LOCAL_IMAGES[@]}"; do
    echo "  docker pull ${REGISTRY}/${img} && docker tag ${REGISTRY}/${img} ${img}"
  done
else
  log "No REGISTRY set — saving images and copying via ssh to BM2 ($BM2_IP) and BM3 ($BM3_IP)"
  for img in "${LOCAL_IMAGES[@]}"; do
    log "  shipping $img → BM2"
    docker save "$img" | ssh_to "$BM2_IP" 'docker load'
    log "  shipping $img → BM3"
    docker save "$img" | ssh_to "$BM3_IP" 'docker load'
  done
fi

# ------------------------------------------------------------------------------
# 5. Named volumes on BM1
# ------------------------------------------------------------------------------
log "Creating BM1-pinned volumes (data tier)"

# ClickHouse on dedicated NVMe — bind-mount /mnt/clickhouse if it exists.
if [[ -d /mnt/clickhouse ]]; then
  log "  /mnt/clickhouse detected — bind-mounting sentry-clickhouse to dedicated NVMe"
  mkdir -p /mnt/clickhouse/data /mnt/clickhouse/log
  docker volume create --driver local --opt type=none --opt device=/mnt/clickhouse/data --opt o=bind sentry-clickhouse     2>/dev/null || true
  docker volume create --driver local --opt type=none --opt device=/mnt/clickhouse/log  --opt o=bind sentry-clickhouse-log 2>/dev/null || true
else
  log "  /mnt/clickhouse NOT detected — creating ClickHouse volumes on /var/lib/docker (root disk)"
  log "  WARNING: ClickHouse data will share the root NVMe with Postgres/Kafka. Consider mounting"
  log "           the second 500 GB NVMe at /mnt/clickhouse before running this script. See"
  log "           docs/multinode-setup.md §'Disk layout'."
  docker volume create sentry-clickhouse     2>/dev/null || true
  docker volume create sentry-clickhouse-log 2>/dev/null || true
fi

for v in sentry-postgres sentry-kafka sentry-kafka-log sentry-secrets; do
  docker volume create "$v" 2>/dev/null || true
done

# ------------------------------------------------------------------------------
# 6. daemon.json on BM1
# ------------------------------------------------------------------------------
log "Writing /etc/docker/daemon.json (nofile=262144). Will need to restart docker."
if [[ -w /etc/docker ]] || [[ "$(id -u)" == "0" ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 262144, "Hard": 262144 }
  }
}
JSON
  log "  /etc/docker/daemon.json written. Run 'systemctl restart docker' on BM1 when ready."
else
  log "  Not running as root — skipping. As root, write this to /etc/docker/daemon.json:"
  cat <<'JSON'
{
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 262144, "Hard": 262144 }
  }
}
JSON
fi

cat <<EOF

================================================================================
NEXT STEPS — run these manually on BM2 and BM3:

RUN-ON-BM2 (the "app" tier, 48 GB):
  # 1. Join Swarm: paste the join command from above
  # 2. /etc/docker/daemon.json: same content as BM1, then 'systemctl restart docker'
  # 3. Sync the repo from BM1 (run this FROM BM1):
  ${RSYNC_HINT}/opt/sentry/self-hosted/ ${SSH_USER}@${BM2_IP}:/opt/sentry/self-hosted/
  # 4. Create app-tier volumes (run this ON BM2):
  docker volume create sentry-data
  docker volume create sentry-seaweedfs
  docker volume create sentry-symbolicator
  docker volume create sentry-vroom
  docker volume create sentry-taskbroker

RUN-ON-BM3 (the "edge" tier, 32 GB):
  # 1. Join Swarm: paste the join command from above
  # 2. /etc/docker/daemon.json: same content as BM1, then 'systemctl restart docker'
  # 3. Sync the repo from BM1 (run this FROM BM1):
  ${RSYNC_HINT}/opt/sentry/self-hosted/ ${SSH_USER}@${BM3_IP}:/opt/sentry/self-hosted/
  # 4. Create edge-tier volumes (run this ON BM3):
  docker volume create sentry-redis
  docker volume create sentry-smtp
  docker volume create sentry-smtp-log
  docker volume create sentry-nginx-cache
  docker volume create sentry-nginx-www

THEN — back on BM1:
  docker node ls                     # confirm 3 managers visible
  docker node update --label-add sentry.role=app  <BM2-hostname>
  docker node update --label-add sentry.role=edge <BM3-hostname>
  # The bootstrap script picks up SSH_KEY/SSH_USER from the environment, so
  # if you exported them for this script, just keep them exported (or use
  # \`sudo -E …\`) before running:
  bash scripts/swarm-bootstrap-sentry.sh
================================================================================
EOF
