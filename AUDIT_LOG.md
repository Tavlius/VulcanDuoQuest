# Improvement loop 1 — audits A1 (sync), A2 (API/UX), A3 (tests/docs)
Critiques/questions (>=12):
1 L/C lists built at queue time -> reordering phantoms (A1#1, A3#10)
2 Join of non-DuoQuest members triggers full resends (A1#2)
3 Messages accepted from any channel/sender (A1#3)
4 Unreadable roster names wipe partners (A1#4)
5 Auto focus flaps in 3+ groups (A1#5)
6 Empty/partial first scan & collapsed headers => false removals/pickups (A1#6, A2#3, A3#7)
7 Hello reply suppressed by FULL_GAP timing (A1#7)
8 N requests mistimed/never stop (A1#8)
9 Bye lost on throttle (A1#9)
10 Permanent send failure blocks queue (A1#11)
11 Turn-in shows false gap between D and C (A1#12)
12 Parser leniency / assemble crash on fractional part (A1#13-14)
13 Cross-realm name collisions (A1#15)
14 Complete quests wrongly unshareable (A2#1, A3#5)
15 Row anchors conflict -> broken layout (A2#2)
16 Duplicate notes when both accept together (A2#4)
17 Rest-area hub detection misfires; flight map on arrival; old gaps nag (A2#5-8, A3#8)
18 Warnings in combat; loud raid-warning sound; strangers (A2#9-11)
19 UNIT_SPELLCAST_START for all units (A2#12)
20 Failed scan not retried (A2#13)
21 Window jumps (center anchor), status wrap, drag, Esc (A2#14,16,17)
22 Share offered out of range; selection side effects; cursor skips (A2#15,18,20)
23 Secret test vacuous; DuoCore not self-contained/untested; version note missing (A3#1-3)
24 Weak assertions; 25/30 mutations survived (A3#4,#12)
25 Progress bars untested/wrong (A3#11)
26 Bindings/TOC unchecked; throttle not modeled; harness echo/instance realism (A3#13-15)
27 Lost progress U never healed (L has no content hash) (own)
28 Heartbeat runs with no DuoQuest peers (A1 critique)
29 Already-done quests only a count; spec says list next to yours (A3 critique)
30 Unwinnable class quests nag forever -> ignore list (A2#7)

## Loop 1 - audit round 1 (3 auditors): NOT clean
A (sync): 4 SHOULD - list restart starvation; every hello -> full resend (O(n^2)); N starves while partner busy; auto focus lost on reload.
B (UX): 1 MUST - Esc hide reappears in 5s; SHOULD - pre-reload/pre-sync gaps never warned; disabled Share no tooltip; share fails for collapsed quests; warnings while dead; notes noisy at shared giver; rest-area town trigger misfires (inn-only, mid-flight); boats undocumented.
C (tests/docs): MUST - collapsed share + share-next stuck; DuoCore lacks handshake (spec); reload silences warnings. SHOULD - vacuous silent-partner test, false harness comment, README test/status/combat/encounter claims, no generic long-payload split, 39 surviving mutations, harness gaps (realms, range unknown, throws, classic accept args).
Fixes: DuoCore handshake/session/bye/version-note/prune moved into DuoCore; SendLong; half-sent lists finish then repeat; targeted hello replies; full-send cooldown with deferred send; N after 25s even if busy; persisted auto-focus + pickup times (wall clock); unknown-age gaps warned once; walk-away hub detection (areas where you rested/handled quests), loading screens/takeoff arrivals, dead skip; notes quiet when together, wait for details; Share fallback by selection; motion scripts while disabled; Esc leaves window; status lists all; README rewritten sections; harness: realms, range unknown, throws, classic args, bounty, subzones, dead, spell names, per-file loading; mutate.py 115 mutations, 115 caught. Tests 377+87+68.

## Loop 1 - audit round 2: NOT clean
A (sync): MUST - long two-sided outage deadlock (heartbeat only when live); SHOULD - version with spaces -> endless hello loop; per-peer request spam; oldest one-way silent; DuoCore API traps (oversized item, Send over half list).
B (UX): MUST - UnitInRange is SecretReturns on 12.1 (verified in Blizzard API docs) so range never worked; held combat warning empty for walk-away/zone; SHOULD - own pre-reload gaps never warned; partner's far-away pickups warned "from here"; zone line mid-flight warns; finish note vs README.
C (tests): MUST - held warning empty; outage deadlock. SHOULD - same-second double warning; /dq check version "?"; expanded sections close on reload; /dq solo on backwards; mid-flight zone; 22 new surviving mutations; harness gaps (no-op unknown methods, fractional time, prefix gating).
Fixes: UnitDistanceSquared-based InRange/Near + map fallback; held keeps hub start; heartbeat continues (180s) when stale + hello every 120s when alone; lockdown pause (InChatMessagingLockdown); version sanitize; per-peer request limit 30s, per-peer ask 120s; one-way note; oversized items skipped; Send/again over half lists; Wire names; hub persisted across /reload (PEW isReloadingUi); told set (each gap once/session); away pickups excluded; mid-flight & corpse-run zone guards; quest-area hub naming; quest-log sound; solo invert; check shows version+distance; collapsed false; incompatible status; MAX_QUESTS 75; harness: widget-method allowlist, whole-second time, prefix registration gating, UnitDistanceSquared/secret UnitInRange/C_Map, lockdown, outage helper, reload PEW args. mutate.py 160 mutations, 160 caught. Tests 437+106+68.

## Loop 1 - audit round 3: NOT clean
A (sync): SHOULD - partner's done list arrives last (~30s wrong gaps); staggered login causes second full exchange. Fuzz/loss/outage/5-player all converged, 0 throttles.
B (UX): SHOULD - own away pickups warned "from here"; fight >30s after leaving loses gaps; note says click Share when Share is greyed. All 12.x APIs VERIFIED non-secret except UnitInRange.
C (tests): MUST - task/hidden/bounty quests accepted during play recovered via collapsed-header path; SHOULD - bonus-area accept marks hub; finish note lost via list; finish note ignores ignore list; README "both of you there" half true; README mutation count; per-API secret harness gaps; 28 meaningful surviving mutations.
Fixes: seen-in-loop set + IsTaskQuest (incl hidden via GetInfo) for recovery and hub marking; C list front on first list; reply to new sessions; awayMine; held warnings wait for the fight, dropped/hub-restored only if you fought back into the hub; far-note wording; finish note honors ignore + fires from list flags; Together = same hub (Near); pugs keep window down; bye waits out lockdown; secret group size = incomplete; Prune clears parts; trimmed truncation; dead code removed (5 spots); harness per-API secrets (12 APIs) + test; mutate.py 245 run (all caught) + 35 documented equivalents. Tests 525+115+68.

## Loop 1 - audit round 4: NOT clean
Findings (A sync, B UX/API, C tests/docs):
- B MUST: QUEST_TURNED_IN read xp as quest ID (bonus turn-ins marked field as hub). Fixed.
- A SHOULD: partner login during your loading screen invisible ~2 min. Fixed: list (or hello) after any non-login/non-reload loading screen; DuoCore defers missed-hello ask to the hello limit instead of dropping it.
- B SHOULD: false "Leaving <inn>" at the inn door. Fixed: area outside a rest area ("door") counts as hub (named subzones only).
- B SHOULD: unknown-age gaps re-dumped every login. Fixed: warned set saved (DB.told), pruned when a quest leaves both logs; partner pickup times/near flags saved per partner.
- B SHOULD: staggered arrival missed. Fixed: your own pickups at this hub count once partner is with you (theirs from elsewhere still don't).
- B SHOULD: held warning lost on death; second signal in a fight dropped the town. Fixed: held until alive (PLAYER_ALIVE/UNGHOST), earliest start and merged areas kept.
- B SHOULD: same-zone hearth kept old hub. Fixed: any loading screen but /reload = new hub.
- B SHOULD: classic collapsed headers dropped quests. Fixed via C_QuestLog.IsOnQuest + GetQuestObjectives (+ GetQuestInfo title) when present; harness classic mode now honours collapsed headers.
- B SHOULD: focus switched after reload in a trio. Fixed: last partner kept 30s after login/grouping and never overwritten while in group.
- B SHOULD: disconnect lost hub. Fixed: login within 10 min in same zone restores it (hub.at refreshed every tick).
- C MUST: test 61 zone-fallback check vacuous. Fixed.
- C SHOULD: ~20 meaningful surviving mutations (priorities, reload away flags, held-return areas, empty realm, send==true, builder throw, part 0, toggles, resetpos, tooltip, status) - tests added (tests_more.lua, tests_duocore.lua).
- C SHOULD: "not plained" equivalents were real crashes - static rule added (every secret-capable API call inside plain()/Bool()); harness secrets for zone/dead; secret IsUnitOnQuest test.
- Nits fixed: only named gaps marked warned; offline / sync-off status lines; RequestFull deferred if it can't send; README wording, boats, counts.
Tests: 526 + 119 + 84 + 87. Mutations r4: 47/47.

## Loop 1 - audit round 5: NOT clean
- A (sync): NO MUST/SHOULD. Nits fixed: new session id on sync on (lost bye), askDue cleared by their hello, usual partner's saved pickups never evicted, README resend-limit wording.
- B MUST: >5 gaps: the walk-back gap could fall into "and N more" and never be warned. Fixed: walk-back first ordering (known age, giver-only), every listed gap counts as warned, "(/dq status)" pointer.
- B SHOULD: own pickups while partner ungrouped/offline counted as together. Fixed: ns.Apart (no focus, offline, far).
- B SHOULD: hearth without loading screen kept hub. Fixed: UNIT_SPELLCAST_SUCCEEDED hearth = new hub.
- B SHOULD: double flight-map events. Now harmless (second finds all told); tested.
- C MUST: 14 stale mutate.py patterns (silently skipped). Replaced; runner now fails on skips.
- C SHOULD: re-picked quest not new; "share it now" wrong branch; zone-return lost hub name; ~15 untested branches (held cleared, PLAYER_ALIVE rez, rest-area return, classic collapsed carry-over/abandon, modern collapsed title after reload, unsynced-as-live, display-name focus, saved times before list, prune guard, ask/nobody/syncing texts); harness map for other instances; README limits (portals etc.). All fixed/tested.
- B nits fixed: rest areas flown over ignored, held warning re-checked each tick, partner reload keeps their quests up ("Resyncing").
Tests: 526 + 120 + 125 + 88.

## Loop 1 - audit round 6: NOT clean
- A SHOULD: offline main in the party kept the window over an online alt. Fixed (Online() in FocusPartner, lastPartner kept).
- B SHOULD: partner pickups from a session without you counted as unknown age -> "from here" next session. Fixed (partnerSeen.met; later first-list IDs are "apart").
- C SHOULD: partner inside a dungeon counted as "with you" (map nil). Fixed in Near (party units only; raid units = can't tell). Tests for zone-line new hub, 3-player non-focus notes (EQUIVALENT entry was wrong -> mutation), classic collapsed Share, chosen non-DuoQuest pickup ages, reload-while-apart guard, 200-yard boundary, 2-3 min drop. Harness H.reload carries clock + throttle.
- Nits fixed: askDue per peer; chosen-partner eviction case-insensitive; HEARTBEAT_STALE 120 < STALE_AFTER 150; bye from unknown peer -> "sync off" status (with redraw); pickup note waits for a resyncing partner; warning works while partner resyncs; town named after its streets not the inn; rest areas marked on landing/after loading screens; loading-screen flag for zone lines; "maybe missing" center text; stale comments; static secret-API list expanded; README (alt switching, pug wording, Astral Recall, tests_static, finished note).
Tests: 526 + 121 + 154 + 99. Full mutation run (round 6 start): 324/325, survivor reclassified as equivalent.

## Loop 1 - audit round 7: NOT clean
- A MUST / C MUST: Near compared a possibly secret map value with nil before plain() (would throw on 12.x and abort the quest scan). Fixed (issecretvalue + rawequal; Apart pcalled in Rescan); harness secrets.map; test.
- A SHOULD: the "met" rule marked a pickup beside you during a reload as apart. Fixed: saved.at (last heard); a gap under 2 min is judged as a pickup now.
- B SHOULD: hub with no handled quests (shopping) gave no walk-away warning for Mirel's pickups beside you. Fixed: partner pickup nearby marks your area.
- B SHOULD: "from the quest giver" wrong for item/shared quests. Wording now "can't be shared"/"can't share".
- B SHOULD: Share enabled while partner offline/other instance. Fixed (Apart) in window and /dq share.
- C MUST: reload-hub-areas and loading-flag-stuck untested; C SHOULD: Near/Apart can't-tell, FocusPartner rules, status/guards, askDue set, README heartbeat. All tested/fixed; harness login fires LOADING_SCREEN_DISABLED; H.reload carries world state.
- Nits fixed: "may be missing" wording; notes wait (uncounted) while partner resyncs; EQUIVALENT reason; stale comments.
Tests: 526 + 122 + 179 + 99. Round 6 full mutation run: 343/348, survivors now tested.

## Loop 1 - audit round 8: NOT clean
- A SHOULD: a quest whose progress changes every second starved the queue (partner resync 167s+). Fixed: changed quests jump the queue at most every 3s.
- A SHOULD (low): Unseen used the last-heard time (could predate the hub). Now "now".
- B SHOULD: logging out at the inn and back in the next day lost the town's gaps. Fixed: login at one of the saved hub's areas keeps the hub at any age.
- C MUST: README resend limit false for N requests. Fixed: N answered at most every 10s per partner; a quest asked again within 5s of being sent is resent when the gap ends.
- C SHOULD: untested taxi guard on partner-pickup marking, /dq share all, partner note how-text, unknown-distance partner pickups, NOTE_WAIT_MAX. All tested.
- Nits fixed: partner pickup marks your hub only within 60 yards and only a named spot (no renaming); not while dead; resting without the event marks the area on the next tick; UnitIsVisible = near (dungeon floors); a missing map inside an instance = can't tell; harness raid units have no map; EQUIVALENT reasons; comments; README.
Tests: 526 + 122 + 196 + 101. Round 7 full mutation run: 352/357 (survivors tested or reclassified).

## Loop 1 - audit round 9: NOT clean (B clean)
- A SHOULD: a quest changing again within 3s went to the back of the queue (29s behind a backlog). Fixed: the jump is postponed (frontDue), not cancelled.
- B: NO MUST/SHOULD (nits: README relog wording, comments, ghost resting).
- C MUST: "/dq sync ON" turned sync off (keywords case-sensitive). Fixed (args lowercased except partner names).
- C MUST: README claims (Share in instances, "handled quests" vs pickups, relog at the hub any time). Fixed.
- C SHOULD: dead landing line removed; tests for resend timing, 60-yard rule, third player, taxi tick fallback, unknown-distance notes, malformed D, duplicate-note guard, left-click, secret party data; harness: secrets.visible, offline units have no position, H.reload copies inInstance/titleCache.
- Nits: NEED_GAP 8s; Dead() on rest fallback; comments; EQUIVALENT reasons.
Tests: 526 + 122 + 212 + 101. Round 8 full run: 361/368 (survivors tested or reclassified).

## Loop 1 - audit round 10: NOT clean (A clean)
- A: NO MUST/SHOULD (nits: heavy grinding still slows a partner's resync at extreme rates; checksum width).
- B SHOULD: /dq while solo switched the window off for good. Fixed (ToggleWindow by visibility; hint on hide).
- B SHOULD: an accept on unnamed ground outside town made the zone's open country part of the town. Fixed (zone-name fallback only for a hub with no areas).
- C SHOULD (no MUST): offline partner while you're inside an instance, "maybe" wording, Astral Recall, classic hidden-quest share, unnamed rest spot, secret sweep (zone/dead/visible/map), ~14 untested user-visible strings. All tested.
- Nits fixed: status for a non-DuoQuest partner on all your quests, share message in a pug, README (resend wording, plain() claim, chain quests, closing the window).
Tests: 539 + 122 + 240 + 101. Round 9 full run: 378/379 (survivor now tested).

## Loop 1 - audit round 11: NOT clean (A clean)
- A: NO MUST/SHOULD (second consecutive clean sync round).
- B SHOULD / C SHOULD: the open-road stand-in swallowed the next town. Fixed: hub.wild gives way to the first named place; relog on the open road doesn't restore it.
- B SHOULD / C SHOULD: /dq silent in a pug. Fixed: says nobody to compare with.
- B SHOULD: offline partner with no data shown as missing everything. Fixed (no game-data guesses while offline; /dq status says offline).
- C MUST: /dq status said "doesn't run DuoQuest" when your sync was off or mid-sync. Fixed: uses the window's status reason.
- C SHOULD: 12 untested user-visible behaviours (per-row Share, failed text, both-ready objective lines, solo-on hint, toggle messages, addon menu, ignore on own notes, failed gap text, unlock, debug output, mouse wheel). All tested; harness models EnableMouseWheel/Wheel.
Tests: 539 + 122 + 263 + 102. Round 10 full run: 387/387.

## Loop 1 - audit round 12: NOT clean (A and B clean)
- A: NO MUST/SHOULD (third clean sync round). B: NO MUST/SHOULD (nit fixed: held warnings keep the road stand-in).
- C MUST: a quest handled inside the inn turned its area from "rest" to "quest", so stepping out marked no door: "Leaving <inn>" in the town square. Fixed (hub.rested/restArea).
- C SHOULD: rest ending while still in the inn's own area. Fixed: the first new named area within 5s is the door. Tests for the 15s reset when stepping back in, road-then-inn naming, no "hidden" line when showing.
Tests: 539 + 122 + 275 + 102. Round 11 full run: 403/403.

## Loop 1 - audit round 13: NOT clean (A and B clean)
- A: NO MUST/SHOULD (fourth clean sync round, line-by-line read). B: NO MUST/SHOULD.
- C MUST (round-12 regression): the inn-door window outlived a new hub (flight right after leaving the inn). Fixed: Arrived() closes it; it closes on taxi/death; resting ending at takeoff or as a ghost marks nothing.
- C SHOULD: the window opened on every end of resting (a fast exit could add the next area). Fixed: only when resting ends inside the inn's own area, for 2s, one place.
- Nits fixed: held warnings keep restArea; a zone-line warning held through a fight isn't cancelled by ending in another town.
Tests: 539 + 122 + 282 + 103. Round 12 full run: 409/409.

## Loop 1 - audit round 14: NOT clean (B clean)
- A SHOULD: "share next" / "/dq share all" offered ignored quests (class quests). Fixed.
- B: NO MUST/SHOULD (nit fixed: a rest area reaching past the inn door kept the inn's name).
- C SHOULD: an EQUIVALENT entry was wrong (unnamed city streets): mutation restored, tested. C SHOULD: a zone event before PLAYER_ENTERING_WORLD at login/reload replaced the saved hub. Fixed; both event orders tested.
- Nits fixed: .toc Notes wording.
Tests: 539 + 122 + 290 + 103. Round 13 full run: 415/415.

## Loop 1 - audit round 15: NOT clean
- A SHOULD: the turned-in list sent after a partner's pickup waited behind a backlog (false "doesn't have" note for a quest done long ago). Fixed (front of the queue).
- B SHOULD: the window's default spot covered the party frames. Moved to 260,-220 (old default migrated).
- C SHOULD: login placement untested; empty "You don't have:" line guard untested; RANK guard EQUIVALENT wrong (partner pickup could downgrade the town). All tested.
- Nits fixed: share accepted in flight/as ghost doesn't mark the area; /dq help lists show/hide and share <ID>; "1 quest" wording; README.
Tests: 539 + 122 + 297 + 103. Round 14 full run: 419/419.

## Loop 1 - audit round 16: NOT clean
- A SHOULD: after quick reloads, a turned-in list built from a half-received partner list wiped the partner's record (false "doesn't have" rows and a false flight warning). Fixed: no turned-in list until every partner's list is in. Nit fixed: a requested full list goes ahead of the backlog (resync 22s -> under 10s). Third player's pickups don't clear warned gaps.
- B SHOULD: after a drag the client re-anchors by the nearest corner, so the window grew upward. Fixed (re-pinned by top left); harness models the client's re-anchor.
- C SHOULD: turned-in list redraw and /dq status game view after the reason untested. Tested.
Tests: 539 + 122 + 306 + 103. Round 15 full run: 425/425.

## Loop 1 - audit round 17: NOT clean (A clean; B's one finding verified false)
- A: NO MUST/SHOULD. Nit fixed: a third player who said hello and went silent no longer holds back the turned-in list (stale partners skipped).
- B: claimed the share binding lacked category="ADDONS" - checked Bindings.xml: it has it (finding rejected); a static check now pins it for every binding.
- C SHOULD: two zone lines in a row untested; harness SetPoint appended instead of replacing (single-anchor checks added); harness drag moved frames that never started moving (row drag and locked drag tested); quest message size bound untested (property sweep + near-limit delivery test).
Tests: 539 + 122 + 317 + 105. Round 16 full run: 431/431.

## Loop 1 - audit round 18: NOT clean (A and B clean)
- A: NO MUST/SHOULD. B: NO MUST/SHOULD.
- C SHOULD: the close button was never clicked by a test; the show/hide key binding had no behaviour test. Both tested.
- Nits fixed: /dq share takes a quest link; /dq partner Name-YourRealm; /dq status marks an offline/stale partner's data as old and says when only ignored quests differ; /dq check reports a partner's sync off; collapse/ignore redraw at once; name-cache test; README.
Tests: 541 + 122 + 323 + 106. Round 17 full run: 436/436.

## Loop 1 - audit round 19: NOT clean (B clean)
- A SHOULD: /dq partner Name-Realm typed before grouping (or in other capitals, or a realm with a space) was saved as typed and never matched. Fixed: saved as a normalized key.
- B: NO MUST/SHOULD. Nit acted on: the wiki lists QuestLogPushQuest without arguments on recent clients, Blizzard's code passes an index: Share now selects the quest, pushes with the index, and restores the selection (works either way).
- C SHOULD: un-ignore and the immediate redraws untested. Tested.
Tests: 541 + 122 + 330 + 106. Round 18 full run: 444/444.

## Loop 1 - audit round 20: NOT clean (A and B clean)
- A: NO MUST/SHOULD. B: NO MUST/SHOULD (verified select/push/restore matches Blizzard's own Abandon/Share pattern).
- C MUST: /dq partner with a dashed realm (Ash-Vale) saved a key that never matched. Fixed (spaces and dashes stripped, as the game does).
- C SHOULD: /dq share with unreadable range, classic finished quest flag, partner progress redraw speed untested. Tested.
- Nits fixed: a secret "can be shared" reads as "try sharing"; push retried without its index if a client refuses one; an older saved "Name-YourRealm" focus still matches; /dq check lists SetSelectedQuest.
Tests: 541 + 122 + 337 + 106.

## Loop 1 - audit round 21: NOT clean (A and B clean; C one small gap)
- A: NO MUST/SHOULD. B: NO MUST/SHOULD.
- C SHOULD: "Ns ago" seconds form untested. Tested.
- Nit fixed: icon/atlas markup and named colours stripped from synced text. Harness option docs updated.
Tests: 541 + 122 + 341 + 106. Round 19/20 full runs: 444/444, 447/447.

## Loop 1 - audit round 22: NOT clean (A and B clean; C test gaps)
- A: NO MUST/SHOULD. B: NO MUST/SHOULD (ran the README's 5-minute check end to end in the harness; wording nits applied to README steps 3 and 5).
- C SHOULD: nothing tested behaviour after landing (an 'onTaxi stuck' EQUIVALENT entry was wrong); first sync mid-flight; a partner's finished progress bar. All tested; EQUIVALENT corrected.
Tests: 541 + 122 + 349 + 106.

## Loop 1 - audit round 23: NOT clean (A and B clean; C tooling + test gaps)
- A: NO MUST/SHOULD (Classic quest mechanics: escorts, chains, repeatables, deaths). B: NO MUST/SHOULD (performance: ~0.7 ms per redraw, flat memory over 4 h; no taint surface).
- C MUST (tooling): a stale mutate.py pattern after the Clean change. Fixed.
- C SHOULD: /dq check lines (entries vs quests, ready/not ready deliveries, "no" for a missing API) untested; an EQUIVALENT entry (classic accept under a collapsed header) was wrong. Tested; entry turned into a mutation.
- Nit fixed: range/party-quest events redraw only for your partner (raid churn).
Tests: 541 + 122 + 358 + 106. Round 22 full run: 458/458 (1 stale pattern, fixed).

## Loop 1 - audit round 24: NOT clean (B clean)
- A SHOULD: a quest under a header collapsed before DuoQuest first ran was never found (permanent false gap on both sides). Fixed: partners' quest IDs are looked for too (once per new ID), found ones get unknown age, not a pickup.
- B: NO MUST/SHOULD (verified UNIT_IN_RANGE_UPDATE payload is secret on 12.x, so the filter falls back to redrawing - correct).
- C SHOULD: tooltip ready/failed lines and partner quest level untested. Tested.
Tests: 541 + 122 + 362 + 106. Round 23 full run: 464/464.

## Loop 1 - audit round 25: NOT clean (A and B clean; C one test gap)
- A: NO MUST/SHOULD. B: NO MUST/SHOULD (verified the partner-ID lookup's API calls on 12.x and classic).
- C SHOULD: the 40-yard Share range was untested (30 or 60 survived). Tested at 35/50 incl. /dq share.
- Nits fixed: a quest seen in the log loop is never treated as a partner find (accept event lagging the log); EQUIVALENT reasons corrected.
Tests: 541 + 122 + 366 + 106. Round 24 full run: 469/469.

## Loop 1 - audit round 26: NOT clean (A clean; B 1 MUST; C 2 MUST + 4 SHOULD)
- A: NO MUST/SHOULD (1,800-run fuzz). NITs fixed: "he doesn't have" note/warning before his turned-in list arrived (own reload ~1.5s; his double reload; him offline). Fixed: p.doneIn (window says Syncing, no warning on his side until in), p.doneNow (notes wait for his current session's list, and while he's offline).
- B MUST: can't-share tooltip told you to get a quest that he needs. Fixed (names who gets it; no line for both/turned-in). NITs fixed: long status lines shortened; "Both on" header without partner column when not synced; help text; /dq check parens; 1.1 changelog as bullets.
- C MUST: stale mutate.py pattern (r24); a check that could never fail (link markup in pickup note pattern). Fixed. SHOULD: RELOG_KEEP, AWAY_FOR low side, greyed Share tooltips, waiting status when grouping mid-session: all tested.
Tests: 542 + 122 + 387 + 107. Round 25 full run: 471/471 (1 stale pattern, fixed). r26 mutations: 18/18.

## Loop 1 - audit round 27: NOT clean (A 1 SHOULD; B 1 SHOULD; C 1 MUST + 3 SHOULD) - all from the round 26 change
- A/B/C SHOULD (same bug): /dq status while his turned-in list was pending said "no gaps apart from quests you ignore". Fixed: says it's waiting; "you have all of his quests"; ignored line only when something is ignored.
- A NIT fixed: a silent third DuoQuest player held the turned-in list ~3 min (and a pickup note was lost). Now held at most 20s after that player's hello, retried each tick.
- C MUST: three mutate.py patterns stale after round 26 edits (the background run would fail). Fixed and rechecked. C SHOULD: tooltip getter on objective/turned-in rows; ", sending N" status. Tested. NITs tested: [0] level, "Objective 1", ignored tooltip line, "No quests to compare yet".
- B NITs fixed: leave-warning README paragraph as bullets; "/dq share" order wording; README Syncing wording.
Tests: 542 + 122 + 411 + 107. Mutations: 505 entries; r26/r27 subsets all caught (1 moved to EQUIVALENT).

## Loop 1 - audit round 28: NOT clean (B clean; A 1 SHOULD; C 1 MUST + 2 SHOULD)
- A SHOULD: a loading screen within ~1-3s of a login or /reload left sync half-done for ~1 min (false "doesn't run DuoQuest", missing turned-in list). Fixed (A's tested patch): after a loading screen while still waiting, start a new session and say hello; on a reloading partner's request, send the turned-in list at once.
- A NIT / B NITs fixed: window says "may not have" and /dq share(+all) waits while the turned-in list is pending; /dq status joins offline/stale + pending notes into one line, says when some are ignored, skips the empty "both on 0" summary; stale-while-pending says "no update", not "Syncing".
- C MUST: 4 more stale mutate.py patterns from round 27 edits. Fixed, and the cause too: `mutate.py --check` (patterns, duplicates, EQUIVALENT overlap) now runs in run.sh. r17 removed with its dead clause.
- C SHOULD: "Waiting for" window length; /dq share with one quest ("0 more"). Tested.
Tests: 542 + 122 + 433 + 107; 514 mutation patterns, 0 problems. r28 subset: 11/11 (3 moved to EQUIVALENT/removed with reasons).

## Loop 1 - audit round 29: NOT clean (B clean; A 1 SHOULD; C 5 SHOULD)
- A SHOULD: after the round-28 loading-screen restart, the partner stayed "Resyncing" ~1 min and a pickup note was lost (his answer's request was held back by REQUEST_GAP). Fixed: a new session clears peers' request times; the turned-in list goes out on any request once we have their list.
- C SHOULD: a mutant that didn't compile ('r5: nobody status'): fixed, and --check now compiles every mutant. Untested: list/turned-in resend after a loading screen, the doneIn part of "still waiting", /dq status for a quiet (online) partner, a refused share moving on. All tested (plus FOCUS_WAIT expiry, "1 quest").
- B NITs fixed: stray period before a status note; /dq share all "may not have" for game-only data and "not in a group"; offline partner called "offline" (not "isn't here") in the Share tooltip and /dq share; tooltip refreshes after a right-click; tooltip hint names notes and /dq share; solo message mentions /dq hide.
Tests: 542 + 122 + 452 + 107; 528 mutation patterns, 0 problems; r29 subset 14/14.

## Loop 1 - audit round 30: NOT clean (B clean; A 1 SHOULD; C 3 SHOULD)
- A SHOULD: a pickup during the partner's loading screen (message lost) gave a wrong "he doesn't have" note and his view stayed stale ~1 min. Fixed: after a loading screen a client also asks for the partner's list (an empty N = "send your list"); his client answers each new quest of yours (or one first seen in your list) with its turned-in list, even unchanged; the note waits for an answer received after the pickup. p.doneNow removed (subsumed).
- A NIT fixed: "Resyncing" forever when a reloading partner goes quiet -> "no update for".
- C SHOULD: quest-row done count untested (tested); run.sh tested a fixed sandbox path whatever tree it was in (now pins DQ_DIR/DQ_TESTS to its own tree); an EQUIVALENT reason that was a harness limit (harness option classicEmptyComplete; mutation restored and caught). NITs fixed: mutate.py counts a hanging mutant as caught; test 57 header.
- B NITs fixed: ignore wording consistent (warnings, notes and /dq share); /dq share all says why it can't share now (offline/not here/too far); one "still syncing" wording.
Tests: 544 + 122 + 469 + 106; 536 patterns, 0 problems; changed/new subsets all caught.

## Loop 1 - audit round 31: NOT clean (B clean; A 1 SHOULD; C 2 SHOULD)
- A SHOULD: a turned-in list built before he heard of your pickup but arriving after it still made a wrong "doesn't have" note (his loading screen ending ~5s after; a lost pickup message with heartbeats out of step). Fixed (A's tested design): his turned-in list marks the quests it answers for ("~id", learned in the last 120s); the note waits for an answer for that quest (or any list 70s+ later, for a client that doesn't answer). Swept in tests (loading end 0.5-7s; heartbeat phase 0-120s).
- A NIT fixed: the after-loading-screen list request has its own queue key (no longer replaces a details request).
- C SHOULD: /dq share all in another instance; reload + portal keeps "Resyncing" and his quests. Tested. EQUIVALENT reasons updated ('r3: request without done list'; 'notes from stale data' moved there).
- B NITs fixed: README ignore wording; "share it" for one quest; /dq share <ID> not in your log says so before range; quest row shows a single objective's own progress (6/10) and no duplicate sub-row, counts as "1/3 obj".
- Process fix: full mutation runs now run from a frozen snapshot copy (earlier runs were invalidated by edits during the run).
Tests: 544 + 122 + 476 + 106; 548 patterns, 0 problems.

## Loop 1 - audit round 32: NOT clean (A 1 SHOULD; B 2 SHOULD; C 3 SHOULD)
- A SHOULD: his turn-in during your loading screen (his D and heartbeat C both lost) left it as "his gap" with a Share button ~1 min. Fixed: an empty request (after a loading screen) is also answered with the turned-in list. Swept (5s/15s loads x heartbeat phases).
- B SHOULD: /dq share <ID> of an unshareable or failed quest blamed distance first; /dq share with him offline and no data said "isn't missing any quest". Fixed (ns.ShareBlocker checked first; "is offline: nothing to compare yet"). NITs fixed: "/dq share sends it" for one; "doesn't have:" (not "needs:") in share all; "?" while his details are on the way; README Both-on row.
- C SHOULD: STALE_AFTER low side; UNIT_SPELLCAST_SUCCEEDED unit filter on old clients; objective sub-rows without his DuoQuest. Tested. NITs: static check renamed; an EQUIVALENT reason corrected. Snapshot-31 full run: 'objectives always shown' survived (both ready on a multi-objective quest) -> tested.
- A NIT not fixed (documented here): a pending pickup note is lost if you /reload within its delay; the window and the leave warning still cover the gap.
Tests: 545 + 122 + 489 + 106; 558 patterns, 0 problems; r32 subset 10/10.

## Loop 1 - audit round 33: NOT clean (B clean; A 1 SHOULD; C 2 SHOULD)
- A SHOULD: after his loading screen, his list request used up the per-partner request budget, so his following request for details was dropped (~17s of stale rows). Fixed: the empty request has its own limit and is always answered with list + turned-in list. The loading-screen "still waiting" check simplified (only a missing list restarts; the turned-in list comes with the answer).
- A NIT: README says notes wait while he's offline "for a few minutes" (they give up after ~3 min).
- C SHOULD: the no-answer fallback (ACK_LATE) and NOTE_WAIT_MAX untested -> swept over heartbeat phases; ShareQuest fallbacks (push refusing an argument, index-only client, no push function) -> tested. NITs: a status test that matched a prefix fixed; the .toc version check now really reads the client's value (harness tocVersion); MISSING_MAX bound tightened (busy partner asked within 30s of noticing); right-click on objective/turned-in rows tested; a dead test alternative removed.
- B NITs fixed: quest IDs typed into commands accept whole numbers only (nan/inf no longer error or get saved); /dq share <his quest ID> says it's his; share-all "nothing" wording matches /dq share; help and usage say "quest ID or link"; the unshareable pickup note names who gets it; README Both-on row ("quests you both have", "-").
- Snapshot-32 full run: 553/558; survivors handled (2 tested, 1 removed with its code, 2 to EQUIVALENT with reasons).
Tests: 546 + 122 + 517 + 107; 568 patterns, 0 problems; r33 subset 14/14.

## Loop 1 - audit round 34: NOT clean (A clean; B clean; C 4 SHOULD)
- A: NO MUST/SHOULD (fuzz 200 seeds x 600 ticks; 1,531 notes checked, 0 wrong; 20,000 malformed messages, 0 errors). NITs fixed: a second list request within 8s is answered when the limit allows (not dropped), turned-in list first; his "picked up" note waits while he resyncs (your /reload) instead of being lost; a repeatable quest's turn-in no longer counts as "turned in" all session (only bridges the completed flag's lag, 60s; kept all session on clients without the flag).
- B: NO MUST/SHOULD. NITs fixed: his unshareable pickup note says "get it yourself"; "yours failed"/"Mirel's failed"; key-binding hint "press again (or /dq share)"; /dq solo wording; README table split into short rows + bullets, "How sync works" as bullets.
- C SHOULD: the static secret-value rule didn't cover pcall(API, ...) calls (now checked: 10 more checks); an EQUIVALENT reason was wrong (r31: backoff can be 120s) -> tested and restored; the loading-screen restart for a partner without a list was untested and worse than the normal path -> narrowed to "nobody heard from yet" (C's probes); the "/dq share <ID>" hint in the pickup note -> tested. NITs: empty-request limit, ignore undo/listing messages, 10-digit ID guard, objective label from his side tested; dead "|Hquest" pattern removed.
Tests: 546 + 122 + 532 + 117; 578 patterns, 0 problems; r34 + changed subsets all caught.

## Loop 1 - audit round 35: NOT clean (A clean; B clean; C 1 MUST + 3 SHOULD)
- A: NO MUST/SHOULD (fuzz 40 + 30 seeds with every note checked; the 9 flagged notes were same-tick races on the other client). NITs left: slower resync while the partner grinds (~50s for 25 quests' details); a pickup arriving before a just-reloaded partner's first list gives no note; a finish during your own /reload gives no note (window right).
- B: NO MUST/SHOULD. NITs fixed: /dq solo on while closed says how to open; "bigger pug or raid"; "no gaps between you and Mirel"; README section names; "window hidden" hint once a session; a drag ends if its row or the window hides (OnHide, button-up check); README softens the 40-yard share range and the first-time check measures it.
- C MUST: a check comparing a value with itself (classic collapsed delivery quest) -> fixed, now catches the mutant. SHOULD: TURNED_IN_LAG low side; title cut exactly 48 bytes (and 40 whole); the static pcall rule missed ok1/ok2 -> all tested/fixed. NITs: 10-digit ID test; list requests not answered forever.
Tests: 546 + 122 + 542 + 119; 586 patterns, 0 problems; r35 subset caught.

## Loop 1 - audit round 36: NOT clean (A clean; B clean; C 1 MUST + 2 SHOULD)
- A: NO MUST/SHOULD (fuzz 400 + 300 + 120 + 200 seeds incl. leave-warning truth checks; a leveling-day walk-through). NITs fixed: a note can come again for a quest picked up again a minute+ later (repeatables); an open-road hub says "Moving on", not "Leaving <zone>"; a loading screen while dead (releasing) doesn't start a new hub.
- B: NO MUST/SHOULD. NITs fixed: a hovered row/Share tooltip follows the redraw; "Waiting for" right after /dq sync on.
- C MUST: a negative check made vacuous by the round-35 wording change (and its scenario never reached the branch) -> rewritten. SHOULD: a held drag continuing (harness IsMouseButtonDown now button-specific); the solo "It's closed" note's two conditions -> tested. NITs: 9-digit ID accepted; answer order -> EQUIVALENT note.
- Snapshot-34 full run: 577/578; survivor (DuoCore NewSession clearing request times) pinned in tests_duocore.
Tests: 547 + 124 + 552 + 119; 598 patterns, 0 problems; r36 subset caught.

## Loop 1 - audit round 37: NOT clean (A, B, C each 1 SHOULD - the same bug; C 4 more SHOULD)
- A/B/C SHOULD: the round-36 "Moving on" lead was lost when the warning was held in a fight (the held hub's stand-in wasn't passed on). Fixed (CheckLeaving takes the held wild; nil-check) and tested.
- C SHOULD: login as a ghost (hub must start); header sliding under the mouse (tooltip hidden); NOTE_REPEAT bounds (45s/57s/75s re-pickups); the Later queue guard (was wrongly EQUIVALENT) -> all tested, mutations added.
- A NITs fixed: a note due during the partner's loading screen waits 3s after it (for the list answer); a partner's pickup right by you replaces an open-road stand-in (a door entry is always a named place).
- B: verified IsOwned tooltip refresh (no taint, no flicker), drag safety.
Tests: 547 + 124 + 562 + 119; 605 patterns, 0 problems; r37 subset 7/7.

## Loop 1 - audit round 38: NOT clean (A clean; B 1 SHOULD; C 2 SHOULD)
- A: NO MUST/SHOULD (fuzz 160 seeds with deaths, spirit healer, hearths, regroups, 3% loss). NIT logged (not fixed): a spirit-healer resurrection at the graveyard uses up the hub's warning there.
- B SHOULD: a Hearthstone that goes through while in combat printed "Before you hearth" after arriving. Fixed: "You hearthed away from <town>". Tested.
- C SHOULD: the 60-yard partner-pickup range's low side; exactly five gaps got a "(/dq status)" pointer off-by-one risk. Tested. Dead right-click tooltip code removed (Layout covers it).
- Remaining logged NITs (not fixed): ghost guards (share accept / inn door / hub.at while dead) untested; LOAD_QUIET and NOTE_TRIES lower bounds; spirit healer case; slower resync while the partner grinds; a pickup reaching a just-reloaded partner before his list gives no note; a finish during your own /reload gives no note.
Tests: 547 + 124 + 566 + 119; 607 patterns, 0 problems; r38 subset 3/3.

## Loop 1 status: STOPPED - did not converge (35 audit rounds, 4-38, no two consecutive clean rounds)
Per the audit-loop-protocols guardrail ("if a set number of cycles passes without two clean rounds, stop and escalate; non-convergence is a finding"), loop 1 stops here and is escalated to the user.
Pattern: A (sync/play) and B (UX/API) were clean in most recent rounds (A: 34, 35, 36, 38; B: 34, 35, 36); C (tests/mutations/docs) found real test gaps every round, many in code added by the previous round's fixes. Recent SHOULDs are timing edge cases (loading screens, combat holds), not core behaviour.
