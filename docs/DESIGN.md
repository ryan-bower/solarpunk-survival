# Design & Roadmap

Turn cozy **Solarpunk** (UE5, host-authoritative co-op listen-server) into a survival /
base-defense game. Principles: **Lua-first** (logic in UE4SS Lua, cooked paks only for what Lua
can't produce), **host is the single source of truth**, **everything defensive** (one broken hook
degrades one feature, never crashes), **one choke point** for fragile symbols (`Scripts/mapping.lua`).

## Milestone 1 — Deadly Storms + Destruction (current)

**Lightning** fires far more often during storms, sometimes in **bursts** (2–3 bolts). Every strike
is **telegraphed** by a ground decal ~`telegraph_lead` s before impact (multicast so all clients see
it); leaving `strike_radius` before it lands avoids the hit.

**Strike effects (host-authoritative):**

| Target | Effect |
|---|---|
| Player (in the open) | 70 % max HP; two hits = lethal. Death → respawn at base, drop carried items. |
| Crop | Killed, drops **no seed**. |
| Battery | **Fully charged**. |
| Drill / sprinkler / powered machine | Damaged → **smoking**; struck again while unrepaired → destroyed. |
| Airship (flying) | −1/3 airship HP; **crashes** at 0 (occupants take fall damage). |
| Other build pieces | Standard HP → destroyed at 0. |
| **Lightning Rod** (new, ≤25 m) | Intercepts every strike in range; grounds it safely, or charges a linked battery. |

**Targeting weights (host):** prefers players in the open; being **~100 m+ from any landmass**
massively raises strike odds; **flying in a storm** is the highest-risk state.

**Structures:** only strikes damage them (no passive erosion). Destroyed pieces drop **partial
salvage** (reuse the vanilla demolish refund, scaled by `salvage_frac`). Damaged "smoking" visual
**reuses the game's existing ship-damage smoke**. New content (**Storm Repair Tool**, **Lightning
Rod**) registers into the game's **existing unlock system**.

## Core framework (all features build on it)

`eventbus` → `config` → `net` (authority + replication) → `identity` (network/save-stable ids) →
`health` (damage component) → `save` (host-only persistence). Custom state lives on a replicated
`BP_ModStateActor` / `BP_HealthState` so Unreal replicates it natively; **Lua tables never sync**.

## Roadmap

0. **Bootstrap & RE** — install UE4SS, dump build `24038177`, populate `mapping.lua`. *(gates all code)*
1. **Core framework** — prove `BP_ModStateActor` host→client replication with two instances.
2. **Deadly Storms + Destruction** — this milestone.
3. **Enemies + AI** — host-only spawn/AI, replicated as normal actors; waves tied to storms.
4. **Defense buildings** — turrets (build on Lightning Rod + unlock foundation), walls.
5. **Weapons / player combat** — host validates hits; clients send fire-intent via Server RPC.
6. **Balance / polish** — ImGui → diegetic UMG HUD, difficulty presets, save migration.

Dependencies: `0 → 1 → 2`; 1 also unblocks 3/4/5; 4 needs 3; 5 needs 3+1.
