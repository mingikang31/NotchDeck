# NotchDeck license proxy

A small Cloudflare Worker that sits between NotchDeck and the merchant. It checks a license key
(or the master key), then answers with an **Ed25519-signed receipt** bound to the Mac. The app
verifies that receipt offline with the public key embedded at build time, so after one successful
activation NotchDeck works without a network connection.

```
NotchDeck ──POST /v1/licenses/activate──▶ proxy ──▶ LemonSqueezy (or master key / mock)
          ◀──── { receipt: { payload, signature } } ────┘   signed with SIGNING_KEY_JWK
```

## Secrets

All secrets live in the repo-root `.env` (git-ignored, mode 600) and, in production, in
Cloudflare secrets. They never appear in source, the app binary, or receipts.

| Name | What it is |
|---|---|
| `MASTER_LICENSE_KEY` | Unlimited-activation key for you and anyone you share it with. |
| `SIGNING_KEY_JWK` | Ed25519 private key that signs receipts. The app embeds only the public half. |

## Master key

- Enter it in **NotchDeck → Settings → License** like any other key (case-insensitive).
- It activates any number of Macs, never touches the merchant, and shows as **Master (unlimited)**.
- The receipt stores only the last 4 characters as a hint; the key itself is never in the receipt.
- To stop *new* activations, change `MASTER_LICENSE_KEY` and redeploy. Macs already activated stay
  activated, because their receipts are signed and verified offline. Revoking those too requires
  rotating the signing key (which also invalidates every customer receipt), so share the master
  key only with people you trust.

## Local development

```sh
node Server/license-proxy/dev-server.mjs   # http://127.0.0.1:8787, reads ../../.env
```

Debug builds already point at this address and embed the DEV public key that matches the DEV
`SIGNING_KEY_JWK` in `.env`. With `MERCHANT=mock`, any key starting with `TEST-` activates, as does
the master key.

Run the live integration tests against it:

```sh
TEST_RUNNER_NOTCHDECK_LICENSE_SERVER=http://127.0.0.1:8787 \
TEST_RUNNER_NOTCHDECK_MASTER_KEY="$(sed -n 's/^MASTER_LICENSE_KEY=//p' .env)" \
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck test
```

## Production deployment

1. Generate the production keypair (separate from the DEV one):
   ```sh
   swift Scripts/license-keygen.swift
   ```
   Put `LICENSE_PUBLIC_KEY` in `Config/NotchDeck.xcconfig` (the Release value) and keep the JWK private.
2. Set the worker's secrets and vars:
   ```sh
   cd Server/license-proxy
   npx wrangler secret put SIGNING_KEY_JWK       # paste the production JWK
   npx wrangler secret put MASTER_LICENSE_KEY    # paste the value from .env
   ```
   In `wrangler.toml`, keep `MERCHANT = "lemonsqueezy"` and set `LEMONSQUEEZY_STORE_ID` /
   `LEMONSQUEEZY_PRODUCT_ID` so keys from other products are refused.
3. `npx wrangler deploy`, then set `LICENSE_API_BASE_URL` (Release) in `Config/NotchDeck.xcconfig`
   to the deployed URL.

## Known limitations

- LemonSqueezy counts every activation call as a new instance. Reinstalling without
  "Deactivate This Mac" first uses another seat; raise the activation limit or deactivate the old
  instance from the LemonSqueezy dashboard.
- Receipts are lifetime and offline-verified, so merchant refunds don't revoke them automatically.
