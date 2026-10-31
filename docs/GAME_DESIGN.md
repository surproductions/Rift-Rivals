# RIFT RIVALS — Game Design Document

## 1. Pitch

**Two teams. One charged shard. Break their rift.**

RIFT RIVALS is a top-down, physics-driven team sport for 2–8 players on one local
network. Each player pilots a *Riftrunner* in a compact arena split between two
teams, **EMBER ▲** (left) and **TIDE ◆** (right). Players don't carry the
shard. They strike it with **Pulses**, short shockwaves that launch it,
charge it and paint it in their team's colour. A charged shard is both the ball
and a weapon: it **shatters** any rival it hits. Score by driving the shard into
the rival team's goal (their *rift*).

Rounds last 1–5 minutes and matches are a single round or best of 3 or 5,
so a session fits between other things. Everyone understands the goal within
seconds; the depth comes from timing, angles and team positioning.

## 2. Core loop

1. **Kick-off.** Players spawn at mirror-symmetric positions; the shard sits at
   centre.
2. **Contest.** Players move with the stick and pulse the shard. Every pulse
   adds a level of charge (0–6) and makes the shard faster and more dangerous.
3. **Rally.** As charge rises, every touch becomes a decision: strike it at
   goal, parry it back, dash through it, or body-block it to bleed off charge.
4. **Score or shatter.** A goal resets to kick-off. A shatter removes a rival
   for ~1.6 s, opening space for a few seconds.
5. **Round ends** at the goal target or when time expires. A tie at time-out
   goes to **golden goal**. Then the next round starts, or the results screen.

## 3. Verbs (the whole control scheme)

| Verb | Input | Effect |
|---|---|---|
| Move | Left-thumb floating stick | Analog movement with momentum (eases toward target velocity). |
| **Pulse** | Right-thumb button (tap) | 118-unit shockwave. Launches the shard away from you, steered by the stick. +1 charge, or +2 and extra speed for a **Perfect** (point-blank) pulse. Knocks rivals back and staggers them; *slingshots* teammates forward. 0.53 s cooldown. |
| **Dash** | Small button | 8-tick burst. While dashing you are **intangible**: no collisions with players or the shard, so you can't be shattered. 1.33 s cooldown. |

Both actions are **buffered** for 8 ticks (133 ms): pressing slightly before a
cooldown ends still fires, which keeps the controls forgiving on touch screens.

## 4. Mechanics in detail

* **Charge (heat).** 0–6 pips orbit the shard. Max speed grows with charge.
  Charge decays one level per 1.25 s without a pulse; at 0 the shard turns
  neutral (white).
* **Shatter.** A shard of *your* colour, charged ≥ 2 and moving fast,
  shatters a rival on contact. Shattered players respawn at their spawn point
  with a brief shield.
* **Parry.** Pulsing a charged enemy shard redirects it. This is the main defensive skill.
* **Body block.** Standing in the path of a hostile shard you can't parry
  absorbs one level of charge (if it isn't fast/charged enough to shatter you).
* **Clash.** If both teams pulse the same shard on the same tick, the impulses
  cancel and the shard becomes neutral. Simultaneous actions are resolved from
  their geometry, never from player order.
* **Team play.** Ally slingshots, lane coverage, a rotating keeper, and baiting
  a rival's pulse before parrying all reward coordination.

## 5. Arenas (all mirror-symmetric)

| Arena | Identity |
|---|---|
| **The Foundry** | Open floor with chamfered corners. A pure skill test. |
| **Twin Rifts** | Two linked portal pairs (top and bottom) teleport the shard and players across the arena, so the shard can enter the enemy half from unexpected angles. |
| **Pillar Drift** | Two fixed central pylons and two pylons that drift up and down (a deterministic function of the tick), constantly reshaping the lanes. |
| **The Narrows** | Wedges choke the midfield into a tight central lane and two side channels; bank shots are strong here. |

## 6. Formats, rules and options

* **1v1, 2v2, 3v3, 4v4.** Up to 8 players. Empty slots can be filled by bots
  (Rookie / Veteran / Riftmaster).
* **Round length** 1, 2, 3, 5 min or untimed; **goal target** 3, 5, 7 or
  time-only; **series** single, best of 3, best of 5.
* **Modifiers:** Twin Shards, Hyper Shard (+35% speed), Mega Pulse (bigger,
  slower), Grounded (no dash), Glass Cannon (any charged shard shatters).
* **Autopilot:** a disconnected player's Riftrunner is piloted by the bot brain
  until they reconnect, so the team isn't left a player down.

## 7. Why this design suits local multiplayer

* **Readable at a glance.** The shard's colour shows who owns it, its pips show
  its charge, and its glow and trail show the danger. Spectators on the couch
  can follow the match without explanation.
* **Short, decisive moments.** Goals and shatters create spikes of reaction
  across the room. Rounds are short enough to rotate players.
* **Low input bandwidth.** The entire control state is 3 bytes per tick, which
  makes deterministic lockstep with rollback practical, and that is how
  8 players stay in sync without a server.
* **Latency-tolerant by design.** Actions are impulses rather than continuous
  aim, and the shard takes several frames to cross a pulse radius, so a few
  ticks of rollback correction are rarely visible. Pulses are generous areas,
  not pixel-precise hitboxes.
* **Fair by construction.** Arenas and spawns are mirrored. Simultaneous
  actions are resolved without player-index bias. Every rule is identical for
  host and clients.

## 8. Visual and audio identity

* **Palette.** Deep ink background; Ember coral `#FF5A3C` vs Tide aqua
  `#22E1C3`, with an optional colour-blind palette (orange `#FF9F1C` / blue
  `#3A86FF`). Teams are also marked by shape (▲ triangle notch vs ◆ diamond
  notch), so colour is never the only cue.
* **The rift motif.** A bright diagonal crack splits the logo, the app icon and
  the menu backdrop. The arena halves are faintly tinted, and goals pulse in
  their team colour.
* **Feedback.** Pulse rings, perfect-pulse flares, shatter bursts, screen shake
  and flashes (all reducible), plus haptics on your own hits.
* **Sound.** All effects are synthesized procedurally at launch (thumps,
  chimes, crystal shatters, a chord swell for goals), so there are no
  third-party samples.

## 9. Progression and replayability

Version 1 focuses on the competitive core: series play, per-player stats
(goals, assists, shatters, parries, downs), an MVP highlight, four arenas,
five combinable modifiers and three bot levels. Unlocks, ranked play and
cosmetics are deliberately left for later versions once online play exists
(see `NETWORKING.md` → *Future online play*).

## 10. Tuning reference

All constants live in `Sources/RiftCore/Game/Simulation.swift` (`Tuning`).
Units: 1600 × 900 world units; speeds in units per tick at 60 Hz.

| Constant | Value |
|---|---|
| Player radius / max speed | 28 / 7.5 |
| Pulse radius / cooldown | 118 / 32 ticks |
| Dash speed / duration / cooldown | 19 / 8 / 80 ticks |
| Shard radius / base max speed | 20 / 14 (+2.5 per charge) |
| Shatter threshold | charge ≥ 2 and speed ≥ 9 |
| Respawn | 96 ticks, then 45 ticks of shield |
