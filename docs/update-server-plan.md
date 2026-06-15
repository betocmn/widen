# Widen auto-update infrastructure — build plan for the website/update-server repo

This is a self-contained brief for standing up the **server/hosting side** of Widen's
auto-update feature. The **client side is already done** in the Widen app repo (Sparkle 2 is
integrated — update popup, auto-download, install, relaunch, a "Check for Updates…" menu item,
and a Settings toggle). What's missing is the thing the client talks to: an **appcast feed**
and the **downloadable builds**, plus the **release pipeline** that produces and publishes them.

Hand this file to an LLM/agent working in the new **Next.js-on-Vercel** repo (the one that also
hosts the marketing site). It does not need access to the Widen app source to do its part.

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

**No backend logic is required.** A dynamic route is optional (see §7) for phased rollouts or
download analytics, but start static.

### What the client already expects (from the Widen repo — do not change without coordinating)
These are set in the Widen app's `project.yml` → `targets.Widen.info.properties`:

| Info.plist key | Current value | Meaning |
| --- | --- | --- |
| `SUFeedURL` | `https://widen.dev/appcast.xml` | Where this repo must serve the feed. |
| `SUPublicEDKey` | Not set yet | EdDSA **public** key; add the real generated key before public releases. |
| `SUEnableAutomaticChecks` | `true` | Auto-check on by default. |

> ⚠️ **Cross-repo coupling — read this twice.**
> - `SUFeedURL` must equal the public URL where this repo serves `appcast.xml`. If you host the
>   feed somewhere else or under a different path, the Widen repo's `SUFeedURL` must be updated
>   (edit `project.yml`, run `make project`, rebuild).
> - If `SUPublicEDKey` is added to the Widen repo, it must be the public half of the EdDSA key
>   generated in §3. Do **not** commit a placeholder value: Sparkle treats invalid public keys as
>   fatal updater configuration errors at launch.

---

## 2. First-time setup checklist

Do these once, in order:

- [ ] **§3** Generate the Sparkle EdDSA key pair; add the public key to the Widen repo.
- [ ] **§4** Confirm/obtain Apple signing + notarization credentials.
- [ ] **§6** Stand up hosting in this repo (serve `appcast.xml` + `/releases/*.zip` at `widen.dev`).
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
./generate_keys
```

This stores the **private** key in the macOS **login Keychain** (item
`https://sparkle-project.org`, account `ed25519`) and prints the **public** key, e.g.:

```
A public key has been generated... Add this to your app's Info.plist (SUPublicEDKey):

  hX3W...base64...=
```

Then:

1. In the **Widen repo**, add `SUPublicEDKey` to `project.yml`
   (`targets.Widen.info.properties`) with that base64 string, run `make project`, commit.
2. **Back up the private key** — without it you can never ship another update users will accept.
   Export it for safekeeping / CI:
   ```sh
   ./generate_keys -x sparkle_private_key.pem    # export (KEEP SECRET; never commit)
   ```
   Store it in a password manager and, for CI, as an encrypted secret (see §7). To import on
   another machine: `./generate_keys -f sparkle_private_key.pem`.

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

The Widen repo's `project.yml` will need these build settings flipped on for Release (the app
team owns this change; noted here so the pipeline is coherent):
`CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM: <TEAMID>`,
`CODE_SIGN_IDENTITY: "Developer ID Application"`, `ENABLE_HARDENED_RUNTIME: YES`.

---

## 5. The release pipeline (per release)

This is the bridge between the two repos. It can run as a local script or a GitHub Action
(§7). Steps for version `X.Y.Z` (with build number `N`):

1. **Bump version** in the Widen repo's `project.yml`
   (`CFBundleShortVersionString: "X.Y.Z"`, `CFBundleVersion: "N"`), `make project`, commit, tag.
2. **Build Release** with Developer ID signing (Xcode signs the app *and* Sparkle's embedded
   XPC services / `Autoupdate` correctly when the identity is set in the build):
   ```sh
   xcodebuild -project Widen.xcodeproj -scheme Widen -configuration Release \
     -derivedDataPath build build
   ```
3. **Notarize + staple** (submit a zip, staple the `.app`, then make the distribution zip):
   ```sh
   APP="build/Build/Products/Release/Widen.app"
   ditto -c -k --keepParent "$APP" Widen-notarize.zip
   xcrun notarytool submit Widen-notarize.zip --key AuthKey.p8 \
     --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
   xcrun stapler staple "$APP"
   ```
4. **Make the distribution archive** from the stapled app:
   ```sh
   ditto -c -k --keepParent "$APP" "Widen-X.Y.Z.zip"
   ```
