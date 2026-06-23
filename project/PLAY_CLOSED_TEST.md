# Google Play — Closed Test Workflow

End-to-end recipe for moving Terenska beležnica from Internal testing (already live since 2026-04-28) to a **Closed testing** track on Google Play. Contains every text Play Console will ask for, in Slovene (primary) and English (secondary), plus the answers to every App Content questionnaire.

> Companion to DEPLOYMENT.md §3 (build pipeline) and ARCHITECTURE.md §9 (server contract). This doc is the **release-content** source of truth; DEPLOYMENT.md remains the **build/signing** source of truth.

---

## 0. Decisions — confirm before starting

| Decision | Default chosen here | Alternative |
|---|---|---|
| **AAB to ship** | Existing `/Users/Alexis/Releases/terenska-beleznica-1.0.1+2.aab` (signed, manifest-verified clean of `BACKGROUND_LOCATION` / `com.example`, hardware-features marked `required="false"`). Upload directly to the new Closed track, skipping a v1.0.1+2 upload to Internal. | Upload to Internal first, then **Promote release → Closed**. Same artifact, more clicks. |
| **Tester source** | **Google Group**, recommended: `terenska-beleznica-testers@googlegroups.com` (or any group you control). You manage members in `groups.google.com`; Play Console only needs the group email. | Play Console **email list** (max 100 emails / list, edit-in-place). Faster for ~5 testers; harder once it grows. |
| **Default listing language** | Slovene (`sl`). | Add English (US) (`en-US`) as a fallback so Play's review tooling and non-SI device locales see English. Both texts in §3 below. |
| **Demo account for Google review** | Placeholder — provision a dedicated `tester+google@…` user in NarcIS with `TERENSKA-BELEZNICA` authorization and fill into §4.2. | Use a real user's account. Discouraged: Google reviewers can lock the account on policy false-positives. |
| **Closed track name** | `ARSO – zaprti test` (visible only in Play Console, not to testers). | Anything ≤50 chars. |

---

## 1. Workflow — phase by phase

### Phase A. Pre-flight (local, ~5 min)

1. Confirm the artifact exists and is the right size (~45 MB):
   ```bash
   ls -lh /Users/Alexis/Releases/terenska-beleznica-1.0.1+2.aab
   ```
2. Re-run the manifest sanity probe from DEPLOYMENT.md §3.2 (one paste, takes 10 s). Expect: `si.terenska.beleznica` present; `com.example` and `BACKGROUND_LOCATION` absent; all four `android.hardware.camera*` / `.location*` features listed.
3. Confirm the privacy policy URL still resolves:
   ```bash
   curl -sI https://alittis.github.io/terenska-beleznica/privacy/ | head -1
   ```
   Expect `HTTP/2 200`.

### Phase B. Play Console — create the Closed track (~10 min)

1. Play Console → app **Terenska beležnica** → **Test and release → Testing → Closed testing**.
2. **Create track** → name: `ARSO – zaprti test` → **Create**.
3. Inside the new track, **Create new release**:
   - **App bundle**: upload `terenska-beleznica-1.0.1+2.aab`. Play parses it; verify the suggested `Release name` is `1.0.1 (2)`.
   - **Release notes**: paste §3.3 (Slovene + English variants).
4. Save (do **not** start rollout yet — finish App Content first).

### Phase C. Testers tab on the Closed track (~5 min, after the group exists)

1. **Testers** tab on the same track →  **+ Create email list** (or **Add Google groups**).
   - For Google Group flow: paste `terenska-beleznica-testers@googlegroups.com` → Save. The group must accept email from `googleplay-noreply@google.com`; default group settings are fine.
   - For email-list flow: paste tester emails (one per line), name the list `ARSO testers`.
2. **Feedback URL or email address**: `admin@alittis.com`.
3. **How testers join your test**: copy the resulting opt-in URL. It is always:
   ```
   https://play.google.com/apps/testing/si.terenska.beleznica
   ```
4. (Optional but kind to testers) toggle **Allow opting out**: ON.

### Phase D. Main store listing (~20 min — only required once per locale)

