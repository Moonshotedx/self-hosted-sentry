#!/usr/bin/env bash
#
# Bootstrap Sentry application state after the first `docker stack deploy`.
#
# Run this ONCE on BM1 after:
#   1. docker stack deploy --compose-file docker-stack.yml sentry  has succeeded
#   2. All services show "1/1" (or "2/2" for snuba-replays-consumer) in `docker stack services sentry`
#
# What it does (in order):
#   1. Generates and pins SENTRY_SYSTEM_SECRET_KEY in .env.custom (if missing).
#   2. Sets up relay/config.yml from the example (relay needs BOTH config.yml and
#      credentials.json to recognise its config folder — without config.yml,
#      relay logs "launching relay without config folder" and ignores creds).
#      Generates relay/credentials.json (if missing).
#   3. Downloads GeoIP databases.
#   4. Creates the 13 ingest Kafka topics (Sentry consumers don't auto-create;
#      broker has auto.create.topics.enable=false).
#   5. Creates SeaweedFS buckets: `nodestore`, `profiles`. Applies lifecycle rules
#      keyed to SENTRY_EVENT_RETENTION_DAYS.
#   6. Runs sentry upgrade --noinput (schema migrations).
#   7. Runs snuba bootstrap + migrations.
#   8. Prompts to create the first superuser AND to set system.url-prefix
#      (without which login hits "CSRF Validation Failed").

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source .env

log() { printf "\n\033[1;32m[%s]\033[0m %s\n" "bootstrap" "$*"; }
warn() { printf "\n\033[1;33m[%s]\033[0m %s\n" "bootstrap" "$*"; }
err() { printf "\n\033[1;31m[%s]\033[0m %s\n" "bootstrap" "$*"; exit 1; }

# A small helper that finds the running task container ID for a given service
# on the local node (BM1), retrying for up to 60s in case the service is restarting.
find_local_container() {
  local svc="$1"
  for _ in $(seq 1 30); do
    local cid
    cid="$(docker ps --filter "label=com.docker.swarm.service.name=sentry_${svc}" --format '{{.ID}}' | head -1)"
    if [[ -n "$cid" ]]; then
      echo "$cid"
      return 0
    fi
    sleep 2
  done
  err "Could not find a running ${svc} container on this node. Check 'docker stack ps sentry'."
}

# ------------------------------------------------------------------------------
# 1. Reuse install/* fragments for secret + relay + geoip
# ------------------------------------------------------------------------------
if [[ ! -f .env.custom ]] || ! grep -q '^SENTRY_SYSTEM_SECRET_KEY=' .env.custom 2>/dev/null; then
  log "Generating SENTRY_SYSTEM_SECRET_KEY → .env.custom"
  SECRET_KEY=$(openssl rand -hex 25)
  printf 'SENTRY_SYSTEM_SECRET_KEY=%s\n' "$SECRET_KEY" >> .env.custom
  unset SECRET_KEY
fi

# Relay config.yml must exist BEFORE credentials are loaded. Without it,
# relay prints "launching relay without config folder" and ignores any
# credentials.json sitting next to it. The example config uses overlay-DNS
# hostnames (web:9000, kafka:9092, redis://redis:6379) which work as-is.
if [[ ! -f relay/config.yml ]]; then
  log "Seeding relay/config.yml from relay/config.example.yml"
  cp relay/config.example.yml relay/config.yml
fi

