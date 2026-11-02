# Rollouts without downtime

## Context

Prod runs two instances so a deploy can replace one while the other serves. Two
things could still drop requests:

- **The edge can route to an instance that isn't answering.** Datum has no
  readiness probe, so it decides for itself when a new instance is ready.
- **The old instance can stop mid-request.** Node exited on `SIGTERM` at once,
  dropping requests still in progress and any the edge was still sending.

## What Datum offers

These are from `datumctl explain` on 2026-11-01:

- **No readiness or liveness probe.** A Workload container has no probe
  fields. `instanceManagementPolicy: OrderedReady` only says it controls how
  instances are managed during scaling and maintenance. We can't define what
  ready means.
- **A passive health check on the HTTPProxy** (`spec.healthCheck.passive`).
  This is Envoy outlier detection: after a number of 5xx replies in a row, the
  edge stops sending to that instance for a while, then tries it again. It
  never replaces the instance. Unset, every instance counts as healthy.
- **`terminationGracePeriodSeconds`** on `spec.template.spec.runtime`. This is
  how long an instance has between `SIGTERM` and a kill. Above zero needs a
  runtime class that supports graceful termination; unikernel accepted 30.

## Design

- **The server drains on `SIGTERM`** (end of `server/index.js`):
  - For 10 seconds it keeps answering, in case the edge still routes there.
    Every reply carries `Connection: close`, so the edge's pooled connections
    move to the other instance.
  - Then it stops accepting connections, lets requests in progress finish, and
    exits.
- **`run.hs` gives the instance 30 seconds** to do that
  (`terminationGracePeriodSeconds: 30`). Past that it is killed anyway.
- **`run.hs` sets the passive health check on the HTTPProxy**:
  - 3 failures in a row set the instance aside for 30 seconds, and longer if
    it keeps failing.
  - Never more than half the instances are set aside at once.
  - Envoy counts refused connections as 5xx too, so this also catches an
    instance that isn't listening.
- **`run.hs` applies the proxy before the workload**, so the health check is
  already in place when instances start being replaced.

`/api/health` returns 503 while the database, the webhook or the geocoder is
failing. If health checks happen to hit the same instance three times in a row
during such an outage, that instance is set aside. Because of the 50% cap the
other instance keeps serving.

## Measurements

All runs were on dev (`dev.birdhaus.store`), raised to two instances for the
test on 2026-11-02. Each run changed only the version label, which made Datum
replace both instances. A probe fetched `/api/health` every half second, with a
3-second timeout, from just before the deploy until 60 seconds after `run.hs`
saw the new version. In the last two runs the probe also fetched a product photo
(static, no database) and recorded the database field and each response time.

| Run | Instances being replaced | New instances | Probes | Failed |
|---|---|---|---|---|
| Baseline | no drain | no drain, no health check | 224 | 1 timeout |
| Fix, first deploy | no drain | drain, health check | 247 | 1 timeout |
| Fix | drain | drain, health check | 269 | 0 |
| Fix | drain | drain, health check | 256 | 23 (see below) |
| Fix | drain | drain, health check | 239 | 0 |
| Fix | drain | drain, health check | 242 | 0 |

Both single timeouts landed while the second instance was being replaced. In
the four runs with the fix on both sides, the old and new versions answered
alternately for a moment, which is the drain doing its job. In the last two
runs no reply took longer than 0.13 seconds.

**The run with 23 failures is unexplained.**
- The failures were 17 timeouts and 6 503s, starting at 02:33:13 UTC. The
  replacement had finished by 02:33:29, but failures kept arriving, mixed in
  with successes, for about 75 seconds after that.
- Some of the 503s came from the app: their reply carried the new version, so
  `/api/health` answered and reported something failing.
- The timeouts fit a new instance waiting 3 seconds for Postgres. That probe
  didn't record reply bodies, so this isn't confirmed.
- The later runs recorded the database field and a static page, and both were
  clean.

If it happens again, the probe's database field and the static page will show
whether the database or the routing failed.

**The first prod rollout with the fix** (`v0.99.2` to `v0.99.3`, 2026-11-02):
1 failure in 329 probes. At 03:00:42 UTC one health request waited 5.7 seconds
and got a 503 from the edge, not from the app. The next probe, half a second
later, got `v0.99.3`, and every later probe got it too. The old instances
weren't draining yet, because `v0.99.2` had no `SIGTERM` handler, so this run
matches the "fix, first deploy" row above. The next prod release is the first
where both sides drain.

## Other findings

- **`OrderedReady` did not keep a working instance serving when the new image
  couldn't be pulled.** On 2026-11-02 the `ghcr-drewr` pull secret held a GHCR
  token GitHub no longer accepted. A deploy moved dev's running instance onto
  the new image anyway, both instances stuck at `ImageUnavailable`, and dev
  served the edge's "service offline" page for over two hours. On prod, a bad
  image or pull secret would probably take down both instances.
- **Fixing the secret didn't recover the instances.** Twenty minutes after the
  secret was replaced they were still `ImageUnavailable`, with no new events.
  A redeploy brought dev back.

## Open questions for Datum

- When does Datum count a unikernel instance as ready, and could the Workload
  take an HTTP readiness probe?
- Should `OrderedReady` keep the old instance until its replacement is ready,
  including when the image can't be pulled?
- Should an instance retry the pull when its pull secret changes, and how often
  does it retry otherwise?
- When does the edge stop routing to an instance after it gets `SIGTERM`? The
  10-second drain is a guess that covers it in practice.

## Open work

- **Check the pull secret before deploying.** `run.hs` could test the pull
  secret against GHCR and stop before deploying, rather than finding out from a
  stuck instance. A check in `ops/watch/checks.json` could catch an expiring
  token before the next deploy.
