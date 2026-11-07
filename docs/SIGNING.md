# Signing: the persistent distribution certificate

**Status:** workflow support implemented (v0.6); the repo secrets still need to
be created once by the owner — see "One-time setup" below.

## Why

`testflight.yml` used App Store Connect's *automatic* signing with an empty
keychain. On an ephemeral macOS runner that means Xcode has no usable identity,
so it mints a fresh **Apple Development** certificate on every run. Ten runs
filled the account's certificate limit (the 2026-11-07 "reached the maximum
number of certificates" failure) and the leftovers had to be revoked with
`cert-maintenance.yml`.

The fix is to stop creating certificates: keep one **Apple Distribution**
identity (certificate + private key) as encrypted repo secrets, import it into a
temporary keychain at the start of every run, and let `codesign` reuse it.

Two modes, chosen automatically by which secrets exist:

| Secrets | Signing | Certificates created per run |
|---|---|---|
| `DIST_CERT_P12` + `DIST_CERT_PASSWORD` | automatic, with the imported identity | none (Xcode reuses it; a *profile* may be created) |
| … plus `DIST_PROFILE` | manual (`CODE_SIGN_STYLE=Manual`) | none, no portal mutation |
| neither | automatic, empty keychain (**old behaviour**) | one Apple Development cert |

The workflow prints a `::warning::` annotation when it falls back to the last
row, so the churn is visible instead of silent.

## One-time setup (owner, ~5 minutes)

All steps happen in a browser and a terminal on a Mac **with the distribution
private key** — not on a CI runner. The key never leaves App Store Connect /
Keychain except as the encrypted `.p12` placed directly into the repo secret.

### 1. Get (or create) one Apple Distribution certificate

Apple Developer portal → **Certificates, Identifiers & Profiles** →
**Certificates** → `+` → **Apple Distribution** (App Store). Create it with a
CSR from a Mac in Keychain Access (`Certificate Assistant → Request a
Certificate From a Certificate Authority`).

Download the `.cer`, double-click it so it lands in the login keychain together
with its private key. In Keychain Access, expand the certificate and confirm the
private key is nested under it.

> If a distribution certificate already exists and its private key is on that
> Mac, use it — no new certificate needed. Creating one is only necessary once
> per ~1 year.

### 2. Export it as a password-protected .p12

Keychain Access → right-click the **Apple Distribution** certificate (with the
key) → **Export Items…** → format **Personal Information Exchange (.p12)** →
set a password (any strong string; it becomes `DIST_CERT_PASSWORD`).

```bash
base64 -w0 AppleDistribution.p12 > dist-cert.b64     # macOS: base64 -i
```

### 3. (Optional but recommended) export the App Store profile

Developer portal → **Profiles** → `+` → **App Store** →
`com.sheigl.CraftRoomAI` → select the same Apple Distribution certificate →
Download. Then:

```bash
base64 -w0 CraftRoomAI_AppStore.mobileprovision > dist-profile.b64
```

Without this the workflow relies on automatic signing with the imported
certificate, which is already churn-free; with it, signing is fully manual and
nothing is created on the portal at all.

### 4. Store the secrets

```bash
gh secret set DIST_CERT_P12      --repo sheigl/craftroom-ai-ios < dist-cert.b64
gh secret set DIST_CERT_PASSWORD --repo sheigl/craftroom-ai-ios
gh secret set DIST_PROFILE       --repo sheigl/craftroom-ai-ios < dist-profile.b64   # optional
```

Delete the local `.p12`/`.b64` files afterwards.

### 5. Verify

```bash
gh workflow run testflight.yml --repo sheigl/craftroom-ai-ios
gh run watch --repo sheigl/craftroom-ai-ios
```

The "Check credentials" step must print
`persistent distribution certificate configured (profile: yes|no)`, and the
"Import distribution certificate" step must list an `Apple Distribution`
identity. If it does not, the `.p12` was exported without its private key.

## Rotating / revoking

* Certificates expire after ~1 year: repeat steps 1–4 with the new `.p12`.
* `cert-maintenance.yml` still exists for emergencies (list/revoke). With this
  policy in place it should not be needed again.
