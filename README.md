# Clipnotch

A macOS notch panel with two things in it: a universal Now Playing player and a
clipboard history built for pasting several screenshots in a row.

Built for macOS 14+, tested on macOS 26.5. Inspired by
[boring.notch](https://github.com/TheBoredTeam/boring.notch) but written from
scratch and cut down to these two features.

## The clipboard queue

The point of the clipboard pane is the paste queue:

1. Take several screenshots (`⌘⇧4`, straight to the clipboard as usual).
2. Hover the notch, or press `⌘⇧V`, and open the **Clipboard** tab.
3. Click the clips **in the order you want them**. Each gets a number badge.
4. Go back to your editor and press `⌘V` once per clip. Each press pastes the
   next one in the queue.
5. When the queue drains, your original clipboard is restored.

Why it works this way: Clipnotch never synthesises a `⌘V`. It pre-arms the
system pasteboard with the head of the queue and installs a **listen-only**
event tap. Your real keystroke does the pasting; the tap only notices it
happened and swaps the next clip in afterwards. A bug here can leave the wrong
clip armed, but it can never break `⌘V`.

Copying something new outside the app cancels the queue — that's the escape
hatch, along with the **Clear** button and the menu bar item.

### Accessibility permission

The event tap needs Accessibility access. Until it is granted, clicking a clip
just copies it (no sequencing). Grant it in
**System Settings → Privacy & Security → Accessibility**.

macOS ties the grant to the app's signature, not its path. An **ad-hoc**
signature is identified by the binary's hash, so every rebuild looks like a
different app and the grant has to be given again. Signing with a stable local
certificate instead makes the designated requirement
`identifier "kz.appstream.clipnotch" and certificate leaf = H"..."`, which
survives rebuilds — grant it once and it stays.

`build.sh` uses the certificate named **Clipnotch Local Signing** if it finds
one, and says so; otherwise it falls back to ad-hoc and warns that the grant
will need re-giving. To create it:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=Clipnotch Local Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# LibreSSL, not OpenSSL 3: `security import` cannot read the newer PKCS#12
# encryption that OpenSSL 3 writes by default.
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem \
  -out bundle.p12 -passout pass:clipnotch -name "Clipnotch Local Signing"

security import bundle.p12 -k ~/Library/Keychains/login.keychain-db \
  -P clipnotch -T /usr/bin/codesign

# Prompts for the keychain password. Until this runs, `security find-identity
# -v -p codesigning` reports the identity as invalid and build.sh stays ad-hoc.
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db cert.pem

rm key.pem bundle.p12   # the private key now lives in the keychain
```

The certificate is self-signed and trusted only in this machine's user trust
settings. It is for keeping a local TCC grant stable — it says nothing about
the app's provenance to anyone else.

The public certificate is kept at
`~/Library/Application Support/Clipnotch/local-signing-cert.pem`.

After switching from ad-hoc to the certificate, remove and re-add Clipnotch in
the Accessibility pane once — the old ad-hoc grant does not carry over.

## Now Playing

Reads the system-wide now-playing session, so it works for any player that
publishes to it — Spotify, Apple Music, a YouTube tab, Yandex Music, VLC.

Apple restricted the private MediaRemote framework in macOS 15.4. The way
around it is [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
by Jonas van den Berg (BSD-3-Clause): the framework is loaded inside
`/usr/bin/perl`, which is still entitled to use it, and now-playing state is
streamed back as NDJSON. `Resources/mediaremote-adapter.pl` and
`Resources/MediaRemoteAdapter.framework` are that project's artifacts.

Shown: artwork, title, artist, album, a draggable progress bar, and
previous/play-pause/next. Progress is extrapolated from `elapsedTime` plus
`playbackRate` so the bar moves smoothly between stream updates.

## History retention

Payloads live in `~/Library/Application Support/Clipnotch/`, images as PNG files
plus a JSON index. Auto-purge runs on launch and after every insert, and deletes
the files, not just the index entries. Defaults: **200 clips** or **7 days**,
whichever hits first. Both are adjustable in Settings, along with
`Clear history now`.

Content marked with `org.nspasteboard.ConcealedType` (what password managers
set) is skipped and never written to disk.

## Build

Needs only the Command Line Tools — no Xcode.

```bash
./build.sh          # -> build/Clipnotch.app
open build/Clipnotch.app
```

`build.sh` runs SwiftPM, assembles the `.app` by hand, copies the adapter
resources in, and ad-hoc signs it.

## Controls

| Action | How |
|---|---|
| Open / close panel | Hover the notch, or click it |
| Open clipboard directly | `⌘⇧V` |
| Add clip to queue | Click a card |
| Remove from queue | Click a queued card again |
| Preview an image full size | Hover a card, click the eye |
| Delete a clip | Hover a card, click the trash |
| Clear the queue | **Clear** in the queue bar |
| Settings, quit | Menu bar icon |

## Layout

```
Sources/Clipnotch/
  main.swift, AppDelegate.swift
  Core/          settings, logging
  Notch/         window, CGS private space, notch shape, geometry, open/close state
  NowPlaying/    perl adapter bridge, observable model
  Clipboard/     capture, on-disk store, pasteboard read/write
  Paste/         paste queue + event tap, Accessibility state
  Hotkey/        Carbon RegisterEventHotKey wrapper
  UI/            SwiftUI views, menu bar, settings window
```

## Third-party

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) — BSD-3-Clause
- `Notch/CGSSpace.swift` derived from [Parrot](https://github.com/avaidyam/Parrot) — MPL-2.0

No other dependencies.
