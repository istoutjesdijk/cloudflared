#!/usr/bin/env bash
# Proves that a given cloudflared version actually works before it is allowed
# into production. Both workflows call this: upstream-update.yml runs it on the
# version it wants to propose and only opens a PR if it passes, validate.yml
# runs it on whatever is pinned in the repo.
#
# Everything published through a tunnel disappears at once when its connector is
# broken, so this does not settle for "the container started": it stands up a
# real quick tunnel against Cloudflare's edge and pulls traffic back through it.
# Quick tunnels need no credentials, so the whole gate runs on a public repo
# without a single secret.
#
# Usage: ci/smoke.sh [version]   (default: contents of .upstream-ref)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(cat .upstream-ref)}"
IMAGE="cloudflare/cloudflared:${VERSION}"
ORIGIN_PORT="${SMOKE_ORIGIN_PORT:-18080}"
METRICS_PORT="${SMOKE_METRICS_PORT:-20241}"
ORIGIN_NAME="cfd-smoke-origin"
TUNNEL_NAME="cfd-smoke-tunnel"
MARKER="cfd-smoke-$(date +%s)-$$"
TUNNEL_ATTEMPTS=3

log()  { printf '\n=== %s\n' "$*"; }
fail() { printf '\n::error::%s\n' "$*" >&2; exit 1; }

