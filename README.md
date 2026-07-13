# Immich iOS Deduplicator

A small SwiftUI utility for cleaning up duplicate iOS Photos assets that would otherwise be re-uploaded to Immich after the web duplicate resolver removes the server copy.

The app:

- Scans the local Photos library with PhotoKit.
- Calls Immich's duplicate API.
- Shows how many duplicate groups and delete candidates were found.
- Deletes local smaller copies first.
- Resolves the matching Immich duplicate groups afterward.

## Open in Xcode

Open `ImmichDeduplicator.xcodeproj` on macOS with Xcode, set your signing team, and run on an iPhone. The app needs full Photos access to delete assets.

Use an Immich API key with duplicate read/delete permission and enter your server URL, for example:

```text
https://immich.example.com
```

## Safety Notes

The app only deletes local assets that are either:

- Matched to a server duplicate asset with high confidence, or
- Part of a strict local duplicate group with the same media kind, dimensions, and capture second.

It deletes local Photos assets before resolving server duplicate groups. If the Photos deletion fails or the user cancels the system deletion prompt, the server is left untouched.
