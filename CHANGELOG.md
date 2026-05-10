# Changelog

## [Unreleased]

### Added

#### Economy Integration
- New **generic bank mod API**: bank mods expose `MyMod.API = { canAfford, deduct, formatLabel }` as a Lua global; BusStop resolves it via `_G[BankModGlobal].API`
- New sandbox options: **Pay with Items** (boolean, default on) and **Pay with Bank** (boolean, default off)
- **Split payment**: when both sources are active, items are deducted first; the bank covers any remaining shortfall
- New sandbox option: **Bank Mod Global** — name of the Lua global the bank mod exposes its API under
- `BusStopEconomy.lua` (shared): `getAPI()` resolves and validates the external bank API; `formatLabel()` formats prices for the active payment mode
- `INTEGRATION.md` and `INTEGRATION.bbcode`: guides for bank mod authors explaining how to expose the API, a Survivor Shop bridge workaround, fail-safe behaviour, and a checklist

#### Player Travel UI
- **Search bar** above the destination list — filters stops by name in real time
- **Scrollable destination list** (`ISScrollingListBox`) replaces fixed-height buttons — handles any number of stops without overflowing the screen
- **Select-then-confirm** flow: clicking a row highlights it and updates the bottom button; travel only happens when the **"Travel to X"** button is clicked, preventing accidental trips
- Selected destination and price shown in an info line above the travel button
- Panel height adapts dynamically (capped at 50% screen height for the list area)

#### Random Trip
- **"Random Trip" button** at the top of the travel panel — destination is picked server-side (client cannot influence which stop is chosen)
- New sandbox option: **Enable Random Trip** (boolean, default on) — hides the button when disabled
- New sandbox option: **Random Trip Price** (integer, default 0 = free) — flat fare charged regardless of distance
- Server cycles through available stops using a round-robin counter (no dependency on `math.random` or `ZombRand`, which are unavailable server-side in B42)

### Fixed

- **Return trip to disabled stop**: traveling to a stop with Return Trip enabled and then returning failed when the origin stop was disabled. The `available` check now only applies to normal travel; return trips bypass it.
- **Server handler crashes swallowed silently**: `OnClientCommand` dispatcher now wraps each handler in `pcall` and logs errors with `[BusStop] ERROR in handler '...'`, making server-side failures visible.
- **`math.random` nil crash** on random trip: Kahlua's server context does not expose `math.random`. Replaced with a module-level round-robin counter using only basic Lua arithmetic.
- **`ZombRand` nil crash**: `ZombRand` is also unavailable server-side. Same fix as above.
- **Float index crash** (`candidates[1.5]`): `getTimestampMs()` can return a float with fractional part; using `%` on it produced a non-integer table index. Fixed by the counter approach.
- **`isRandom`/`isReturn` boolean comparison**: server now accepts both `true` (boolean) and `"true"` (string) to handle potential Kahlua network serialization differences.
- **Syntax error** (`function arguments expected near 'and'`): Kahlua does not allow `self:method and ...` without `()` — replaced `self:getScrollBarWidth and self:getScrollBarWidth() or 0` with `self.vscroll and self.vscroll.width or 0`.
- **`setEmptyString` crash**: `ISTextEntryBox:setEmptyString()` does not exist in this PZ version; calling it via `pcall` still caused a Java `RuntimeException` that escaped Kahlua's pcall. The call was removed entirely.
- **`getMode()` nil crash** (prior session): a leftover debug print called `BusStopEconomy.getMode()` after that function was removed; replaced with inline sandbox var checks.
- **Kahlua null serialization** (prior session): sending `{returnTrip=nil}` over the network serializes to Java null and crashes the client handler. Fixed by always sending `{cleared=true}` for nil-value payloads.
- **`IsoThumpable.new()` 5-arg crash** (prior session): B42 requires `sq:getCell()` instead of `getCell()` as the first argument.
- **Arrival protection had no effect**: `setZombiesDontAttack` was called client-side, but zombie AI runs on the server and ignores client-only flag changes for non-admin players. Fixed by applying the flag server-side (in `BusStopServer.lua`) with an `OnTick` cleanup after 5 seconds.
- **Arrival protection didn't stop already-targeting zombies**: `setZombiesDontAttack` alone does not interrupt zombies already in attack state. Added `OnZombieUpdate` listener (SafeUserLogin pattern): each frame clears zombie detection via `zombie:spotted(player, false)` and temporarily disables any zombie facing the player via `zombie:setUseless(true)`.
- **Countdown HUD frozen on screen after death**: when the player died during protection, `OnPlayerUpdate` stopped firing, `stopProtection()` was never called, and the HUD remained visible indefinitely — including after respawn. Fixed by adding an `OnPlayerDeath` listener that triggers `stopProtection()` immediately.
- **Listener leak after death**: `OnZombieUpdate` and `OnPlayerUpdate` were left registered after player death with no path to remove themselves. `stopProtection()` now explicitly removes all three listeners (`OnZombieUpdate`, `OnPlayerUpdate`, `OnPlayerDeath`) regardless of how it is triggered.

### Changed

- Sandbox option `PaymentMode` (string enum) replaced by two independent booleans `UseItemPayment` / `UseBankPayment` supporting simultaneous use
- Destination list no longer triggers travel on single click — now requires explicit confirmation via the travel button
- Server-side logging reduced: only errors and key travel events are printed; routine per-frame or per-request noise removed
- `BusStopServer.lua`: all client command handlers are now protected by `pcall` in the dispatcher