if [[ ! -f relay/credentials.json ]]; then
  log "Generating relay/credentials.json"
  # The relay CLI does NOT support -o; use --stdout and shell redirect instead.
  # `docker run` works here without exec'ing into the running container,
  # which means we can generate creds on BM1 even though the long-running
  # relay container is pinned to BM3 (we then rsync the file across below).
  RELAY_IMAGE_REF="${RELAY_IMAGE:-ghcr.io/getsentry/relay:${SENTRY_VERSION:-26.4.2}}"
  docker pull "$RELAY_IMAGE_REF" >/dev/null
  docker run --rm --entrypoint relay "$RELAY_IMAGE_REF" \
    credentials generate --stdout > relay/credentials.json
  if ! [[ -s relay/credentials.json ]] || ! grep -q '"public_key"' relay/credentials.json; then
    err "relay credentials generation produced an invalid file. Check 'cat relay/credentials.json'."
  fi
  warn "relay/credentials.json was generated on BM1. The relay container is pinned to BM3."
  warn "Sync the file (and relay/config.yml) to BM3 before relay can start:"
  warn "  rsync -a relay/ root@<BM3-IP>:/opt/sentry/self-hosted/relay/"
fi

if [[ ! -f geoip/GeoLite2-City.mmdb ]]; then
  log "Downloading GeoIP DBs (geoip/)"
  bash install/geoip.sh
fi

# ------------------------------------------------------------------------------
# 2. Kafka ingest topics
#    Sentry's consumers subscribe to these topics but don't trigger topic
#    auto-creation (only producers do). Broker has auto.create.topics.enable=false,
#    so missing topics → consumers crash-loop every 3-6s on UNKNOWN_TOPIC_OR_PART,
#    which puts BM2 at >80% CPU. Create them upfront, idempotently.
#    Snuba creates its own snuba-* topics during `snuba bootstrap` below; these
#    are the ingest-side ones that Sentry needs.
# ------------------------------------------------------------------------------
KAFKA_CID="$(find_local_container kafka)"
INGEST_TOPICS=(
  ingest-attachments
  ingest-events
  ingest-transactions
  ingest-metrics
  ingest-performance-metrics
  ingest-replay-recordings
  ingest-feedback-events
  ingest-occurrences
  profiles
  buffered-segments
  ingest-spans
  monitors-clock-tasks
  uptime-results
)
log "Creating Kafka ingest topics (idempotent)"
for topic in "${INGEST_TOPICS[@]}"; do
  docker exec "$KAFKA_CID" kafka-topics --bootstrap-server localhost:9092 \
    --create --if-not-exists --topic "$topic" \
    --partitions 1 --replication-factor 1 >/dev/null
done
log "Created/verified ${#INGEST_TOPICS[@]} ingest topics"

# ------------------------------------------------------------------------------
# 3. SeaweedFS buckets + lifecycle policies
#    SeaweedFS is pinned to BM2; this requires running s3cmd against the
#    overlay-network DNS name from a container on BM2. We exec into the local
#    seaweedfs container if available, otherwise tell the operator to run on BM2.
# ------------------------------------------------------------------------------
SEAWEED_CID="$(docker ps --filter "label=com.docker.swarm.service.name=sentry_seaweedfs" --format '{{.ID}}' | head -1 || true)"
if [[ -z "$SEAWEED_CID" ]]; then
  warn "SeaweedFS not running on this host (it's pinned to BM2)."
  warn "SSH to BM2 and run this script there for the SeaweedFS section, or run the s3cmd"
  warn "commands manually from a container that can reach 'seaweedfs:8333' on the overlay."
else
  log "Installing s3cmd inside SeaweedFS (one-shot)"
  docker exec "$SEAWEED_CID" apk add --no-cache s3cmd >/dev/null

  S3CMD_PREFIX="docker exec $SEAWEED_CID s3cmd --access_key=sentry --secret_key=sentry --no-ssl --region=us-east-1 --host=localhost:8333 --host-bucket=localhost:8333/%(bucket)"

  for bucket in nodestore profiles; do
    if ! $S3CMD_PREFIX ls 2>/dev/null | grep -q "s3://${bucket}"; then
      log "Creating bucket s3://${bucket}"
      $S3CMD_PREFIX mb "s3://${bucket}"
    else
      log "Bucket s3://${bucket} already exists"
    fi
  done

  # Lifecycle policies — adapted from install/bootstrap-s3-{profiles,nodestore}.sh
  RETENTION="${SENTRY_EVENT_RETENTION_DAYS:-7}"
  for bucket in profiles nodestore; do
    log "Applying ${RETENTION}-day lifecycle policy to s3://${bucket}"
    LIFECYCLE_XML=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<LifecycleConfiguration>
    <Rule>
        <ID>Sentry-${bucket}-Rule</ID>
        <Status>Enabled</Status>
        <Filter></Filter>
        <Expiration>
            <Days>${RETENTION}</Days>
        </Expiration>
    </Rule>