1. **Grow → Store presence → Main store listing → Slovene (default)**.
2. Paste fields from §3.1.
3. Upload graphics:
   - **App icon (512×512 PNG)**: regenerate from the existing 1024×1024:
     ```bash
     sips -z 512 512 assets/icon/app_icon.png --out /tmp/play_icon_512.png
     ```
   - **Feature graphic (1024×500 PNG/JPG)**: not yet authored. See §6 for the spec; until it exists, the listing cannot be saved. Quickest path: a tinted-green background with the launcher icon centered + the words "Terenska beležnica" in white. Reuse the `tools/icon/build_icon.py` palette (`#2E7D32` background, white narcissus, yellow/red cup).
   - **Phone screenshots (2–8, min 320 px short edge)**: capture on the A56 dev device:
     - Login screen (the meadow / butterfly background)
     - Home map with Motnje + Obhodi layers visible
     - Form screen mid-entry
     - Detail screen with photo
     - Walk-recording mode with active-walk pill
     - Profile / sync-status tile
4. **English (US)**: paste fields from §3.2. Same graphics work for both.
5. **Categorization**:
   - Application type: **App**
   - Category: **Productivity** (alternative: *Tools*; not *Maps & Navigation* — the app's primary purpose is field reporting, not navigation)
   - Tags: `Productivity`, `Note taking`, `Location` (Play picks from a fixed list; choose closest 3)
6. **Contact details**:
   - Email: `admin@alittis.com`
   - Website: `https://narcis.arso.gov.si`
   - Phone: leave blank
7. **Privacy policy**: `https://alittis.github.io/terenska-beleznica/privacy/`

### Phase E. App content questionnaire (~30 min — required once)

Walk through every section under **Policy → App content**. Answers in §4 below. All sections must show the green ✓ before the closed-test release can roll out.

### Phase F. Roll out the Closed release (~2 min)

1. Back to **Test and release → Testing → Closed testing → ARSO – zaprti test → Releases overview**.
2. Open the draft release → **Review release** → **Start rollout to Closed testing**.
3. Confirm. Play queues a review (typically 2–7 days for a first-ever Closed test on a new track; subsequent updates land within hours).
4. Once Play emails "Your release is live", testers can use the §1.C opt-in URL.

### Phase G. Tester onboarding (~5 min, after rollout is live)

1. Add testers to the Google Group (or email list).
2. Send the §5 invitation email (Slovene; English variant included for non-SI testers).
3. Watch `admin@alittis.com` for replies.

---

## 2. App identity (paste-ready)

| Field | Value |
|---|---|
| App name (Play listing) | `Terenska beležnica` |
| Package name | `si.terenska.beleznica` |
| Default language | Slovene (`sl`) |
| Additional languages | English (United States) (`en-US`) |
| Publisher (developer name) | `Alittis` |
| Publisher contact | `admin@alittis.com` |
| Privacy policy | `https://alittis.github.io/terenska-beleznica/privacy/` |
| Website | `https://narcis.arso.gov.si` |
| Category | Productivity |
| Tags | Productivity · Note taking · Location |
| Content rating (expected outcome) | IARC 3+ / PEGI 3 (everyone) |
| Target audience | 18+ |
| Contains ads | No |
| In-app purchases | No |

---

## 3. Store listing copy

### 3.1 Slovene (`sl`) — default

**App name** (max 30 chars):
```
Terenska beležnica
```

**Short description** (max 80 chars; current count: 75):
```
Terenska beležnica za naravovarstvene nadzornike — motnje, foto, GPS sledi.
```

**Full description** (max 4000 chars):
```
Terenska beležnica je mobilna aplikacija za naravovarstveno nadzorno službo. Zabeležite motnje (nedovoljene posege v zaščiteno naravo, kršitve), opravljene obhode in spremljevalne fotografije naravnost na terenu — tudi takrat, ko ni omrežne povezave.

Aplikacija je razvita za uporabnike, ki delajo na zavarovanih in drugih naravovarstvenih območjih v Sloveniji. Podatki se sinhronizirajo s sistemom NarcIS, ki ga upravlja Agencija Republike Slovenije za okolje (ARSO).

— Glavne funkcije —

• Hitra prijava motnje. Točna GPS lokacija, slovenski šifrant tipov motenj, fotografije, opis dogodka in seznam opazovalcev — vse v eni preprosti zaslonski obliki.

• Obhodi z GPS sledjo. Snemanje neprekinjene poti obhoda v ozadju, tudi pri zaklenjenem zaslonu. Motnje, zabeležene med obhodom, se samodejno povežejo s sledjo, da je delo enostavno za pregled in arhiviranje.

• Zemljevid s plastmi. Izberite med OpenStreetMap in satelitskim slojem (Esri). Prikažite svoje motnje, motnje sodelavcev iz iste organizacije, sledi obhodov in zgodovinske zapise (Notranjski regijski park, marec–avgust 2025).

• Fotografije. Vgrajeni fotoaparat samodejno zmanjša velikost slike na ~200–500 KB pred prenosom — kakovost ostane primerna za dokazilo, prenos pa hiter tudi pri šibki povezavi.

• Delovanje brez omrežja. Vse zapise aplikacija shrani lokalno na napravi. Ko telefon ponovno dobi povezavo, sinhronizacija poteka samodejno; uporabnik lahko z eno potezo zažene tudi ročno sinhronizacijo.

• Varna prijava. Prijava z e-pošto in geslom iz sistema NarcIS prek šifrirane povezave (HTTPS). Geslo se na napravi shrani le kot enosmerni izvleček (PBKDF2-SHA256), kar omogoči ponovno prijavo brez omrežja do 14 dni. Po izteku tega obdobja je potrebna ponovna spletna prijava.

• Avtorizacija po organizaciji. Vsak nadzornik vidi izključno motnje in obhode lastne organizacije. Brez vidnosti med organizacijami.

— Za koga —

Aplikacija je namenjena naravovarstvenim nadzornikom in pooblaščenim sodelavcem ARSO ter pristojnih parkov, ki imajo v sistemu NarcIS dodeljeno pravico „TERENSKA-BELEZNICA“. Brez te pravice prijava v aplikacijo ne uspe.

— Zasebnost in podatki —

• Podatki, ki jih vnesete (lokacija, čas, opis, fotografije, opazovalci), se prenašajo izključno na strežnik ARSO (narcis.gov.si).
• Aplikacija ne uporablja oglasov, sledilnikov ali analitike tretjih oseb.
• Politika zasebnosti: https://alittis.github.io/terenska-beleznica/privacy/
• Upravljavec terenskih podatkov: ARSO (narcis.arso@gov.si). Izdajatelj aplikacije v Trgovini Play: Alittis (admin@alittis.com).

— Zaprti preizkus —

Trenutna različica je v zaprtem preizkusu. Za sodelovanje potrebujete povabilo upravnika in obstoječi račun v sistemu NarcIS. Za dostop ali povratne informacije pišite na admin@alittis.com.
```

### 3.2 English (`en-US`) — fallback

**App name** (max 30 chars):
```
Terenska beležnica
```

**Short description** (max 80 chars; count: 70):
```
Field notebook for nature wardens — disturbance reports, photos, GPS tracks.
```

**Full description** (max 4000 chars):
```
Terenska beležnica ("Field Notebook") is a mobile app for nature-protection wardens. Capture disturbances (illegal interventions in protected areas, infractions), walk-around (patrol) sessions, and supporting photos directly in the field — even with no network coverage.

The app is purpose-built for wardens working in protected and other nature-conservation areas in Slovenia. All data is synchronised with the NarcIS system operated by the Slovenian Environment Agency (ARSO).

— Key features —

• Fast disturbance reporting. Precise GPS location, the Slovenian disturbance-type codebook, photos, free-text description, and an observer list — all in a single short form.

• GPS-tracked walk-arounds. Continuous background tracking of the patrol path, even with the screen off. Disturbances recorded during a walk are automatically linked to the GPS track for later review.

• Map with togglable layers. Choose between OpenStreetMap and Esri satellite imagery. Show your own disturbances, your organisation's disturbances, walk-around tracks, and a bundled historical archive (Notranjska Regional Park, March–August 2025).

• Photos. The built-in capture flow auto-shrinks images to ~200–500 KB before upload — quality remains adequate for evidence, while upload stays fast on weak connections.

• Works offline. Every entry is saved locally on the device. When connectivity returns, sync runs automatically; the user can also trigger a manual sync.

• Secure sign-in. Email + password from the NarcIS system over an encrypted connection (HTTPS). The password is stored on the device only as a one-way digest (PBKDF2-SHA256), which permits offline re-login for up to 14 days. After that window, a fresh online login is required.

• Organisation-scoped access. Each warden only sees disturbances and walks belonging to their own organisation. No cross-organisation visibility.

— Audience —

The app is intended for nature-protection wardens and authorised collaborators of ARSO and the regional parks who hold the "TERENSKA-BELEZNICA" function authorization in NarcIS. Without that authorization, sign-in fails.

— Privacy and data —

• Data you enter (location, timestamp, description, photos, observer names) is transmitted only to the ARSO server (narcis.gov.si).
• The app uses no third-party advertising, trackers, or analytics.
• Privacy policy: https://alittis.github.io/terenska-beleznica/privacy/
• Field-data controller: ARSO (narcis.arso@gov.si). Play Store publisher: Alittis (admin@alittis.com).

— Closed test —

This release is part of a closed test. Participation requires an invitation from the administrator and an existing NarcIS account with the appropriate authorization. For access or feedback, write to admin@alittis.com.
```

### 3.3 Release notes — v1.4.0+13 (current)

**Slovene** (max 500 chars):
```
Različica 1.4.0 (build 13)
• Nov iskalnik tipov motenj: pri izbiri tipa lahko vpišete nekaj črk in seznam se sproti filtrira (išče po imenu tipa in skupine, ne glede na šumnike). Skupine ostajajo za brskanje.
• Obhodi, opravljeni z vozilom, se zdaj v celoti zabeležijo (prej so se točke pri višjih hitrostih izpuščale).
• Na zemljevidu se med oddaljenimi točkami ne rišejo več ravne „navidezne" črte čez vmesne odseke.
```

**English** (max 500 chars):
```
Version 1.4.0 (build 13)
• New disturbance-type search: when picking a type, type a few letters and the list filters as you go (matches type and group name, accent-insensitive). Groups remain for browsing.
• Walk-arounds done by car are now recorded in full (previously points were dropped at higher speeds).
• On the map, tracks no longer draw straight "phantom" lines across gaps between distant points.
```

### 3.3a Release notes — v1.3.1+12 (historical, superseded)

**Slovene** (max 500 chars):
```
Različica 1.3.1 (build 12)
• Časi pri zapisih in obhodih se zdaj prikazujejo v lokalnem času. Prej so bili pri vnosih, prenesenih s strežnika (npr. zapisi sodelavcev), lahko zamaknjeni za 1–2 uri.
• Sledi obhodov so na zemljevidu natančnejše in bolj gladke: točke s slabim signalom GPS se samodejno izločijo, sled pa se zgladi, da manj „cikcaka".
```

**English** (max 500 chars):
```
Version 1.3.1 (build 12)
• Times on records and walk-arounds now display in local time. Previously, items synced from the server (e.g. colleagues' records) could be off by 1–2 hours.
• Walk-around tracks on the map are more accurate and smoother: points with a weak GPS signal are filtered out and the track is smoothed to reduce zig-zag.
```

### 3.3b Release notes — v1.3.0+11 (historical, superseded)

**Slovene** (max 500 chars):
```
Različica 1.3.0 (build 11)
• Nova plast „Območja s statusom": Natura 2000, zavarovana območja, ekološko pomembna območja, naravne vrednote in jame iz GeoServerja NarcIS. Izbirnik plasti in dotik na zemljevidu prikaže območja na izbrani točki (seznam + podrobnosti) v barvah in oblikah z zemljevida.
• Lastni obhodi so na zemljevidu obarvani drugače kot obhodi sodelavcev.
```

**English** (max 500 chars):
```
Version 1.3.0 (build 11)
• New "Protected areas" layer: Natura 2000, protected areas, ecologically important areas, natural values and caves from the NarcIS GeoServer. A layer picker plus tap-to-identify shows the areas at a point (list + details), using the same colours and shapes as the map.
• Your own walk-arounds are now coloured differently from your colleagues' on the map.
```

### 3.3c Release notes — v1.2.3+10 (historical, superseded)

**Slovene** (max 500 chars):
```
Različica 1.2.3 (build 10)
• Dodana navedba financiranja na dnu zaslona Profil: logotipi LIFE, Natura 2000 in projekta LIFE Tršca ter izjava o sofinanciranju.
• Projekt LIFE Tršca (št. 101114184) sofinancirata Evropska unija iz programa LIFE in Ministrstvo za naravne vire in prostor.
```

**English** (max 500 chars):
```
Version 1.2.3 (build 10)
• Funding attribution added at the bottom of the Profile screen: LIFE, Natura 2000 and LIFE Tršca project logos plus the co-funding statement.
• The LIFE Tršca project (no. 101114184) is co-funded by the European Union (LIFE programme) and the Slovenian Ministry of Natural Resources and Spatial Planning.
```

### 3.3d Release notes — v1.2.0+7 (historical, superseded)

**Slovene** (max 500 chars):
```
Različica 1.2.0 (build 7)
• Vztrajna prijava: aplikacija si zapomni vašo prijavo med zagoni in po vrnitvi iz ozadja. Če Android v ozadju ugasne aplikacijo (pogosto na napravah Samsung), pri naslednjem odprtju ne zahteva več ponovne prijave.
• Geslo se v napravo ne shrani: po prvi prijavi aplikacija uporablja preklicljiv žeton, ki po 30 dneh neaktivnosti poteče. Z odjavo ga prekliče tudi na strežniku.
```

**English** (max 500 chars):
```
Version 1.2.0 (build 7)
• Persistent login: the app now remembers your login across launches and across returning from the background. When Android kills the app in the background (common on Samsung devices), it no longer prompts for re-login on the next open.
• Password is not stored on the device: after the first login the app uses a revocable token that expires after 30 days of inactivity. Signing out also revokes it server-side.
```

### 3.3e Release notes — v1.1.3+6 (historical, superseded)

**Slovene** (max 500 chars):
```
Različica 1.1.3 (build 6)
• Nova plast "Parcele": katastrske parcele iz javnega WMS-ja GURS (meje + številke pri večji povečavi). Vir: e-prostor, CC BY 4.0.
• Spodnja vrstica preoblikovana: drsni izbirnik načina (Motnje / Obhodi) z dvignjenim "+" gumbom.
• Po prijavi se počistijo zapisi prejšnjega uporabnika — menjava računa na napravi ne pušča sledi.
• Zgodovinski zapisi Notranjskega regijskega parka so zdaj del rednih motenj.
```

**English** (max 500 chars):
```
Version 1.1.3 (build 6)
• New "Parcele" map layer: Slovenian cadastral parcels from the public GURS WMS (boundaries + parcel numbers at higher zoom). Source: e-prostor, CC BY 4.0.
• Bottom bar redesigned: sliding mode picker (Motnje / Obhodi) with a raised "+" FAB.
• On sign-in, records from a previously signed-in user are cleared — switching accounts on a shared device no longer leaks data.
• Historical Notranjska Regional Park entries are now part of the regular Motnje layer.
```

### 3.3f Release notes — v1.0.1+2 (historical, superseded)

**Slovene** (max 500 chars):
```
Različica 1.0.1 (build 2)
• Združljivost naprav: aplikacija je zdaj vidna in jo je mogoče namestiti tudi na napravah, kjer je Trgovina Play prej prikazala "Ta izdelek ni na voljo za vašo napravo" (npr. Blackview Active 8 Pro). Strojne zahteve (kamera, GPS) so označene kot izbirne.
• Manjše izboljšave stabilnosti.
```

**English** (max 500 chars):
```
Version 1.0.1 (build 2)
• Device compatibility: the app is now visible and installable on devices where Play previously showed "This app is not available for your device" (e.g. Blackview Active 8 Pro). Hardware requirements (camera, GPS) are now declared optional.
• Minor stability improvements.
```

---

## 4. App Content questionnaire — answers

### 4.1 Privacy policy

URL: `https://alittis.github.io/terenska-beleznica/privacy/`. Stable; served from `Alittis/alittis.github.io`.

### 4.2 App access (login required)

Play asks: *"Are all parts of your app available without restriction?"* → **No, all or some functionality is restricted.**

Add **Instructions for review**:

```
Step 1. Tap "Prijava" on the launch screen.
Step 2. Enter the demo credentials below.
Step 3. After successful login the home map opens. The "+" button on the bottom right opens the disturbance entry flow (camera or codebook). The mode pill switches to "Obhodi" for walk-around recording.

Demo email:    axzrim+google@gmail.com
Demo password: see project/.credentials.local.md (gitignored)

Notes for reviewer:
- The account requires a server-side authorization in the Slovenian NarcIS system; this demo account is provisioned for Google Play review only and has limited test data.
- Network access is required for the first login (HTTPS to narcis.gov.si). The app then permits offline use for up to 14 days against a local password digest.
- Walk recording uses a foreground service typed "location" with a persistent notification. There is no background-location permission; tracking only runs while the user has explicitly started a walk.
```

> Provisioned 2026-05-07: NarcIS user `axzrim+google@gmail.com` (Gmail `+google` subaddress, mail still routes to the maintainer's main inbox) with `TERENSKA-BELEZNICA` authorization. Password lives in `project/.credentials.local.md` (gitignored) — copy from there into the Play Console **App access** form. Rotate or disable the account in NarcIS once the closed test ends.

### 4.3 Ads

*"Does your app contain ads?"* → **No**.

### 4.4 Content rating (IARC questionnaire)

Choose category: **Utility, Productivity, Communication, or Other**.

Question-by-question:

| IARC question | Answer |
|---|---|
| Does the app contain violence? | No |
| Sexuality or nudity? | No |
| Profanity or crude humour? | No |
| Controlled substances (alcohol/tobacco/drugs)? | No |
| Gambling? | No |
| Horror? | No |
| Does the app share user-generated content with others? | **Yes** (records visible to other members of the same organisation) |
| Does the app share user location? | **Yes** (precise location of records is shared with users from the same organisation only; not public, not with third parties) |
| Does the app allow users to interact (chat, messaging)? | No |
| Does the app share personal information with other users? | **Yes** (observer names typed into a record become visible to others in the same organisation) |
| Does the app provide unrestricted internet access? | No |
| Does the app permit digital purchases? | No |

Expected outcome: **IARC 3+ / PEGI 3 / ESRB Everyone**, with the "User-generated content" + "Users interact" + "Shares location" descriptors. Save and submit.

### 4.5 Target audience and content

- **Target age groups**: select **18+** only. (Wardens are professionals; the app is not designed for minors.)
- **Does the app appeal to children?** → No.
- **Apps directed to children policy**: not applicable.
- **Account creation in app**: No (accounts are provisioned externally in NarcIS; app only signs in).

### 4.6 News app

*"Is your app a news app?"* → **No**.

### 4.7 COVID-19 contact tracing and status apps

*"Is your app a public-health authority COVID-19 contact-tracing or status app?"* → **No**.

### 4.8 Government app

*"Is your app a government app published by or on behalf of a government?"* → **No**.

> Reasoning: the publisher on Play is **Alittis**, not ARSO. ARSO is the data controller for the field records, but is not the Play publisher. Selecting "Yes" requires a verifiable government affiliation document and is the wrong category for this account. Listing ARSO in the description and privacy policy as the data controller is sufficient.

### 4.9 Financial features

*"Does your app provide any financial features?"* → **No**.

### 4.10 Health features

*"Does your app provide health features?"* → **No**.

### 4.11 Data Safety form (the long one)

#### Did your app collect or share any of the required user data types? → **Yes**

#### Is all user data collected encrypted in transit? → **Yes** (HTTPS to `narcis.gov.si`).

#### Do you provide a way for users to request that their data is deleted? → **Yes**

Method to disclose: data deletion is handled out-of-band by ARSO administrators on request to `narcis.arso@gov.si`. (The app itself currently does not have an in-app delete-account button — that's on the roadmap; for now the privacy policy explicitly directs users to the ARSO contact.)

#### Data types collected (per Play's taxonomy)

For **every** entry below: collection is **required for app functionality** (or **optional**, where noted), data is **not shared with third parties**, and is **encrypted in transit**.

| Category | Data type | Collected? | Shared? | Optional? | Purpose |
|---|---|---|---|---|---|
| **Personal info** | Name | Yes | No | Optional | App functionality (the *observers* free-text field on a disturbance record) |
| **Personal info** | Email address | Yes | No | Required | Account management; app functionality (sign-in) |
| **Location** | Approximate location | Yes | No | Optional | App functionality (low-accuracy disturbance entries marked "Približna") |
| **Location** | Precise location | Yes | No | Required for the feature | App functionality (precise disturbance pins; live track points during a walk) |
| **Photos and videos** | Photos | Yes | No | Optional | App functionality (evidence photos attached to disturbance records) |
| **App info and performance** | Crash logs | No | — | — | (No Crashlytics / Sentry / Firebase wired in) |
| **App info and performance** | Diagnostics | No | — | — | (No analytics SDK; only local debug-prints during development) |
| **Device or other IDs** | Device or other IDs | No | — | — | (No advertising-ID, no install-ID, no GAID; only Android Keystore-backed secure storage) |
| **Files and docs** | Files and docs | No | — | — | |
| **Calendar** | — | No | — | — | |
| **Contacts** | — | No | — | — | |
| **Messages** | — | No | — | — | |
| **Audio** | — | No | — | — | |
| **Health and fitness** | — | No | — | — | |
| **Financial info** | — | No | — | — | |
| **Web browsing** | — | No | — | — | |

> **Note about photo metadata**: the `image_picker` flow with `maxWidth=1600, imageQuality=85` re-encodes the JPEG and **does not preserve EXIF GPS** by default. The location stamped on the record is the device's *current* GPS fix at intent time (see ARCHITECTURE.md §14), not the photo's EXIF. So we do not declare extra location data flowing in via photos.

#### Children's data

*"Is any of the collected data from users known to be children?"* → **No** (target audience 18+).

#### Compliance

- Are you compliant with the [Families Policy](https://support.google.com/googleplay/android-developer/answer/9893335)? → **Not applicable** (not a children's app).

---

## 5. Tester onboarding kit

### 5.1 Slovene invitation email

**Subject**: `Vabilo: zaprti preizkus aplikacije Terenska beležnica (NarcIS)`

**Body**:
```
Pozdravljeni,

vabimo Vas k zaprtemu preizkusu mobilne aplikacije Terenska beležnica (Android).
Aplikacija je namenjena naravovarstvenim nadzornikom za zapisovanje motenj,
obhodov in fotografij neposredno na terenu, s sinhronizacijo v sistem NarcIS.

— Kako se prijavite —

1. V Android telefonu odprite naslednjo povezavo:
   https://play.google.com/apps/testing/si.terenska.beleznica

2. Pritisnite "Postani preizkuševalec" / "Become a tester".

3. Po nekaj minutah lahko aplikacijo namestite iz Trgovine Play
   (poiščite "Terenska beležnica" ali sledite isti povezavi).

4. Za prijavo v aplikacijo uporabite Vaš obstoječi e-naslov in geslo iz
   sistema NarcIS. Če dostopa še nimate, pišite na admin@alittis.com —
   uredimo Vam pravico TERENSKA-BELEZNICA.

— Kaj prosimo, da preizkusite —

• Prijavo (z omrežno povezavo).
• Pregled zemljevida: motnje (vaše + sodelavcev), obhodi, zgodovinski
  zapisi Notranjskega regijskega parka.
• Zapis nove motnje (foto + tipi iz šifranta + opis).
• Snemanje obhoda: zaženite, hodite eno-dve minuti, zaklenite zaslon,
  spet odklenite — preverite, da snemanje ni bilo prekinjeno (poglejte,
  da je obvestilo "Snemanje obhoda" še vidno v statusni vrstici).
• Pregled lastnih motenj in obhodov v zavihku "Profil".
• Sinhronizacija brez omrežja: vklopite letalski način, zabeležite
  motnjo, izklopite letalski način — motnja naj se samodejno prenese
  (status v zgornjem desnem kotu zemljevida postane zelen oblaček).

— Kako poslati povratno informacijo —

Pišite na admin@alittis.com. Prosimo, navedite:
• model in različico telefona (npr. Samsung A56, Android 14);
• kratek opis: kaj ste storili, kaj je aplikacija naredila, kaj ste
  pričakovali;
• po možnosti zaslonsko sliko ali kratek video.

Pri zelo nujnih težavah (sesutje, izguba podatkov, nedelujoča prijava)
prosimo dodajte v zadevo besedo NUJNO.

Hvala za sodelovanje.

Lep pozdrav,
Alittis (založnik aplikacije v Trgovini Play)
v sodelovanju z ARSO – sistem NarcIS
admin@alittis.com
```

### 5.2 English invitation email (for non-SI testers, if any)

**Subject**: `Invitation: closed test of the Terenska beležnica app (NarcIS)`

**Body**:
```
Hello,

We would like to invite you to a closed test of the Terenska beležnica
Android app. It is built for nature-protection wardens to record
disturbances, walk-arounds, and field photos, with synchronisation
into the Slovenian NarcIS system.

— How to join —

1. On your Android phone, open:
   https://play.google.com/apps/testing/si.terenska.beleznica

2. Tap "Become a tester".

3. After a few minutes the app is installable from the Play Store
   (search for "Terenska beležnica" or use the link above).

4. Sign in with your existing NarcIS email and password. If you do
   not have an account yet, write to admin@alittis.com — we will
   set up the TERENSKA-BELEZNICA authorization for you.

— What we'd like you to test —

• Sign-in with network.
• Map browsing: own disturbances, your organisation's disturbances,
  walks, and bundled historical Notranjska records.
• Creating a disturbance (photo + types from the codebook + notes).
• Walk-around recording: start, walk for 1–2 minutes, lock the screen,
  unlock — confirm the "Walk recording" notification is still visible
  and the path was not interrupted.
• Personal lists in the Profile tab.
• Offline sync: turn on Airplane mode, save a disturbance, turn it off
  — the entry should sync automatically (cloud icon in the top right
  of the map turns green when in sync).

— How to send feedback —

Email admin@alittis.com. Please include:
• phone model and Android version;
• a short description: what you did, what the app did, what you
  expected;
• if possible, a screenshot or short screen recording.

For urgent problems (crash, data loss, sign-in fails) please put
the word URGENT in the subject.

Thank you.

Kind regards,
Alittis (Play Store publisher)
in cooperation with the Slovenian Environment Agency (ARSO) – NarcIS
admin@alittis.com
```

### 5.3 Tester registration intake

For each tester collected via reply email, store: full name, role / organisation, Google account email (the email under which they sign in to Google Play), date added. Spreadsheet is fine; no PII beyond what the user explicitly provided. Add the Google account email to the Google Group; the registration record is for the publisher's bookkeeping only.

---

## 6. Graphic assets — what's needed and where

| Asset | Spec | Status | Source |
|---|---|---|---|
| App icon (Play listing) | 512×512 PNG, 32-bit, < 1 MB | Need to generate from existing 1024×1024 | `sips -z 512 512 assets/icon/app_icon.png --out /tmp/play_icon_512.png` |
| Feature graphic | 1024×500 PNG/JPG, 24-bit (no alpha), < 15 MB | Builder authored 2026-05-21; regenerate per upload | `python3 tools/icon/build_feature_graphic.py` → `/tmp/play_feature_graphic_1024x500.png` (~77 KB at 24-bit RGB). Flower on the left, two-line "Terenska / beležnica" wordmark stacked on the right; title font auto-sizes to fit Play's 80% center safe zone. Reuses `build_icon.draw_flower()` + the green palette, so launcher-icon tweaks propagate automatically. |
| Phone screenshots | 16:9 or 9:16, 320–3840 px short edge, JPG/24-bit PNG, no alpha. 2 minimum, 8 maximum | **Captured 2026-06-15** → `~/Releases/play-screenshots-1.3.0/` (6 × 1080×2340, alpha stripped). Native ~20:9 (2.17:1) — pad to 2:1 if the uploader objects. | Capture order: login → home map → form → detail → walk-active → profile. |
| 7-inch tablet screenshots | optional | skip | n/a |
| 10-inch tablet screenshots | optional | skip | n/a |
| Android TV / Wear / Auto | not applicable | skip | n/a |
| Promo video (YouTube URL) | optional | skip | n/a |

---

## 7. After rollout — monitoring & cadence

- Watch **Play Console → Quality → Android vitals → Crashes & ANRs** for the first week. Internal-track crash data carries over.
- Watch **Pre-launch report** for the AAB (auto-generated by Play; Espresso-driven smoke run on a small device farm). Login screen failure is expected — the report bot won't have NarcIS credentials. Review only the *non-login* findings (rendering, accessibility, security warnings).
- Subsequent releases: bump `version: X.Y.Z+B` in `pubspec.yaml`, run `flutter build appbundle --release`, replace the AAB on the same Closed track via **Create new release**. No need to re-fill App Content unless the data-collection footprint changes.
- When promoting to **Open testing** or **Production**: same questionnaire answers carry over; the only new step is uploading to the higher track and waiting for re-review (typically faster).

---

## 8. Open items / TODO before submission

- [ ] Provision the Google review demo account in NarcIS; paste creds into §4.2 of this doc.
- [ ] Decide tester-source (Google Group vs. email list); create the chosen artifact.
- [x] Author the 1024×500 feature graphic and add a builder under `tools/icon/`. (2026-05-21 — `tools/icon/build_feature_graphic.py`; output at `/tmp/play_feature_graphic_1024x500.png`)
- [x] Capture the 6 phone screenshots on the A56. (2026-06-15 — `~/Releases/play-screenshots-1.3.0/01-login…06-profile.png`, 1080×2340, alpha stripped, from the v1.3.0+11 dev build.)
- [ ] Confirm the chosen Closed track name (`ARSO – zaprti test`) is the right label for stakeholders.
- [ ] Confirm category choice (Productivity vs. Tools).
- [x] After the first Closed release goes live: paste the Google-assigned **app-signing** SHA-1 / SHA-256 into `STATE.json → android_release.play_app_signing_cert_sha*`. (Done 2026-06-15.)
