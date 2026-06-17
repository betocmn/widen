# Widen auto-update infrastructure

This is the hosting model for Widen's Sparkle auto-update feature. The app uses
Sparkle 2 for update UI, download, install, relaunch, "Check for Updates...",
and the Settings toggle. Release artifacts are hosted directly on GitHub
Releases in the Widen app repo.

The static marketing site should only link to the latest DMG. It no longer
hosts `appcast.xml` or Sparkle ZIP files for routine releases.

---

## 1. How Sparkle works (the 60-second model)

Sparkle (the macOS-standard updater, https://sparkle-project.org) is **pull-based**. The app
periodically downloads an XML file — the **appcast** — from a URL baked into its Info.plist
(`SUFeedURL`). The appcast lists the latest version and a link to a zipped `.app`. If the
appcast advertises a version newer than what's installed, Sparkle shows the "new version
available" panel, downloads the zip, **verifies two signatures** (Apple code signature +
Sparkle's EdDSA signature), swaps the app in place, and relaunches.

So the "API" is just **two kinds of static files served over HTTPS**:

1. `appcast.xml` — the feed (one per release channel).
2. `Widen-X.Y.Z.zip` — the zipped, signed, notarized app for each release.

**No backend logic is required.** GitHub Releases serves both files.

### What the client already expects (from the Widen repo — do not change without coordinating)
These are set in the Widen app's `project.yml` → `targets.Widen.info.properties`:

| Info.plist key | Current value | Meaning |
| --- | --- | --- |
| `SUFeedURL` | `https://github.com/betocmn/widen/releases/latest/download/appcast.xml` | Where Sparkle fetches the latest feed. |
| `SUPublicEDKey` | Configured in the Widen app repo | EdDSA **public** key for Sparkle update verification. |
| `SUEnableAutomaticChecks` | `true` | Auto-check on by default. |

> ⚠️ **Cross-repo coupling — read this twice.**
> - `SUFeedURL` must equal the public URL where GitHub serves `appcast.xml`.
>   If you move hosting again, update `project.yml`, run `make project`, and
>   rebuild before distributing that change.
> - If `SUPublicEDKey` is added to the Widen repo, it must be the public half of the EdDSA key
>   generated in §3. Do **not** commit a placeholder value: Sparkle treats invalid public keys as
>   fatal updater configuration errors at launch.

---

## 2. First-time setup checklist

Do these once, in order:

- [x] **§3** Generate the Sparkle EdDSA key pair; add the public key to the Widen repo.
- [ ] **§4** Confirm/obtain Apple signing + notarization credentials.
- [x] **§6** Host `appcast.xml` and `Widen-X.Y.Z.zip` as GitHub Release assets.
- [ ] **§5** Run the release pipeline once to publish v0.1.0 (or the first real version).
- [ ] **§8** Verify end-to-end with a test feed before announcing.

---

## 3. Generate the Sparkle EdDSA signing key (do this first)

Sparkle signs every release with an Ed25519 key that's **independent of Apple code signing**.
The tools ship inside the Sparkle package. From a checkout of the **Widen app repo** after a
build (`make build`), they are at:

```
build/SourcePackages/artifacts/sparkle/Sparkle/bin/{generate_keys,sign_update,generate_appcast}
```

(or download the same tools from a Sparkle release tarball: https://github.com/sparkle-project/Sparkle/releases)

Generate the key pair:

```sh
./generate_keys --account <sparkle-account>
```

This stores the **private** key in the macOS **login Keychain** (item
`https://sparkle-project.org`, under the selected account) and prints the
**public** key, e.g.:

```
A public key has been generated... Add this to your app's Info.plist (SUPublicEDKey):

  hX3W...base64...=
```

Then:

1. In the **Widen repo**, `SUPublicEDKey` is already set in `project.yml`
   (`targets.Widen.info.properties`). Do not rotate it after public release
   unless you are prepared to require a manual reinstall.
2. **Back up the private key** — without it you can never ship another update users will accept.
   Export it for safekeeping / CI:
   ```sh
   ./generate_keys --account <sparkle-account> -x sparkle_private_key.pem
   ```
   Store it in a password manager and, for CI, as an encrypted secret (see §7). To import on
   another machine: `./generate_keys --account <sparkle-account> -f sparkle_private_key.pem`.

---

## 4. Apple signing & notarization (required for updates to launch)

Auto-installed updates must pass **Gatekeeper** on end-user Macs, which requires the app to be
**Developer ID-signed, hardened-runtime-enabled, and notarized**. (The Widen dev build is
ad-hoc signed today — fine for local testing, **not** for distribution.)

You need:

- A paid **Apple Developer Program** membership and a **Developer ID Application** certificate
  (Keychain, or exported `.p12` for CI).
- **Notarization credentials**, one of:
  - An **App Store Connect API key** (`.p8` file + Key ID + Issuer ID) — preferred for CI, or
  - An **Apple ID + app-specific password + Team ID**.

The Widen repo's Release configuration enables Developer ID signing and the
hardened runtime. Set the Apple team identifier through local release
credentials or your fork's build settings. Debug remains ad-hoc signed for
local development.

---

## 5. The release pipeline (per release)

The release pipeline is documented in [release.md](release.md). That runbook
covers version bumps, local signing environment, Developer ID notarization,
Sparkle ZIP/appcast generation, DMG upload, tag push, and draft GitHub Release
creation.

---

## 6. Hosting on GitHub Releases

Each release uploads three assets:

- `Widen.dmg` for the static website and manual downloads.
- `Widen-X.Y.Z.zip` for Sparkle.
- `appcast.xml` for Sparkle's update feed.

The shipped app uses GitHub's stable latest-release asset URL:

```text
https://github.com/betocmn/widen/releases/latest/download/appcast.xml
```

Each generated appcast points its enclosure at the versioned ZIP asset:

```text
https://github.com/betocmn/widen/releases/download/vX.Y.Z/Widen-X.Y.Z.zip
```

The website download CTA should point at:

```text
https://github.com/betocmn/widen/releases/latest/download/Widen.dmg
```

### Appcast format (full example)
`sparkle:version` = `CFBundleVersion` (the build number Sparkle compares); `sparkle:shortVersionString`
= `CFBundleShortVersionString` (display). Match Widen's min OS: `26.0`.

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Widen</title>
    <link>https://github.com/betocmn/widen/releases/latest/download/appcast.xml</link>
    <description>Most recent updates to Widen.</description>
    <language>en</language>
    <item>
      <title>Version 0.2.0</title>
      <pubDate>Wed, 18 Jun 2026 10:00:00 +0000</pubDate>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h3>What's new</h3>
        <ul><li>First auto-update-capable release.</li></ul>
      ]]></description>
      <enclosure
        url="https://github.com/betocmn/widen/releases/download/v0.2.0/Widen-0.2.0.zip"
        length="18342755"
        type="application/octet-stream"
        sparkle:edSignature="REAL_BASE64_ED_SIGNATURE_FROM_sign_update==" />
    </item>
    <!-- Older <item> entries may remain; Sparkle picks the newest applicable one. -->
  </channel>
