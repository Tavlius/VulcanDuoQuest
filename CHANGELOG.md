# Changelog

## v1.2.0 - first public release

- Now **Vulcan DuoQuest**, part of the Vulcan Suite. `/duoquest` and `/dq` both work.
- New: if the Forever client fails to load this character's saved data, DuoQuest says so and
  tells you which file to keep, instead of quietly starting from defaults.
- Fixed: a packaged release showed and sent its version as 1.1.0 whatever it really was. The
  version now comes from the release tag (and reads "dev" when run from source).
- Sync uses a new message name, so both of you need this version to see each other.
- Frame accent in the Vulcan Suite's ember orange.

## 1.1.0

- **Leave warning**: only gaps picked up at the hub you're leaving with both of you there, each
  once (remembered across logins). Walking away replaces the rest-area check. Takeoff, any
  loading screen and zone lines start a new hub; a /reload or a quick relog keeps it. Held during
  combat; never while dead or flying.
- **Distances** measured directly (the in-range check is a secret value on newer clients). A
  pickup of your partner's right next to you makes the spot part of your hub.
- **Notes**: quiet while you're at the same hub; one note per quest.
- **What's compared**: bonus objectives, hidden trackers and bounties never are. Quests under
  collapsed headers are kept. "Already turned in" sections. Progress bars as percent.
- **Share**: also for finished quests; greyed out out of range, while your partner is offline or
  in a dungeon you're not in. `/dq share` cycles through them. Ignore list (right-click).
- **Sync**: checksums heal lost updates, turn-ins known at once, group channels only,
  cross-realm names, version note, list resent after a loading screen.
- **Window**: status line says when your partner is offline, turned sync off or is resyncing.
  Follows an online alt over an offline main.

## 1.0

- First version.