5. **EdDSA-sign + generate the appcast.** Easiest path — point `generate_appcast` at a folder
   of release zips; it reads the private key from the Keychain, computes each signature +
   length, and writes/updates `appcast.xml`:
   ```sh
   mkdir -p releases && mv "Widen-X.Y.Z.zip" releases/
   ./generate_appcast --download-url-prefix "https://widen.dev/releases/" releases/
   ```
   (Single-file alternative if hand-authoring the XML: `./sign_update Widen-X.Y.Z.zip` prints
   the `sparkle:edSignature` and `length` to paste into the `<enclosure>`.)
6. **Publish**: copy `Widen-X.Y.Z.zip` and `appcast.xml` into this repo's hosting (§6) and
   deploy to Vercel.

---

## 6. Hosting in this (Next.js/Vercel) repo

### Option A — static (recommended to start)
- Serve the feed at `https://widen.dev/appcast.xml` → put the file at `public/appcast.xml`.
- Serve builds at `https://widen.dev/releases/Widen-X.Y.Z.zip` → `public/releases/…`.
- Vercel serves `.xml` as `application/xml` and `.zip` as a binary download automatically.
- **HTTPS is mandatory** (Sparkle refuses insecure feeds) — Vercel gives you that.

> **Binary size caveat:** files in `public/` are committed to git and bundled into every
> deploy. A macOS `.app` zip is tens of MB and grows the repo fast. For anything beyond a few
> releases, host the **zips** on object storage — **Vercel Blob**, **Cloudflare R2/S3**, or
> **GitHub Release assets** — and point each `<enclosure url>` at that. The small `appcast.xml`
> can still live in `public/` (or be a dynamic route). Keep the feed and the binaries on HTTPS.

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
    <link>https://widen.dev/appcast.xml</link>
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
        url="https://widen.dev/releases/Widen-0.2.0.zip"
        length="18342755"
        type="application/octet-stream"
        sparkle:edSignature="REAL_BASE64_ED_SIGNATURE_FROM_sign_update==" />
    </item>
    <!-- Older <item> entries may remain; Sparkle picks the newest applicable one. -->
  </channel>
</rss>
```

Release-notes alternative to inline `<description>`: host an HTML file and reference it with
`<sparkle:releaseNotesLink>https://widen.dev/notes/0.2.0.html</sparkle:releaseNotesLink>`.

`generate_appcast` (§5) produces this XML for you, including the signature and length — prefer
it over hand-editing.

---

## 7. Optional: dynamic feed + CI

### Dynamic appcast route
Replace the static file with `app/appcast.xml/route.ts` returning the XML with
`Content-Type: application/xml`. This unlocks: **phased rollouts** (serve the new `<item>` to a
growing % of requests via `sparkle:phasedRolloutInterval` or your own logic), **channels**
(beta vs stable feeds), and **download analytics**. Sparkle only requires valid appcast XML at
the URL — everything else is your choice.

### GitHub Actions release workflow (skeleton — can live in the Widen repo)
On a `v*` tag: select Xcode 26 → build Release → import Developer ID cert (from a base64 secret)
→ notarize with the App Store Connect API key (secret) → staple → zip → `sign_update` with the
EdDSA **private** key (imported from a secret via `generate_keys -f`) → `generate_appcast` →
publish the zip to storage and push `appcast.xml` to this repo (or commit to `public/`).
Required repo secrets: `DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`,
`AC_API_KEY_P8`, `AC_KEY_ID`, `AC_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`, plus a deploy/storage token.

---

## 8. Verify end-to-end before announcing

1. Produce one real signed+notarized `Widen-X.Y.Z.zip` and a feed advertising a
   `sparkle:version` **higher** than a locally installed build.
2. Point a build's `SUFeedURL` at the test feed (temporarily edit `project.yml`, or override at
   launch with `defaults write dev.widen.Widen SUFeedURL https://…/test-appcast.xml`).
3. Launch Widen → **Widen ▸ Check for Updates…** → confirm: the update panel with release
   notes appears → it downloads → installs → prompts to relaunch → relaunches into the new
   version. (Auto-checks also fire on a schedule with `SUEnableAutomaticChecks=true`.)
4. Sanity-check signatures: `./sign_update --verify Widen-X.Y.Z.zip` and confirm the app is
   notarized: `spctl -a -vvv -t install Widen.app` → "accepted ... source=Notarized Developer ID".

---

## 9. Security notes

- The EdDSA **private** key and Apple credentials are the crown jewels — keep them in a secrets
  manager / encrypted CI secrets. **Never commit them.** Only the **public** EdDSA key is
  public (it lives in the shipped app).
- Always serve the feed and binaries over **HTTPS**.
- Don't change `SUPublicEDKey` after shipping — rotating it makes existing installs reject all
  future updates until manually reinstalled.
