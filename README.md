# SideText

A native macOS client for Google Messages for Web. It's a clean-room rebuild of the
features in **Texty 1.3.13** (Tunabelly Software, `com.tunabelly.androidsms`), with everything
Texty locks behind "Texty Pro" turned on. There's no paywall, RevenueCat, newsletter, or review
prompt. No Texty code or artwork is included; [docs/FINDINGS.md](docs/FINDINGS.md) records what was learned from the installed app.

## Build

```bash
scripts/build-app.sh            # -> build/SideText.app (universal, ad-hoc signed, sandboxed)
scripts/build-app.sh --install  # also copies it to /Applications
scripts/test.sh                 # OTP, notification payload, and mark-read tests (requires Node.js)
```

Requires Xcode command line tools. No Xcode project or SwiftPM is used, because SwiftPM's own
sandbox can't run inside some restricted shells. Set `SIGN_IDENTITY="Developer ID Application: …"`
to sign with a real certificate.

## Features

| Feature | Texty | SideText |
|---|---|---|
| Google Messages in a native window, runs in background | Free | ✓ |
| Native notifications for new messages | Free | ✓ |
| Reply from notifications | Pro | ✓ |
| Copy one-time codes from notifications | Pro | ✓ |
| Automatically copy one-time codes (toast only, mark conversation read) | Pro | ✓ (off by default) |
| Dock unread badge | Pro | ✓ |
| Dock bouncing (once / until opened) | Pro | ✓ |
| Notification sound choice | Pro | ✓ (system sounds + `~/Library/Sounds`) |
| Custom download folder | Pro | ✓ (security-scoped bookmark) |
| Window space behavior (follow / retain) | Pro | ✓ |
| Scroll bar style (system / Google) | Pro | ✓ |
| Zoom level 50–200% (⌘+ / ⌘− / ⌘0) | Pro | ✓ |
| Launch at login | Free | ✓ (`SMAppService`) |
| Spellcheck + autocorrect in composer | Free | ✓ |
| Emoji font fix, draft kept across reloads | Free | ✓ |
| "Remember this computer" auto-on at pairing | Free | ✓ |
| Passkey → "Try another way" hint on Google sign-in | Free | ✓ |
| Offline / cannot-connect screens, auto-reload on network/wake, web-process crash recovery | Free | ✓ |
| Downloads named from the attachment, saved to Downloads/custom folder | Free | ✓ |
| Console Output window (page console + app log) | Free | ✓ (View menu) |
| Phone offline / back online notifications | Free | `NotificationManager.postPhoneStatus` exists but nothing calls it yet |

## How it works

- `MessagesViewController` hosts `https://messages.google.com/web/conversations` in a
  `WKWebView` (persistent data store, so pairing survives restarts).
- `WebScripts` injects page scripts. The key one replaces `window.Notification` (and
  `ServiceWorkerRegistration.showNotification`) with a shim that posts the title and options
  to native code through `webkit.messageHandlers.notify`.
- `IncomingMessage.parse` reads those options. Texty accepts two payload shapes, and so does
  this: `options.data.participants[…]` with `options.tag = "cid:<id>"`, or `options.data` as a
  base64 protobuf.
- With automatic code copying enabled, successfully copied OTPs show only the temporary green
  clipboard toast, without a native notification, sound, or Dock bounce. The app selects the
  verified OTP thread, checks that Google clears its unread flag, then restores the prior route
  when doing so would not consume a new unread message in another conversation.
- Inline reply queues the text, opens the conversation, fills the composer, and gets the Send
  button's coordinates. It then clicks with a real `NSEvent`, which is how Texty does it. If the
  composer doesn't clear, it falls back to a DOM click. If the send still isn't confirmed, the
  text is copied to the clipboard and you get an alert.

## Known limits

- Google changes the Messages web DOM from time to time. Selectors live in
  `WebScripts.swift` (`data-e2e-*` attributes, `mws-conversation-list-item`).
- Automatic mark-read requires an unchanged complete message snippet and either a trusted
  conversation ID or a unique exact sender match. It leaves drafts, ambiguous matches, and
  open menus alone. Guessed protobuf IDs are never used to select a conversation.
- Conversation identity uses `data-e2e-conversation` or a validated same-origin conversation
  URL. Read state uses Google's `data-e2e-is-unread` attribute, with legacy unread markers as
  a fallback. Unknown read state is never reported as success.
- The unread badge counts unread conversation rows, plus messages that arrive while the app
  is in the background and were not automatically handled as codes.
- The protobuf payload's exact field numbers aren't known. The parser pulls out strings
  heuristically, and the dictionary form is the main path.
