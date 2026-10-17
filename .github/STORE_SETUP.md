# Setting up the stores, step by step

This is the one-time setup that lets the **release** workflow publish Diapason to
**Google Play** (phone + Android TV) and **App Store Connect** (iOS + tvOS).
Reference for the workflow itself: [`MOBILE_RELEASE.md`](./MOBILE_RELEASE.md).

Store consoles rename buttons now and then; where a label below doesn't match,
look for the same idea nearby.

| Fixed values for this app | |
|---|---|
| Android package / iOS + tvOS bundle ID | `fr.nytuo.diapason` |
| iOS widget extension bundle ID | `fr.nytuo.diapason.DiapasonWidget` |
| App Group | `group.fr.nytuo.diapason` |
| Apple team | `U5WGLFU24B` (already set in both Xcode projects) |
| Privacy policy | [`PRIVACY.md`](../PRIVACY.md), "Diapason does not collect any data" |
| Store texts and screenshots already in the repo | `fastlane/metadata/android/en-US/` |

## 0. The order that works

1. Build the artifacts once with **no** secrets (proves the pipeline) — section 1.
2. Google Play: account → app → upload key → first manual upload → API access — section 2.
3. Apple: App ID → App Store Connect app (+ tvOS) → API key → distribution certificate — section 3.
4. Add the secrets to GitHub — section 4.
5. Run the workflow with `publish_stores` — section 5.
6. Fill in the store listings and send for review — sections 6 and 7.

Costs: Google Play is a one-time 25 USD fee. The Apple Developer Program is
99 USD/year (you already have it through CosmicComics; the same team is used).

## 1. Prove the pipeline first (no stores involved)

1. GitHub → **Actions → release → Run workflow**.
2. Leave `publish_stores` **off**, leave `build_tvos` **on**, run it.
3. When it finishes you get a **draft release** with the Android phone APK, the
   Android TV APK, the unsigned iOS IPA and the unsigned tvOS IPA, plus desktop builds.

If a job fails here, fix it before touching any store; nothing below helps.

## 2. Google Play (Android phone + Android TV)

### 2.1 Developer account
1. Go to <https://play.google.com/console/signup> and sign in with the Google account that will own the app.
2. Choose **Personal** or **Organization**. Personal accounts created after
   13 Nov 2023 must run a **closed test with at least 12 testers for 14 days**
   before they may publish to production (organization accounts skip this).
3. Pay the fee, verify your identity (ID and, for some countries, a phone/device check). Approval can take days.

### 2.2 Create the app
1. Play Console → **Create app**.
2. App name `Diapason`, default language, **App**, **Free**, accept the declarations.

### 2.3 Create the upload key (once, keep it forever)
```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```
- Pick a strong password and **store the `.jks` and the password in a password manager**, outside the repo.
- You will later upload this key's *certificate* to Google; Google re-signs what users download with its own key (**Play App Signing**, on by default). If you lose the upload key, Google can reset it; if you lose it *and* don't use Play App Signing, the app can't be updated.