</LifecycleConfiguration>
EOF
)
    docker exec "$SEAWEED_CID" sh -c "printf '%s' '$LIFECYCLE_XML' > /tmp/${bucket}-lc.xml"
    $S3CMD_PREFIX setlifecycle "/tmp/${bucket}-lc.xml" "s3://${bucket}"
  done
fi

# ------------------------------------------------------------------------------
# 4. Sentry schema migrations
# ------------------------------------------------------------------------------
WEB_CID="$(docker ps --filter "label=com.docker.swarm.service.name=sentry_web" --format '{{.ID}}' | head -1 || true)"
if [[ -z "$WEB_CID" ]]; then
  warn "sentry_web is not running on this host (it's pinned to BM2). SSH to BM2 and run:"
  warn "  docker exec \$(docker ps -qf name=sentry_web) sentry upgrade --noinput"
  warn "  docker exec -it \$(docker ps -qf name=sentry_web) sentry createuser --email <admin@example.com> --superuser"
else
  log "Running sentry upgrade (database migrations)"
  docker exec "$WEB_CID" sentry upgrade --noinput
  log "All migrations applied. Create the first superuser interactively:"
  echo "  docker exec -it $WEB_CID sentry createuser --email <admin@example.com> --superuser"
fi

# ------------------------------------------------------------------------------
# 5. Snuba bootstrap + migrations (BM1 — local to this script)
# ------------------------------------------------------------------------------
SNUBA_CID="$(find_local_container snuba-api)"
log "Running snuba bootstrap (idempotent)"
docker exec "$SNUBA_CID" snuba bootstrap --force --no-migrate || true
log "Running snuba migrations migrate"
docker exec "$SNUBA_CID" snuba migrations migrate --force

cat <<EOF

================================================================================
Sentry multinode bootstrap complete (BM1 portion).

Still required — must run BY HAND because the target containers aren't on BM1:

  ON BM3 (or rsync the relay/ dir from here):
    rsync -a /opt/sentry/self-hosted/relay/ root@<BM3-IP>:/opt/sentry/self-hosted/relay/

  ON BM2 (sentry_web is pinned there):
    WEB=\$(sudo docker ps -qf "label=com.docker.swarm.service.name=sentry_web")
    sudo docker exec    "\$WEB" sentry upgrade --noinput          # idempotent
    sudo docker exec -it "\$WEB" sentry createuser --superuser

  ON BM1 (fix CSRF before browser login — otherwise login fails with
  "CSRF Validation Failed" because system.url-prefix defaults to
  http://localhost:9000):
    sed -i "s|^# system.url-prefix:.*|system.url-prefix: 'http://<BM3-IP>:${SENTRY_BIND:-9000}'|" \\
      sentry/config.yml
    rsync -a sentry/config.yml root@<BM2-IP>:/opt/sentry/self-hosted/sentry/config.yml
    docker service update --force sentry_web

Then verify:
  * docker stack services sentry              (all REPLICAS at desired count)
  * curl http://<BM3-IP>:${SENTRY_BIND:-9000}/_health/    → "ok"
  * Browse http://<BM3-IP>:${SENTRY_BIND:-9000} and log in as the superuser.
  * Send a test event using the SDK with the DSN from your new project.
  * Read docs/multinode-setup.md §"Verification" for full smoke tests.
================================================================================
EOF
