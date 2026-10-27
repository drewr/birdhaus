# Analytics (Umami)

Self-hosted [Umami](https://umami.is) 3.4.1 at https://stats.birdhaus.store, storing its data in the `umami` database of the S3-backed Postgres (`postgres/README.md`). It runs as the general-purpose workload `birdhaus-umami` in the `birdhaus` Network.

## Deploy

```sh
./umami/deploy.hs --project <project>
```

On first run it creates the Secret `birdhaus-umami` (`DATABASE_URL`, `APP_SECRET`). The database host is `db.birdhaus.store` (`dns/aaaa.yaml`), not an IPv6 literal, because Umami's runtime driver cannot parse a bracketed address. The image is pinned by digest in `deploy.hs`; to upgrade, change the digest and redeploy (Umami runs its own migrations on start).

The image binds `0.0.0.0` by default, which an IPv6-only instance cannot serve, so the workload sets `HOSTNAME=::`.

## Tracking

`index.html` loads `https://stats.birdhaus.store/t.js` with the website ID. The script is renamed from `script.js` and collects at `/api/t` instead of `/api/send`, which ad blockers match less often. `data-domains="birdhaus.store"` keeps local development out of the stats.

## Login

User `admin`. The default password was replaced at setup; the current one is in the Secret `birdhaus-umami-admin`:

```sh
datumctl get secret birdhaus-umami-admin -o jsonpath='{.data.password}' | base64 -d
```

If you change it in the Umami UI, update the Secret too.
