# Texty 1.3.13 — reverse-engineering notes

Target: `/Applications/Texty.app` (bundle id `com.tunabelly.androidsms`, build 6683, Mac App
Store, universal x86_64+arm64, sandboxed). This was static analysis only; Texty was never run.

## Sources examined

| Evidence | What it gave |
|---|---|
| `Contents/Info.plist`, `codesign --entitlements` | Sandbox, network.client, downloads r/w, user-selected r/w; LSMinimumSystemVersion 10.15 |
| `Resources/Defaults.plist` | All preference keys and defaults (mirrored in `Prefs.registerDefaults`) |
| `Resources/CustomScript.js` | Notification shim (`window.Notification` → `messageHandlers.notify.postMessage([title, options])`), draft save/restore in `sessionStorage`, XHR `loadend` hook → `ajaxFinished` |
| `Resources/InternetAccessPolicy.plist` | Hosts: Google, RevenueCat, Tenor, Sendy newsletter |
| `en.lproj/*.strings` | UI text, the Pro feature list, OTP/reply error strings |
| Interface Builder (REA `decode_interface_builder`, evidence `ev_7e2d0aed…`) | Preferences pane controls and their bindings (`preferencesManager.*`, `enabled: self.isProModeEnabled`), menu items/actions |
| Asset catalog (`assetutil --info`) | Colors and SF Symbol icons; not copied |
| `strings` on the executable | Embedded scripts: spellcheck enabler, emoji CSS injector, conversations-loaded observer, reply filler (`tbsReplyInit`), conversation selector, scrollbar stripper, settings/auth page tweaks, passkey popover, per-language OTP regex tables, protobuf message names (`texty.NotificationData`, `texty.NotificationMessage`, `texty.Participant`, …) |
| `otool -oV` ObjC metadata | Class list with ivars/methods, e.g. `MessagesViewController` constants (`URL_*`, `ZOOM_MIN/MAX/INCREMENT`), `UserNotificationManager` category/action ids, `SubscriptionManager._isPro`, `DockManager.dockBadgeNumber` |
| Ghidra 12.1.4 decompile of the arm64 slice | `FUN_100008790`: payload dispatch (`body` + `data` string → protobuf path; `data` dict → participants path). `FUN_100007e04`: dict path reads `data.participants[last].displayName/fullName/name`, `tag` with `"cid:"` prefix, phone split on `"•"`. `FUN_10000765c`: base64 → SwiftProtobuf decode. `FUN_10004a634`: badge only updated when `SubscriptionManager._isPro`. `FUN_100045e74`: Copy Code action unarchives the OTP from `userInfo` and copies it |

## Pro gating (observed)

`SubscriptionManager._isPro` (RevenueCat entitlement) gates the dock badge (decompiled), and
`isProModeEnabled` gates the Preferences controls (IB bindings). The notification categories
have `*_NOPRO_*` / `*_REQUIRES_PRO` variants that open the paywall in place of reply/copy. The
Pro feature list is from `ProFeaturesDescription`: reply from notifications, Dock badge and
bouncing, custom sounds, advanced settings, one-click 2FA code copy.

## Design choices in SideText (not from Texty)

- No subscription layer: everything is on.
- Notification sounds are played with `NSSound`, so any system sound works. Texty bundles its
  own `.aiff` files, and those aren't redistributed.
- Unread badge: the page's unread row count, or messages received while in the background,
  whichever is higher. Texty counts in-app arrivals only.
- Login item uses `SMAppService.mainApp` in place of a helper app.
- OTP detection uses one keyword list plus a nearest-code heuristic, not Texty's
  per-language prefix/suffix tables.

## Unknowns

- Exact protobuf field numbers for `texty.NotificationData` (the SwiftProtobuf name map gives
  field names but the decoder layout wasn't recovered).
- How Texty decides a phone is "offline" for its phone-status notifications.
