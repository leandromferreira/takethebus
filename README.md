# Bus Stop Fast Travel

A multiplayer-focused fast travel mod for Project Zomboid B42. Server admins place bus stops anywhere on the map; players walk up to a stop, pick a destination, pay the fare, and are teleported there with a cinematic fade transition.

---

## Features

- Admin-placed bus stops at any coordinate
- Per-stop price configuration (Free, Fixed, or Dynamic by distance)
- Configurable currency (any item type via Sandbox Options)
- **Economy integration** — connect any bank mod as the payment backend via a simple Lua API
- **Search bar + scrollable destination list** — find stops quickly even with dozens of destinations
- **Select-then-confirm** travel flow — click a stop to preview price, then confirm to travel
- **Random Trip** — surprise destination button with configurable price (optional, server toggle)
- Cinematic fade-to-black transition with bus arrival/departure sounds
- Arrival protection: zombies won't attack for a few seconds after teleport
- Return-trip memory: stops can remember where you came from
- Map markers showing all active stops
- Admin management panel to edit, go to, or delete any stop
- Per-player sound volume preference (Off / Low / Medium / High)

---

## How It Works

### For Players

1. Walk within 3 tiles of a bus stop sign
2. Right-click → **Use bus stop: [name]**
3. The travel panel opens — use the search bar to filter destinations or scroll the list
4. Click a destination to select it — the info line and travel button update to show the stop name and fare
5. Click **"Travel to [name]"** to confirm — the screen fades to black, you are teleported, and the screen fades back in
6. If the destination stop has **Return Trip** enabled, a return button appears at the top of the panel on your next use
7. The **Random Trip** button (if enabled by the server) sends you to a surprise destination

### For Admins

- Right-click any tile → **Build bus stop here** → enter a name
- Right-click near an existing stop → **Remove bus stop**
- Right-click anywhere → **Manage bus stops** to open the admin panel

---

## Stop Options

Each stop has the following configurable fields in the admin panel:

| Field | Description |
|---|---|
| **Display Name** | The name shown in menus and on the map marker |
| **X / Y / Z** | World coordinates of the stop (read from placement, editable) |
| **Price Type** | `Free` — no cost; `Fixed` — flat fare; `Dynamic` — calculated by distance |
| **Price Multiplier** | Multiplies the calculated fare (e.g. `2.0` doubles the price for this stop) |
| **Available** | When disabled, the stop is hidden from players and cannot be used as a destination |
| **Return Trip** | When enabled, traveling to this stop remembers your origin so you can return with one click |

---

## Sandbox Options

Found under **Sandbox → Bus Stop Fast Travel**:

| Option | Default | Description |
|---|---|---|
| **Pay with Items** | `true` | Deduct fares from the player's inventory. When both sources are active, items are deducted first. |
| **Pay with Bank** | `false` | Deduct fares via a bank mod API. The bank covers any shortfall that items could not cover. |
| **Bank Mod Global** | *(empty)* | Lua global the bank mod exposes its API under (e.g. `MyBankMod`). Required when Pay with Bank is enabled. |
| **Currency Item** | `Base.Money` | Item type players pay with (only used when Pay with Items is enabled) |
| **Base Price** | `1` | Minimum fare applied to every trip |
| **Price Per Tile** | `1` | Extra cost per tile of distance (divided by 1000, used in Dynamic pricing) |
| **Enable Random Trip** | `true` | Show the Random Trip button in the travel panel |
| **Random Trip Price** | `0` | Flat fare charged for a random trip (0 = free) |

### Dynamic Price Formula

```
price = ceil((BasePrice + distance_in_tiles * (PricePerTile / 1000)) * stop_multiplier)
```

---

## Economy Integration

BusStop supports pluggable payment backends. Any bank or economy mod can integrate by exposing a global Lua API table:

```lua
MyBankMod = MyBankMod or {}
MyBankMod.API = {
    canAfford   = function(player, amount) ... end,
    deduct      = function(player, amount) ... end,
    formatLabel = function(amount)         ... end,
}
```

Enable it in Sandbox Options by setting **Pay with Bank = true** and **Bank Mod Global = MyBankMod**.

Both sources can be active at the same time: items are deducted first, and the bank covers any remaining shortfall.

See [INTEGRATION.md](INTEGRATION.md) for the full protocol, a Survivor Shop bridge example, and fail-safe behavior.

---

## Multiplayer

- Fully server-authoritative: all travel requests are validated server-side
- Random trip destination is chosen by the server — clients cannot influence which stop is picked
- Admins and moderators can build/remove/manage stops
- Stop data is saved to `Zomboid/Lua/BusStopData.lua` on the server
- Stop list is broadcast to all clients on join and after any change
- Player sound preferences are stored in player ModData (per-player, persistent)

---

## Requirements

- Project Zomboid **B42** (Unstable or later)
- Admin or Moderator access level to manage stops

---

## Technical Info

| | |
|---|---|
| Mod ID | `BusStopFastTravel` |
| Version | 1.1 |
| Build | 42+ |
| Multiplayer | Yes |
| Added mid-game | Yes |
