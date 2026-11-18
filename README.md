# keyfob

Menu bar app for dev tokens. Press a hotkey, type a few letters, hit return, and the token is on your clipboard. Secrets live in your login Keychain.

## Build

```sh
make run       # build build/keyfob.app and launch it
make install   # copy to /Applications (needed for Launch at login)
make icon      # regenerate Resources/AppIcon.icns
```

Requires macOS 26+ and a Swift 6.2+ toolchain with the macOS 26 SDK or newer (current Command Line Tools work). The code avoids `@State` because the Command Line Tools don't include SwiftUI's macro plugins.

## Search panel

| Key | Action |
| --- | --- |
| `⌥⌘K` | Toggle panel (configurable) |
| `↩` | Copy value |
| `⇧↩` | Copy as `export NAME='value'` |
| `⌥↩` | Copy as `NAME='value'` |
| `↑` `↓` / `⌃N` `⌃P` | Move selection |
| `⌘E` / `⌘N` | Edit selected / new token |
| `⌘O` / `⌘,` | Manager window / settings |
| `⌘L` | Lock session |
| `esc` | Clear query, then close |

Right-click the menu bar icon for the menu. A filled key icon means the session is unlocked.

## URL scheme

```sh
open "keyfob://search?q=github"
open "keyfob://new?q=Stripe"
open keyfob://manage
open keyfob://settings
open "keyfob://token?q=github"   # manager, best match selected
```

## Storage

Each token is a generic-password item with service `dev.keyfob.token`. The secret is the item data, and metadata (name, variable, tags, notes, expiry) is JSON in the generic attribute. Copy counts and last-used times stay in UserDefaults so copying never writes to the Keychain.

## Security

- Copy and reveal need Touch ID or your password once per session. The session ends after the idle timeout, on screen lock, sleep or fast user switching, or with `⌘L`.
- Clipboard writes are marked `org.nspasteboard.ConcealedType` and cleared after 30s if unchanged.
- The app is ad-hoc signed, so each rebuild has a new code signature. macOS will ask once per token per build to let keyfob read it. Choose "Always Allow".