cleanup() { docker rm -f "$TUNNEL_NAME" "$ORIGIN_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

log "cloudflared ${VERSION}"

# --- 1. the tag exists and the binary runs -----------------------------------
# Docker Hub publishes a tag some minutes after the GitHub release, so a bump
# can legitimately resolve to a version that is not pullable yet. Better to fail
# here than to send an unpullable tag to every host at once.
docker pull "$IMAGE" >/dev/null || fail "cannot pull ${IMAGE}"

reported="$(docker run --rm "$IMAGE" --version)"
echo "$reported"
grep -qF "$VERSION" <<<"$reported" \
  || fail "image reports '${reported}', expected version ${VERSION}"

# --- 2. compose invariants ---------------------------------------------------
log "compose.yml invariants"

rendered="$(CLOUDFLARE_TUNNEL_TOKEN=smoke-token CLOUDFLARED_TAG="$VERSION" \
            docker compose -f compose.yml config --format json)"
python3 ci/check_compose.py "$VERSION" <<<"$rendered"

# The token has no default on purpose: an app deployed without one must refuse
# to render rather than start a connector that can never authenticate.
if CLOUDFLARED_TAG="$VERSION" docker compose -f compose.yml config --quiet 2>/dev/null; then
  fail "compose renders without CLOUDFLARE_TUNNEL_TOKEN; the :? guard is gone"
fi

pinned="$(cat .upstream-ref)"
grep -qF "CLOUDFLARED_TAG:-${pinned}" compose.yml \
  || fail "compose.yml pin does not match .upstream-ref (${pinned})"

# --- 3. a real tunnel, end to end --------------------------------------------
log "end-to-end tunnel"

docker run -d --name "$ORIGIN_NAME" --network host \
  -e WHOAMI_PORT_NUMBER="$ORIGIN_PORT" \
  -e WHOAMI_NAME="$MARKER" \
  traefik/whoami >/dev/null

origin_body=""
for _ in $(seq 1 30); do
  origin_body="$(curl -sf "http://127.0.0.1:${ORIGIN_PORT}/" || true)"
  [ -n "$origin_body" ] && break
  sleep 1
done
# The marker doubles as proof that this is our origin and not some other
# service that already held the port -- with host networking that is a real
# possibility, and it would make the rest of this test meaningless.
grep -qF "Name: ${MARKER}" <<<"$origin_body" || {
  docker logs "$ORIGIN_NAME" 2>&1 | tail -20
  fail "nothing answering as our origin on 127.0.0.1:${ORIGIN_PORT}; is the port taken?"
}

# Quick tunnels are a free service and occasionally refuse or take their time.
# A flaky edge must not read as a broken release, hence the retries.
tunnel_ok=0
for attempt in $(seq 1 "$TUNNEL_ATTEMPTS"); do
  echo "--- attempt ${attempt}/${TUNNEL_ATTEMPTS}"
  docker rm -f "$TUNNEL_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$TUNNEL_NAME" --network host "$IMAGE" \
    tunnel --no-autoupdate \
           --metrics "127.0.0.1:${METRICS_PORT}" \
           --url "http://127.0.0.1:${ORIGIN_PORT}" >/dev/null

  url=""
  for _ in $(seq 1 45); do
    url="$(docker logs "$TUNNEL_NAME" 2>&1 \
           | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 || true)"
    [ -n "$url" ] && break
    sleep 2
  done
  if [ -z "$url" ]; then
    echo "no quick tunnel hostname appeared"
    docker logs --tail 30 "$TUNNEL_NAME" 2>&1 || true
    continue
  fi
  echo "tunnel: $url"

  # Wait for the hostname to exist before asking a resolver for it. The DNS
  # record shows up a few seconds after the URL is printed, and the negative
  # answer in between is cached for the half hour that trycloudflare.com's SOA
  # asks for -- one early lookup and this hostname is unusable for the rest of
  # the run. DNS over HTTPS answers straight from Cloudflare and leaves no
  # negative entry behind in the local resolver.
  host="${url#https://}"
  resolved=0
  for _ in $(seq 1 24); do
    if curl -sf --max-time 10 -H 'accept: application/dns-json' \
         "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
       | grep -q '"Answer"'; then
      resolved=1
      break
    fi
    sleep 5
  done
  if [ "$resolved" != 1 ]; then
    echo "hostname never got a DNS record"
    docker logs --tail 30 "$TUNNEL_NAME" 2>&1 || true
    continue
  fi

  edge_body=""
  status=""
  for _ in $(seq 1 10); do
    status="$(curl -s -o /tmp/cfd-smoke-edge.out -w '%{http_code}' --max-time 15 "$url/" || true)"
    if [ "$status" = "200" ]; then
      edge_body="$(cat /tmp/cfd-smoke-edge.out)"
      break
    fi
    sleep 5
  done
  if [ -z "$edge_body" ]; then
    echo "edge did not serve the tunnel (last status: ${status:-none})"
    head -c 500 /tmp/cfd-smoke-edge.out 2>/dev/null || true
    docker logs --tail 30 "$TUNNEL_NAME" 2>&1 || true
    continue
  fi

  # Cloudflare serves some of its own error pages with a 200, so the status
  # code alone proves nothing. The marker only exists in our origin.
  if ! grep -qF "Name: ${MARKER}" <<<"$edge_body"; then
    echo "edge answered 200 but not from our origin"
    head -c 500 <<<"$edge_body"
    continue
  fi

  tunnel_ok=1
  break
done
[ "$tunnel_ok" = 1 ] || fail "cloudflared ${VERSION} could not serve traffic over a tunnel"
echo "traffic reached the Cloudflare edge and came back to the origin"

# --- 4. the connector registered with the edge -------------------------------
# A process that is up with zero connections passes every liveness check ever
# written and still routes nothing.
log "/ready"
ready="$(curl -sf --max-time 10 "http://127.0.0.1:${METRICS_PORT}/ready")" \
  || fail "metrics endpoint did not answer on ${METRICS_PORT}"
echo "$ready"
python3 -c "
import json, sys
n = json.loads(sys.argv[1]).get('readyConnections', 0)
if n < 1:
    sys.exit(f'::error::readyConnections is {n}; the connector registered nothing')
print(f'readyConnections: {n}')
" "$ready"

# --- 5. the health check Coolify will run ------------------------------------
# Coolify evaluates the health check inside the container and derives the app
# status from it. An upstream build that drops or moves the binary turns every
# app running:unhealthy while the tunnel itself looks fine.
log "health check inside the container"
hc="$(python3 -c "
import json, sys
print(' '.join(json.load(sys.stdin)['services']['cloudflared']['healthcheck']['test'][1:]))
" <<<"$rendered")"
echo "running: $hc"
docker exec "$TUNNEL_NAME" $hc >/dev/null \
  || fail "health check '${hc}' fails inside the container"

log "cloudflared ${VERSION} passed"
