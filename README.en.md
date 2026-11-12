<p align="center">
  <img src="docs/images/app-icon.png" width="120" alt="3106">
</p>

<h1 align="center">3106</h1>

<p align="center">
  A no-jailbreak iOS container manager: app data, patches, cleaning, wallpapers, and dialer themes.
</p>

<p align="center">
  <a href="README.md">简体中文</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="docs/PATCH_GUIDE.md">Patch guide</a>
</p>

## Project

| Item | Value |
| --- | --- |
| Version | **3.2.3** (stable) |
| Current release | **v3.2.3** (build 21, fixed on-device .tendies imports failing with noDescriptors: containment no longer depends on symlink resolution) |
| Supported systems | iOS 17.0–18.7.1 · 26.0–26.7.2 · 27.0–27.3 (verified) |
| Access backend | kernel / `bad_query` / `worse_query` (selected automatically by OS version) |
| UI languages | Simplified Chinese · English · Vietnamese |
| Signing | iOS 26.7+ / 27.x requires an App Group entitlement |
| Bundle ID | `com.qingtang.3106` |
| Repository | <https://github.com/QuinnTang74/3106.git> |

## Features

| Module | Description |
| --- | --- |
| MobileGestalt cards page | Erosion-style staged toggles with one Apply button, Apple Intelligence 4-element checkup (config vs. on-device), factory restore, 31 presets (display/device/iPad/intelligence/advanced), lock states and factory-baseline protection |
| CacheExtra field editor | 8 types (incl. Array/Dictionary XML fragments), search/add/edit/remove, plist import/export, type-faithful |
| Region & Siri AI | Region triplet + regulatory model (verified machine table), native Siri AI / experimental mode, anti-bounce protection |
| Arbitrary file replace | Pick app → browse container directories → pick file → optional backup → replace; persistent log, one-tap restore, saved presets; protected-path rails |
| Supervised Mode | ConfigurationProfiles `IsSupervised` toggle (MDM warning + risk confirmation) |
| App save backups | Documents + Library/Preferences as `.3106save`; restore re-matches the container by bundle ID after reinstall |
| Backup tab (top level) | Auto-backup explainer, snapshot overview, full backup `.3106fullbackup` (manifest + one-tap restore), save-archive preview, activity timeline |
| Cleaner | Defense in depth (16-path blacklist + dev/ino identity re-check + three-stage gate), budgeted measurement + incremental cache, per-app progress, cumulative stats |
| File browser | Container navigation, size column + sorting, index age label, AppCard rows, Hex/Plist/SQLite tools |
| Enumeration speedups | LaunchServices DB direct read (incl. iOS 26.5 layouts), parallel MCM activation, dynamic pathleak ceiling, scan diagnostics |
| Wallpapers & dialer | `.tendies` PosterBoard wallpapers (moved into the feature hub), dialer key themes (per-file backup/restore) |
| Sources | AltGallery as the sole default source (AltStore-format adapter, 61 apps); IPAs hand off to the share sheet for the user's signing tool |
| Update check | Automatic at launch + manual in Settings; new versions open GitHub Releases |
| Risk system | Structured three-part risk copy per write feature + full-screen red confirmation (1.2s hold) + version-limited red banner |
| Languages | Simplified Chinese · English · Vietnamese |

## Recent updates

