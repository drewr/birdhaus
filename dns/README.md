# DNS records

Hand-written records for the `birdhaus-store-1kamnr` zone (birdhaus.store) on Datum Cloud. The apex ALIAS record that points at the site is managed by the edge and is not here.

| File | Records |
|---|---|
| `txt.yaml` | Stripe domain verification, Mailgun SPF, DMARC, Mailgun DKIM |
| `cname.yaml` | Stripe custom email domain: six DKIM CNAMEs and `bounce` |
| `mx.yaml` | Mailgun inbound mail |

Apply with the project as an argument:

```
datumctl apply -f dns/ --project <project>
```

These files are the source of truth: applying overwrites each record set, so a change made only in the Datum console is lost on the next apply. TTLs are 5 minutes. Everything here is public DNS data.
