# Accounts and sign-in (Rauthy)

Self-hosted [Rauthy](https://github.com/sebadob/rauthy) 0.37.2 at https://login.birdhaus.store, storing users and clients in the `auth` database of the S3-backed Postgres. It runs as the general-purpose workload `birdhaus-auth` in the `birdhaus` Network. Design: [`docs/design/accounts.md`](../docs/design/accounts.md).

## Deploy

Prerequisites: `datumctl` on PATH, the Postgres workload is running, and you know the Mailgun SMTP credentials. Run from the repo root.

1. **Add the database.** Put a random password under the key `auth` in the Secret `birdhaus-db-db` (recreate the Secret with all existing keys plus the new one), then redeploy Postgres so its entrypoint creates the database and role:

   ```sh
   ./postgres/deploy.hs --project <project> --workload birdhaus-pg --pull-secret <ghcr-secret>
   ```

   The restart is graceful (WAL switches and drains), so no committed write is lost; the restore takes seconds.

2. **Store the SMTP settings** in their own Secret. Rauthy copies them into `birdhaus-auth` on first run:

   ```sh
   datumctl create -f - --project <project> <<'YAML'
   apiVersion: v1
   kind: Secret
   metadata:
     name: birdhaus-mailgun
     namespace: default
   type: Opaque
   stringData:
     SMTP_URL: smtp.mailgun.org
     SMTP_PORT: "587"
     SMTP_USERNAME: postmaster@birdhaus.store
     SMTP_PASSWORD: <Mailgun SMTP password>
     SMTP_FROM: Birdhaus <login@birdhaus.store>
   YAML
   ```

   The domain already has Mailgun SPF, DKIM, DMARC and MX records (`dns/`).

3. **Deploy the workload** (the Secret `birdhaus-auth` is created on first run):

   ```sh
   ./auth/deploy.hs --project <project> --admin-email <operator email>
   ```

   It prints the admin bootstrap password command, the Google callback URL and the store callback URL. Re-running keeps the existing Secret; delete it and re-run to regenerate the encryption keys and admin password (which invalidates encrypted client secrets, so prefer the admin UI).

4. **Admin and MFA.** Read the bootstrap password, sign in at `https://login.birdhaus.store/admin`, change it, and enable the admin MFA requirement in the security settings.

5. **Google.** In Google Cloud Console create an OAuth consent screen (External) and a Web application client:

   - Authorized redirect URI: `https://login.birdhaus.store/auth/v1/providers/callback`

   Then in Rauthy's **Providers** page add a Google provider with the client ID and secret, and upload the Birdhaus logo.

6. **The store client.** In Rauthy's **Clients** page create `birdhaus-store`:

   - Redirect URI: `https://birdhaus.store/api/auth/callback` (add `http://localhost:4242/api/auth/callback` for local development)
   - PKCE S256, scopes `openid email profile`

   Put the client ID and secret into the store's Secret `birdhaus-store-auth` (`scripts/store-auth-secret.hs`).

## Operate

- **Logs:** `datumctl compute logs birdhaus-auth`. Startup logs the public URL and any config error; a wrong `PUB_URL`, proxy or encryption key panics at boot.
- **Health:** `GET https://login.birdhaus.store/auth/v1/health` (and `/auth/v1/ping`). The watcher probes it through `ops/watch/checks.json`.
- **Restart:** `datumctl compute restart birdhaus-auth`. It is stateless: users, clients and providers are in Postgres, so it comes back without losing anything.
- **Backups:** the `auth` database is covered by the Postgres base backups and WAL. A restore drill of `birdhaus-pg` also restores accounts; verify by signing in afterwards.
- **Upgrade:** change `rauthyImage` in `auth/deploy.hs` to the new digest and re-run. Rauthy runs its own migrations on start.
- **Encryption keys:** `ENC_KEYS` / `ENC_KEY_ACTIVE` in `birdhaus-auth` encrypt client secrets, upstream provider secrets and cookies in the database. Do not change or lose them without following Rauthy's key-rotation procedure; losing them means re-creating clients and providers.
- **Lost passkey:** a passkey-only user who loses every device needs an admin-assisted reset in the Admin UI. Users who chose a password can reset it by email.
- **Proxy trust:** TLS terminates at the Datum edge, so `PROXY_MODE=true` and `TRUSTED_PROXIES` must include the edge's source range. The first deploy trusts everything (`0.0.0.0/0 ::/0`); narrow it after checking the peer addresses in the instance logs, or Rauthy will either block requests or accept spoofed client IPs. `SESSION_VALIDATE_IP` is on, so a wrong range shows up as sessions with the proxy's IP in the Admin UI.

## Limits

- **Email login is passkey-first**, not a per-login magic link: Rauthy's magic link activates the account and sets the first passkey or password. Users without a passkey can keep a password.
- **No SSO into Umami.** Umami self-hosted does not support OIDC; its admin login stays local. The store sends `umami.identify` with the Rauthy user ID instead.
- **No HA.** One instance, restored from Postgres if it is replaced. Login is unavailable while it restarts; checkout keeps working.
- **Phase 2:** Microsoft (Entra) and Login with Amazon as generic OIDC providers in Rauthy's Providers page, once the Google flow is verified.
