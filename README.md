# Vulcan DuoQuest

Your duo partner's quest log next to yours, for **World of Warcraft: Forever**.

- **What each of you is missing**: your quests your partner doesn't have (with a **Share** button) and their quests you don't have.
- **Objective progress side by side** for quests you're both on.
- **A warning when you leave a hub** (flight map, Hearthstone, walking away, crossing into a new zone) if one of you picked up a quest there that the other doesn't have.
- **Notes in chat**: while you're at different hubs (more than ~200 yards apart), when your partner picks up a quest you don't have or you pick up one they don't; and (anywhere) when they finish the objectives of one you're both on and you haven't.

**Display only, no automation.** The one thing DuoQuest ever does in the game is share a quest, and only when you click Share, press its key binding or type `/dq share`. It never accepts, completes, abandons, casts, targets or moves for you.

Both of you need DuoQuest for the full picture. Without it on your partner's side, the window still shows which of *your* quests they're not on (the game reports that for party members), but not their quests.

Part of the **Vulcan Suite**: Vulcan GrindWatch · Vulcan RunBook · Vulcan SimBench.

## Install

- **CurseForge app** or **WowUp**: search for *Vulcan DuoQuest* and install it for World of Warcraft: Forever.
- **By hand**: unzip the download and copy the `VulcanDuoQuest` folder into the `Interface\AddOns\` folder of your Forever game folder (Battle.net > the Forever game > gear icon > *Show in Explorer*).

At the character screen, click **AddOns** and make sure Vulcan DuoQuest is ticked. If it's greyed out as "out of date", tick **Load out of date AddOns**. Your partner needs it too.

## The window

It appears when you group up with someone to compare with: a partner running DuoQuest, or the one other player in a two-person group (then it shows what the game reports about them). A bigger pug or raid without your partner keeps it down; `/dq solo on` keeps it up always. If your partner logs off in the group and plays an alt you've invited, the window follows whoever is online.

| Section | Shows | Right side |
|---|---|---|
| *Partner* doesn't have | Your quests they haven't got or turned in | **Share**, "can't share" or "yours failed" |
| You don't have | Their quests you haven't got or turned in | "ask *partner*", "can't share" or "*partner*'s failed" |
| Both on | Quests you both have | *you \| partner* (below) |
| *Partner* / You already turned in | Quests one of you did that the other still has (start collapsed) | |

- **Share** greys out while your partner is more than about 40 yards away, offline, or in a dungeon you're not in. "Can't share": they have to get it themselves, usually from the quest giver.
- **Both on** shows each side's state: ready, failed, a single objective's progress (6/10, 45% for a bar), or objectives done (1/3 obj); "-" for a quest without objectives, "?" while their details are on the way. Quests with several objectives get a line per objective until you're both ready.
- Hover a quest for both sets of objectives. Click a section header to collapse or expand it.
- **Right-click a quest** to ignore it in warnings, notes and `/dq share` (a class quest your partner can't take, say). `/dq ignore` (or `/dq ignore list`) shows them.
- Scroll with the mouse wheel, drag anywhere to move. The x (or `/dq`) closes it until you open it again with `/dq`, the key binding or the add-on menu; Esc doesn't, since it's meant to stay up while you play.

## The leave warning

You get one chat warning, a line in the middle of the screen and a soft sound when you:

- open a flight map ("Before you fly"),
- start casting your Hearthstone ("Before you hearth"),
- walk away from the hub ("Leaving Goldshire", or "Moving on" from a spot on the open road): 15 seconds out of town and outside every area that's part of this visit. Those are the areas where you rested or handled quests, where your partner picked up a quest within about 60 yards of you, and the area right outside an inn's door.
- cross into a new zone on foot ("You left Elwynn Forest", a last chance to turn back).

It only lists gaps picked up **since you arrived at this hub, with both of you there**: those are the ones that cost a walk back. Each gap is warned about once (remembered across logins). A warning names up to five quests per line, the ones that cost a walk back first; `/dq status` lists every gap at any time.

It never fires while you're dead (a corpse run isn't leaving), during a flight, for a random groupmate without DuoQuest (unless you picked them with `/dq partner`), or from out-of-date data. In combat it waits for the fight to end.

## Commands and key bindings

`/duoquest` and `/dq` both work.

- `/dq` show/hide the window (`/dq show`, `/dq hide`), `/dq status` every gap in chat
- `/dq share` share the next quest your partner needs, one per use (the game shows them one share at a time); `/dq share all` lists them; `/dq share <quest ID or link>` shares that one
- `/dq partner <name>` choose who to compare with in a bigger group (`/dq partner auto` to undo)
- `/dq ignore <quest ID or link>` leave a quest out of warnings, notes and `/dq share` (or right-click it); `/dq ignore list`
- Toggles (add `on`/`off`): `/dq warn` leave warnings, `/dq notify` chat notes, `/dq sound`, `/dq objectives`, `/dq solo` (window even with nobody to compare with)
- `/dq sync` sync on/off, `/dq lock`, `/dq unlock`, `/dq resetpos`
- `/dq check` what your client supports (and whether your saved data loaded), `/dq debug` prints every sync message

**Key bindings** (Options > Key Bindings > AddOns > Vulcan DuoQuest): show/hide the window, and share the next quest.

## How sync works

- **Hello:** when you group up, each client says hello and the others answer with their quest list.
- **Changes:** one small message per accept, progress, turn-in or abandon, and the list again every minute while a partner is around. The list has a checksum per quest, so anything a lost message left out of date is asked for again.
- **Turned in:** each side tells the other which of the other's quests it has already done, so you aren't told to pick up a quest you've done.
- **Loading screens:** afterwards a client sends its list again and asks for its partner's, in case either missed something.

**What it sends.** Addon messages go to your **party, raid or instance group only**, never to whispers, guild or public channels, and only while sync is on. Each starts with DuoQuest's sync protocol number. The message kinds are:

| Message | Contents |
| --- | --- |
| Hello / bye | your DuoQuest version and a random session ID; "bye" when you turn sync off or leave |
| Quest list | the quest IDs in your log, each with a few status flags and a short checksum |
| Quest update | one quest's ID, status flags, level, title and objective text with progress |
| Done | one quest's ID, when you finish its objectives |
| Turned in | IDs of your partner's quests that you've already turned in |
| Resend request | which quests your client needs again after a lost message |

Nothing else is sent: no location, no character details beyond your name (which the game shows anyway), no history. Messages are paced under the client's addon-message limit, wait while the game blocks addon messages (boss encounters), and are retried with growing gaps.

Both of you need a version that speaks the same sync protocol. If your versions differ, you each get a one-time note.

## Known Forever client issue: saved data

The Forever beta client has been reported to write add-on data to disk but sometimes fail to load it back, and then overwrite the good file the next time you log out or /reload. DuoQuest keeps its settings per character (window position, ignored quests, partner, notes about pickups). It also keeps a small account-wide file that only lists which characters have saved data.

- **It notices a failed load.** If a character on that list comes back with no saved data, DuoQuest warns you in chat instead of quietly starting from defaults. It tells you which file to copy before you log out or /reload. If both files fail at once, that looks like a fresh install and can't be detected.
- **Backing up by hand:** with the game closed, copy the `WTF` folder in your Forever game folder. DuoQuest's file is `WTF\Account\<account>\<realm>\<character>\SavedVariables\VulcanDuoQuest.lua`.

Community workaround tools exist. DuoQuest doesn't need or rely on any of them, and some work by editing add-on files that your add-on updater replaces.

## Limits

- Level, class and quest-chain requirements aren't known, so a quest your partner has may show as missing for you even if you can't take it yet. Right-click it to ignore it.
- "Hub" is judged by the areas where you rested or handled quests (plus the area outside an inn's door), and by flights, loading screens and zone lines.
- Boats, zeppelins, the tram, mage portals, dungeon entrances and teleports other than a Hearthstone have no departure signal: you hear about gaps about 15 seconds after you walk away from the hub (if that happens before the loading screen), otherwise not at all.
- Bonus objectives and other area tasks aren't compared: you both get those just by being there.
- On the classic quest functions, quests under a collapsed quest-log header are kept only if the client has `C_QuestLog.IsOnQuest` (`/dq check` lists it).

## Development

The repository is the add-on folder. Run every check (luacheck, the six test suites against a simulated two-client party, the mutation-pattern check, the personal-data guard, and a real package build) in the pinned container, from Git Bash or any shell with Docker:

    sh tests/docker.sh

After cloning (or right after `git init`), run this once before the first commit, from Git Bash on Windows (PowerShell has no `sh`). It sets this repository's commit identity and installs a pre-push hook that runs the personal-data guard over the tree and the whole history:

    sh tests/init_repo.sh

Commits must carry a GitHub noreply email address (`<id>+<username>` at `users.noreply.github.com`); the guard refuses any other address.

The GitHub Actions workflow runs exactly the same container on every push and pull request. Pushing a tag `vX.Y.Z` packages the add-on with the BigWigs packager and uploads it to CurseForge and Wago. The tag needs a matching `## vX.Y.Z` section in `CHANGELOG.md`. `python3 tests/mutate.py` (run by hand) breaks one meaningful line at a time and checks that some test fails each time.

- **Client version:** `## Interface: 16001` matches Forever 1.60.1. When the Forever client version changes, bump it in `VulcanDuoQuest.toc` and in `tests/tests_release.lua`.
- **Version:** the TOC's `## Version:` line holds the packager's version token (`project-version` between two `@` signs), and the packager replaces it with the tag. DuoQuest shows and sends it (`v1.2.0` as `1.2.0`), or `dev` when running from source. Sync compatibility goes by the protocol number in `Sync.lua`, never the version.
- **`DuoCore.lua`** is a self-contained channel layer (hello/bye with session IDs, the version note, a throttled queue, retries, splitting long messages). It only uses WoW API globals, and `tests_duocore.lua` loads it on its own.
- **Retiring the saved-data safety layer** once Blizzard fixes the client: delete `Persist.lua`, its TOC line, the `## SavedVariables: VulcanDuoQuestDB` line and `tests/tests_persist.lua`. Then remove the "Known Forever client issue" section here and the marker check in `tests/tests_static.lua`. Core.lua and Commands.lua only reach the module through `ns.Persist` checks.

## License

MIT. See [LICENSE](LICENSE). Changes are listed in [CHANGELOG.md](CHANGELOG.md).