</rss>
```

Release-notes alternative to inline `<description>`: host an HTML file and reference it with
`<sparkle:releaseNotesLink>https://github.com/betocmn/widen/releases/tag/v0.2.0</sparkle:releaseNotesLink>`.

`generate_appcast` (§5) produces this XML for you, including the signature and length — prefer
it over hand-editing.

---

## 7. Optional: dynamic feed + CI

### Dynamic appcast route
If Widen later needs phased rollouts, channels, or download analytics, move the
feed back behind a controlled HTTPS endpoint and update `SUFeedURL` in the app.
Sparkle only requires valid appcast XML at the configured URL.

### GitHub Actions release workflow (skeleton — can live in the Widen repo)
On a `v*` tag: select Xcode 26 → build Release → import Developer ID cert
(from a base64 secret) → notarize with the App Store Connect API key (secret)
→ staple → zip → `generate_appcast` with the EdDSA **private** key imported via
`generate_keys -f` → upload `Widen.dmg`, `Widen-X.Y.Z.zip`, and `appcast.xml`
to the GitHub Release.
Required repo secrets: `DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`,
`AC_API_KEY_P8`, `AC_KEY_ID`, `AC_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`, plus a deploy/storage token.

---

## 8. Verify end-to-end before announcing

1. Produce one real signed+notarized `Widen-X.Y.Z.zip` and a feed advertising a
   `sparkle:version` **higher** than a locally installed build.
2. Point a build's `SUFeedURL` at the test feed (temporarily edit
   `project.yml`, or override at launch with
   `defaults write <bundle-id> SUFeedURL https://…/test-appcast.xml`).
3. Launch Widen → **Widen ▸ Check for Updates…** → confirm: the update panel with release
   notes appears → it downloads → installs → prompts to relaunch → relaunches into the new
   version. (Auto-checks also fire on a schedule with `SUEnableAutomaticChecks=true`.)
4. Sanity-check signatures: copy the `sparkle:edSignature` from the generated appcast, run
   `./sign_update --verify Widen-X.Y.Z.zip "<sparkle:edSignature>"`, and confirm the app is
   notarized: `spctl -a -vvv -t install Widen.app` → "accepted ... source=Notarized Developer ID".

---

## 9. Security notes

- The EdDSA **private** key and Apple credentials are the crown jewels — keep them in a secrets
  manager / encrypted CI secrets. **Never commit them.** Only the **public** EdDSA key is
  public (it lives in the shipped app).
- Always serve the feed and binaries over **HTTPS**.
- Don't change `SUPublicEDKey` after shipping — rotating it makes existing installs reject all
  future updates until manually reinstalled.
