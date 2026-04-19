# Bus Stop Fast Travel

A multiplayer-focused fast travel mod for Project Zomboid B42. Server admins place bus stops anywhere on the map; players walk up to a stop, pick a destination, pay the fare, and are teleported there with a cinematic fade transition.

---

## Features

- Admin-placed bus stops at any coordinate
- Per-stop price configuration (Free, Fixed, or Dynamic by distance)
- Configurable currency (any item type via Sandbox Options)
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
3. The travel panel opens showing all available destinations and their fares
4. Click a destination to travel — the screen fades to black, you are teleported, and the screen fades back in
5. If the destination stop has **Return Trip** enabled, a return button appears at the top of the panel on your next use

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
| **Currency Item** | `Base.Money` | The item type players pay with (any valid item type string) |
| **Base Price** | `1` | Minimum fare applied to every trip |
| **Price Per Tile** | `1` | Extra cost per tile of distance (divided by 1000, used in Dynamic pricing) |

### Dynamic Price Formula

```
price = ceil((BasePrice + distance_in_tiles * (PricePerTile / 1000)) * stop_multiplier)
```

---

## Multiplayer

- Fully server-authoritative: all travel requests are validated server-side
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
| Version | 1.0 |
| Build | 42+ |
| Multiplayer | Yes |
| Added mid-game | Yes |