### 2.4 First upload must be manual
Google refuses API uploads to an app that has never had a release, so:
1. Add the three Android secrets from section 4 (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`).
2. Run **release** with `publish_stores` **off**. Because the keystore secrets exist, the run now also keeps a signed bundle as the artifact **`store-android-aab`** (kept 14 days).
3. Download it from the run's page (Artifacts), unzip to get `diapason-<version>_android.aab`.
4. Play Console → **Test and release → Testing → Internal testing → Create new release**.
5. Accept **Play App Signing** when asked, upload the `.aab`, name the release, **Save → Review → Start rollout to Internal testing**.
6. Add yourself under **Testers** (create an email list) so you can install it.

### 2.5 Let GitHub upload for you (service account)
1. <https://console.cloud.google.com> → create a project (any name).
2. In that project **APIs & Services → Library** → enable **Google Play Android Developer API**.
3. **IAM & Admin → Service Accounts → Create service account** (name `play-publisher`, no roles needed here).
4. Open it → **Keys → Add key → Create new key → JSON**. Download the file; this is `PLAY_SERVICE_ACCOUNT_JSON`.
5. Play Console → **Users and permissions → Invite new users** → paste the service account's email (`…@….iam.gserviceaccount.com`).
6. Give it permissions for **this app**: at least *Release to production, exclude devices, and use Play App Signing* and *Release apps to testing tracks*. Send the invite (service accounts accept automatically).
7. It can take up to a few hours before the API honours the new permissions.

### 2.6 Store listing (**Grow users → Store presence → Main store listing**)
- Short and full descriptions: copy from `fastlane/metadata/android/en-US/short_description.txt` and `full_description.txt`.
- App icon 512×512: `fastlane/metadata/android/en-US/images/icon.png` (check it is 512×512).
- Feature graphic 1024×500 and 2–8 phone screenshots (`images/phoneScreenshots/`). Tablet screenshots are optional but improve placement.
- Category: **Music & Audio**. Contact email required; website optional.

### 2.7 App content (**Policy and programs → App content**) — all required
- **Privacy policy URL**: the public URL of `PRIVACY.md` on GitHub.
- **Ads**: no.
- **App access**: the app needs a music server to do anything, so reviewers can't use it
  without one. Choose "all or some functionality is restricted" and give a **demo server
  URL, username and password** (a small public Navidrome/Jellyfin with a few CC-licensed tracks works).
- **Content rating**: answer the questionnaire (no violence, etc.; user-generated content: no).
- **Target audience**: 18+ (or 13+) — not for children.
- **Data safety**: "No data collected" and "No data shared" matches `PRIVACY.md`. Data
  you send to servers *the user configures* is not data you collect. Declare that data is encrypted in transit only if you require HTTPS; the app also allows plain HTTP to LAN servers, so be accurate.
- **Government / financial / health / news**: none apply.

### 2.8 Android TV (same app, extra opt-in)
The manifest is TV-ready (the workflow checks it every run). In the Play Console:
1. **Test and release → Setup → Advanced settings → Form factors → Add Android TV**.
2. Add the TV assets in the store listing for that form factor (TV banner graphic, TV screenshots) — the console shows the required sizes.
3. Complete the **TV app quality** checks it lists (D-pad navigation, no touch-only flows, a launcher banner). Test on a real TV or the Android TV emulator before submitting.
4. Until this is enabled, uploads succeed but Play does not offer the app on TVs.

### 2.9 Publishing
- Internal testing needs no review. To go public: **Closed testing** (needed for the 12-tester rule), then **Production → Create release → Send for review**. The workflow leaves `production` as a *draft* on purpose; you press *Send for review* yourself.

## 3. Apple (iOS + tvOS)

You already have the Developer Program membership (team `U5WGLFU24B`).

### 3.1 Register the identifiers
<https://developer.apple.com/account> → **Certificates, Identifiers & Profiles**.
1. **Identifiers → App Groups → +** → `group.fr.nytuo.diapason`.
2. **Identifiers → App IDs → + → App** → explicit Bundle ID `fr.nytuo.diapason`.
   Capabilities: **App Groups** (select the group above). Leave **CarPlay** alone unless Apple has granted you the entitlement (see 3.7).
3. Another App ID `fr.nytuo.diapason.DiapasonWidget` (the iOS widget) with **App Groups** → same group.
tvOS reuses `fr.nytuo.diapason`; no extra identifier is needed.

### 3.2 Create the app in App Store Connect
<https://appstoreconnect.apple.com> → **Apps → + → New App**.
1. Platforms: tick **iOS** and **tvOS**. (Forgot tvOS? Open the app later → the **+** next to *Apple TV* in the sidebar.)
2. Name `Diapason` (names are unique store-wide; if taken, pick another and keep the on-device name as is).
3. Primary language, **Bundle ID** `fr.nytuo.diapason`, SKU anything (e.g. `diapason`), **Full access**.

### 3.3 App Store Connect API key (lets GitHub upload)
1. App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys → +**.
2. Name `github-release`, access **App Manager**.
3. Note the **Issuer ID** (top of the page) and the key's **Key ID**, then **Download** the `.p8`. **You can download it only once.**
   - `APPLE_API_ISSUER` = Issuer ID
   - `APPLE_API_KEY` = Key ID
   - `APPLE_API_KEY_P8` = the whole text of `AuthKey_<KeyID>.p8`, including the BEGIN/END lines.

(If you already made one for CosmicComics, reuse it.)

### 3.4 Apple Distribution certificate (needed for tvOS)
tvOS is built with the third-party flutter-tvos toolchain, which signs the Flutter
engine with your own certificate; Apple rejects an unsigned engine when a build
reaches *external* TestFlight. The API key can't supply that, so export one:
1. On a Mac: **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority** → your email, "Saved to disk".
2. developer.apple.com → **Certificates → + → Apple Distribution** → upload the request → download the `.cer` and double-click it to install.
   (You may already have an *Apple Distribution* certificate from CosmicComics — check Keychain Access → My Certificates; reuse it.)
3. In **Keychain Access → My Certificates**, right-click **Apple Distribution: …** → **Export** → `.p12`, choose a password.
4. `base64 -i dist.p12` → `APPLE_DISTRIBUTION_CERT_P12_BASE64`; the password → `APPLE_DISTRIBUTION_CERT_PASSWORD`.
5. Delete the `.p12` from disk afterwards or keep it in the password manager.

### 3.5 iOS store listing (app → **iOS App → version**)
- **Screenshots**: App Store Connect currently requires screenshots for the large iPhone size (6.9″/6.5″); iPad ones if the app supports iPad.
- **Description, keywords, support URL, marketing URL** (optional), **copyright**.
- **App Privacy**: "Data Not Collected", with the privacy policy URL (`PRIVACY.md` on GitHub).
- **Age rating**: complete the questionnaire.
- **Export compliance**: the app only uses the operating system's HTTPS, which is exempt.
  App Store Connect asks this question for every build until `ITSAppUsesNonExemptEncryption` is set to `false` in the Info.plists — say if you want that added so builds stop waiting on the question.
- **App Review information**: because the app needs a server, give a **demo server URL, username and password** and a note that it is a client for self-hosted servers.
  Also explain `NSAllowsArbitraryLoads`: users connect to their own servers, often plain HTTP on a home network.
- **Local network**: the app asks for local network access (Diapason Connect and discovery); the usage text is already in the Info.plist.

### 3.6 tvOS listing (app → **tvOS App → version**)
- **Screenshots**: Apple TV, 1920×1080 (or 3840×2160), at least one.
- **App icon and Top Shelf**: already in `tvos/Runner/Assets.xcassets/AppIcon.brandassets` (layered Large/Small icon and a Top Shelf image). Make sure they are real artwork, not placeholders; the build fails validation if layers are missing.
- Description, keywords, support URL, privacy and age rating are entered again for tvOS.
- App Review information: the same demo server details.

### 3.7 CarPlay (optional, not needed now)
The iOS app has a CarPlay scene, but Apple only allows CarPlay apps that were granted the **CarPlay audio** entitlement (request at <https://developer.apple.com/contact/carplay/>). `Runner.entitlements` does not contain it, so CarPlay will not work in the store build until it's granted and added.

## 4. Put the secrets in GitHub

Repo → **Settings → Secrets and variables → Actions → New repository secret**, or with the CLI:

```bash
# Android (section 2)
base64 -i upload-keystore.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS          # "upload" if you used the command above
gh secret set PLAY_SERVICE_ACCOUNT_JSON < play-service-account.json

# Apple (section 3)
gh secret set APPLE_API_ISSUER
gh secret set APPLE_API_KEY
gh secret set APPLE_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
base64 -i dist.p12 | gh secret set APPLE_DISTRIBUTION_CERT_P12_BASE64
gh secret set APPLE_DISTRIBUTION_CERT_PASSWORD
```
(`gh secret set NAME` with no input prompts you to type the value.)

Optional but recommended: **Settings → Environments → New environment `app-stores`
→ Required reviewers = you**. Every store upload then waits for your click.

## 5. Publish

1. **Actions → release → Run workflow**.
2. Tick `publish_stores`. `play_track` = `internal` for the first time.
3. What happens:
   - Android: the signed bundle goes to the Play track you chose.
   - iOS and tvOS: signed builds are uploaded to App Store Connect (nothing is submitted for review automatically).
   - The GitHub release stays a **draft**; publish it when you're happy (that also triggers the Homebrew update).
4. If a platform's secrets are missing, that upload is skipped with a warning and the rest continues.

## 6. After the upload

- **Google Play**: the release appears under your track. Install it from the internal-testing link on a phone and a TV.
- **App Store Connect → TestFlight**: builds show "Processing" for 10–30 minutes, then appear under **iOS** and **tvOS**.
  - Answer the export-compliance prompt if it shows.
  - Add yourself as an **Internal Tester** to install via the TestFlight app.
  - **tvOS: push the first build to an *External* group** at least once. Upload and internal TestFlight succeed even with an unsigned engine; only external review checks the engine signature, so this is the real test that the certificate setup works.

## 7. Submitting for public release

- **Google Play**: Production → Create release → pick the build → **Send for review**. New personal accounts must finish the 14-day closed test first.
- **App Store**: open the version → **Build → +** pick the processed build → fill any remaining fields → **Add for Review → Submit**. Do iOS and tvOS separately; each has its own version page.
- Reviews usually take from a few hours to a few days. The usual first-time rejections: reviewers can't log in (give working demo credentials), missing privacy policy URL, screenshots that show placeholder or empty states.

## Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| `store-android-aab` artifact missing | The keystore secrets aren't set; the workflow then signs with the debug key and keeps no bundle. |
| Play: "package not found" / "app not published" | First upload wasn't done manually (2.4). |
| Play: 403 from the API | Service account not invited to the app, or permissions still propagating (2.5). |
| Play: "version code already used" | Build numbers come from the workflow run number, so a fresh run always gets a new one; this only happens if a run was uploaded twice by hand. |
| App Store: "Missing signature" / ITMS-91065 on external TestFlight | The tvOS engine wasn't signed: certificate secrets missing or wrong (3.4). |
| `No signing certificate "Apple Distribution" found` in the tvOS job | `APPLE_DISTRIBUTION_CERT_*` wrong, or the `.p12` was exported without its private key. |
| `Provisioning profile … doesn't include …` | Capabilities (App Group) missing on the App ID (3.1). |
| tvOS job: "tvOS … is not installed" | The job downloads the platform by itself; if it still fails, re-run (large download). |
