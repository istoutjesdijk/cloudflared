# cloudflared

A Cloudflare Tunnel connector you can deploy from Coolify, pinned to a version
and updated automatically once that version has proved itself.

Coolify ships cloudflared as a one-click service. That service has no git
source, so it never redeploys on its own and the image it started with is the
image it keeps. This repository is the same connector as a Docker Compose
application instead: Coolify follows the repository, a workflow bumps the pin
when Cloudflare publishes a release, and the merge is what deploys.

## Setup

1. Fork or copy this repository. It can stay public; no secret belongs in it.
2. In Coolify, create an application per host you want to expose:
   - source: your GitHub App, this repository, branch `main`
   - build pack: **Docker Compose**, compose location `/compose.yml`
   - leave "Connect To Predefined Network" off and set no domain
3. Set `CLOUDFLARE_TUNNEL_TOKEN` on each application, taken from Cloudflare
   Zero Trust > Networks > Tunnels. See `.env.example` for the rest.
4. Deploy. The connector shows up in Zero Trust; the tunnel's ingress rules stay
   in the Cloudflare dashboard.

Migrating from a running connector on the same host costs no downtime:
Cloudflare accepts several connectors on one tunnel, so deploy this app, wait
for the new connector to appear, then remove the old one.

## How updates happen

`upstream-update.yml` runs every morning, asks GitHub for the latest stable
cloudflared release and, if it differs from `.upstream-ref`, bumps the pin and
runs `ci/smoke.sh` against the new version. Only if that passes does it open a
pull request and merge it. The merge is the deploy: Coolify's GitHub App sees
the push and redeploys every app that follows this repository, each of which
pulls the new image.

`ci/smoke.sh` is the whole safety story, because everything published through a
tunnel disappears at once when its connector is broken. It:

- pulls the tag and checks the binary reports the version it claims to be --
  Docker Hub publishes a tag minutes after the GitHub release, so a bump can
  resolve to a version that is not pullable yet;
- asserts the compose invariants that keep routing intact (host networking, no
  published ports, the expected command, no tunnel without a token);
- runs a real quick tunnel against Cloudflare's edge, fetches the public
  hostname it is given and checks the response came back from the local test
  origin rather than from a Cloudflare error page;
- checks `/ready` reports at least one registered connection, since a connector
  with zero connections still looks alive;
- runs the health check from `compose.yml` inside the container, because Coolify
  derives the app status from it and an upstream build that moved the binary
  would turn every app unhealthy.

Quick tunnels need no credentials, so none of this requires a secret. The same
script runs on every push and pull request through `validate.yml`.

The workflow needs "Allow GitHub Actions to create and approve pull requests"
enabled under Settings > Actions > General, and write permissions for the
workflow token.

## Rolling back

1. Set `CLOUDFLARED_TAG=<older version>` on the affected Coolify app and
   redeploy. Fastest, works per app, leaves git alone.
2. Redeploy an earlier commit from Coolify.
3. Revert the bump commit on `main`, which moves every app back. Put
   `.upstream-ref` on the version you want too, otherwise the next morning's run
   proposes the bad release again.

## Running the checks locally

```sh
./ci/smoke.sh            # the pinned version
./ci/smoke.sh 2026.8.3   # some other version
```

Needs Docker and outbound access to Cloudflare. It binds port 18080 for the test
origin and 20241 for the metrics listener; override with `SMOKE_ORIGIN_PORT` and
`SMOKE_METRICS_PORT` if those are taken. The deployed container leaves its
metrics port unset so two connectors can share a host; the smoke test asks for
one explicitly because it reads `/ready`.