| Version | Highlights |
| --- | --- |
| **3.2.3** | Stable: fixed every on-device `.tendies` import failing with noDescriptors (issue #2: path containment no longer depends on symlink resolution; any /var vs /private/var spelling mix is accepted) |
| **3.2.2** | Stable: fixed Gestalt cards dark mode (card backgrounds are dynamic; no more white-on-white in dark theme) |
| **3.2.1** | Stable: checkup row states (unmodified=neutral / written&match=green / mismatch=warning, all-red-X on iOS 26), saved replace presets with one-tap reuse, backend reachability fix (kernel backend reaches system groups), File Replace banner removed, Settings update check |
| **3.2.0** | Stable: full parity (see the feature table above and CHANGELOG); WQ Files 0.9.1 iOS 26.5 layout sync; iOS 27.3 beta 1 promoted to stable; AltGallery source; Erosion-CN v0.8.5 factory-baseline protection; credits expanded to 9 entries |
| **3.1.13** | Feature hub + fixed five tabs; LaunchServices fast catalog; backup center and verified writes; scan progress/stop; safe MobileGestalt subset, keypad themes; SQLite/hex/plist tools |

## 3.2 details

### MobileGestalt cards page (Erosion-CN interaction model)

- Staged toggles written together by the top-right **Apply** button; each row shows its staged state; unapplied changes can be discarded as a group.
- Apple Intelligence activation 4-element checkup: sales region / US regulatory model / China-model gates / on-device AI admission, each row comparing config vs. on-device truth; row states are unmodified = neutral, written & matching = green check, mismatch = orange warning, and all-red-X on iOS 26.0–26.6.1.
- Status card: device-verification entry, dual factory backup note, and a one-tap factory restore (with confirmation).
- 31 presets across display / device / iPad / intelligence / advanced; lock states (natively enabled = pale-green locked against accidental disable; factory-baseline protection = orange lock).
- CacheExtra field editor: 8 types, plist import/export, type fidelity (`CFBooleanGetTypeID` / `CFNumberIsFloatType`).

### Arbitrary file replace (new module)

- Pick an app → navigate its container directory by directory → pick a file → optionally back up the original → replace. Works on both iOS 26 and 27 backends.
- The replace log persists across relaunches; one-tap restore of the backup, with the live file renamed aside first.
- Saved presets: store an app + path combo and re-anchor the whole flow with one tap; deletes are always backed up.
- Protected-path rails: the Gestalt cache, configuration profiles, keychain files and system prefixes are refused with localized reasons.

### Backup center (top-level tab)

- Five tabs: Features / Files / Search / Cleaner / **Backup**; wallpapers moved into the feature hub.
- Full backup `.3106fullbackup`: Gestalt cache + configuration profiles + patch workspace + snapshot index, with a manifest and a fresh pre-restore backup per target.
- App save backups: Documents + Library/Preferences as `.3106save`, re-matched by bundle ID after reinstall.
- Activity timeline: backup / restore / clean / write events in one list.

### Region & Siri AI

- Region triplet (LL/A) + regulatory model auto-matched from the verified machine table; only existing keys are written (anti-bounce).
- Native Siri AI (no hardware spoofing) / experimental mode (spoof + `SiriMode=2`, iOS 27+, unknown machines refused).
- Factory-baseline protection: Audio Intelligence ships false; forcing it breaks photos' high-quality Clean Up (Erosion-CN v0.8.5, device-verified).

### System-level and cleaner

- Supervised Mode toggle; app save backups; system container shortcuts.
- Cleaner defense in depth: 16-path blacklist, (dev,ino) identity re-check, three-stage confirmation gate; budgeted measurement + incremental cache; per-app progress; cumulative stats.
- Enumeration speedups: parallel MCM activation, concurrent lsd probes, dynamic pathleak ceiling, scan diagnostics (watchdog).
- Sources: AltGallery as the sole default source (AltStore-format adapter); downloaded IPAs hand off to the share sheet.
- Update check: automatic + manual; risk system: structured copy + full-screen red confirmation + version-limited red banner.

## Install & signing

The IPA is unsigned and must be signed with your own tool (LCSign / Sideloadly / Impactor / Xcode).

**iOS 26.7+ / 27.x must keep the App Group entitlement** (Sideloadly drops it; use Impactor or Xcode).

Current build: `3106-3.2.3-unsigned.ipa` (SHA256 `4f47344764422731bd33b77f3aad8d39d25f67ef8a564bee9e2c5ced0d4c6fae`).

## License

GPL-3.0-or-later. Based on 3105 (YangJiiii) and worse_query (forcequitOS) among other GPL projects; see NOTICE.md and the in-app acknowledgements (9 entries).