# birdhaus-watch: operator alerts

A small heartbeat and probe monitor that emails the operator when something breaks. It runs in AWS (Lambda, EventBridge Scheduler, DynamoDB, SES), not on Datum, so a Datum outage can't silence it.

## What is watched

Defined in `checks.json`; each check carries the "what to check" text that goes into its alert.

| Check | How | Down when |
|---|---|---|
| `postgres` | Heartbeat: the Postgres entrypoint reports every 5 minutes | It reports a problem, or is silent for over 15 minutes (instance, network or location down) |
| `auth` | Probe of `https://login.birdhaus.store/auth/v1/health` | Not 200; sign-in and account pages are down (guest checkout keeps working) |
| `store` | Probe of `https://birdhaus.store/api/health` | Not 200; the body names the database or webhook as failing |
| `checkout` | Probe of `https://birdhaus.store/api/batch` | Not 200 |
| `umami` | Probe of `https://stats.birdhaus.store/api/heartbeat` and `/t.js` | Not 200 |

The Postgres watchdog (`postgres/entrypoint.sh`, `watch_loop`) reports a problem when:
- Postgres isn't accepting connections, or is still recovering 15 minutes after boot;
- the most recent WAL archive attempt failed (writes are not reaching S3);
- more than 3 WAL segments are waiting to be archived;
- the newest base backup is 26 hours old or more;
- the data disk is over 85% full.

Probes alert after 2 failed sweeps in a row. A reported Postgres problem alerts at once.

## Email

- **DOWN** when a check goes down, with the reason and what to check. **STILL DOWN** every 24 hours while it stays down. **RECOVERED** when it's healthy again.
- **Weekly status** on Mondays at 9:00 US Central. If it stops arriving, the watcher itself is broken.
- Sent through SES from `alerts@birdhaus.store`, signed with DKIM. The records are generated into `dns/ses.yaml` by `ops/aws-account.hs setup` and applied by hand. SES is in sandbox mode, so it only delivers to verified addresses. That suits a single operator; adding a recipient means verifying it in SES too.
- If an email fails to send, the state is kept and the next sweep (5 minutes later) retries it.

Stripe separately emails the account owner when webhook deliveries keep failing.

## Operate

```sh
export AWS_PROFILE=<profile>
./ops/watch/deploy.hs deploy --to <email> --project <datum-project>   # create or update everything
./ops/watch/deploy.hs status       # each check's state
./ops/watch/deploy.hs sweep        # run a sweep now
./ops/watch/deploy.hs test-alert   # send a test email
./ops/watch/deploy.hs dkim         # the SES DKIM records, as YAML
./ops/watch/deploy.hs destroy      # delete the schedules, Lambda, table, roles and identities
```

`ops/aws-account.hs setup` runs `deploy` and writes its `dkim` output to `dns/ses.yaml`.

- `deploy` is idempotent. Changing `checks.json` or `lambda/index.mjs` takes effect on the next `deploy`.
- Per-check tokens are generated once and kept. Postgres gets its URL and token from the Datum Secret `birdhaus-db-watch` (`WATCH_URL`, `WATCH_CHECK`, `WATCH_TOKEN`); `postgres/deploy.hs` attaches it when it exists. To rotate, delete the Secret and remove `TOKENS` from the Lambda's environment, run `deploy`, then redeploy Postgres.
- A heartbeat check that has never reported alerts 15 minutes after the watcher first sees it, so a misconfigured pinger is caught.

## Tested (2026-10-28)

- **WAL failure:** detaching the IAM policy from the database's AWS user made archiving fail. The watchdog reported "WAL archiving to S3 is failing" 4.5 minutes later. After reattaching, archiving caught up (no WAL left queued) and the check recovered at the next report.
- **Real outage:** on its first sweep the watcher found birdhaus.store returning 503. A platform event had replaced the database instance and left the store's network attachment unprogrammed ("the attachment has no network advertisement"). `datumctl compute restart birdhaus-store` fixed it.
