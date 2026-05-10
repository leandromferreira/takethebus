# BusStop Economy Integration Guide

This guide is intended for **bank mod authors** who want their mod to natively support BusStop Fast Travel as a payment backend.

---

## How it works

BusStop calls your mod through a Lua global API table that you expose. Your mod stays in full control of how balances are stored and managed — BusStop never touches your internal data directly.

When a player travels, BusStop:
1. Deducts available inventory items first (if *Pay with Items* is enabled on the server)
2. Calls your API's `canAfford` with the **remaining amount** (may be the full fare if items are disabled or insufficient)
3. If affordable, calls `deduct` for that remaining amount

```
┌──────────────┐   canAfford(player, remaining)   ┌──────────────┐
│   BusStop    │ ───────────────────────────────►  │  Your Mod    │
│   (server)   │   deduct(player, remaining)        │  .API table  │
│              │ ───────────────────────────────►  │              │
│              │   formatLabel(price)               │              │
│              │ ───────────────────────────────►  │              │
└──────────────┘                                    └──────────────┘
```

---

## Adding the API to your mod

### Where to put the code

Create (or edit) a file inside your mod's server Lua folder:

```
mods/
└── MyBankMod/
    └── media/
        └── lua/
            └── server/
                └── MyBankMod_BusStopAPI.lua   ← new file (name is up to you)
```

This file is loaded automatically by PZ on the server — no `require`, no `mod.info` changes needed.

### What to write

In that file, expose a global table with an `.API` sub-table:

```lua
-- Inside your bank mod's server Lua file

MyBankMod = MyBankMod or {}

MyBankMod.API = {

    -- Returns true if the player can afford `amount`.
    -- amount = remaining fare after items were already deducted.
    -- On failure returns: false, errMsgKey, { label, needed, have }
    -- errMsgKey maps to: "Not enough %1. Need %2, have %3."
    canAfford = function(player, amount)
        local balance = MyBankMod.getBalance(player)
        if balance >= amount then return true end
        return false, "err_no_currency", { "MyBank", tostring(amount), tostring(balance) }
    end,

    -- Deducts `amount` from the player's balance.
    -- Only called after canAfford returned true.
    deduct = function(player, amount)
        MyBankMod.setBalance(player, MyBankMod.getBalance(player) - amount)
    end,

    -- Returns a formatted price string shown in the travel UI.
    -- Only used when Pay with Items is disabled (bank-only mode).
    formatLabel = function(amount)
        if amount <= 0 then return "Free" end
        return "$" .. tostring(amount)
    end,
}
```

That's all. No dependency on BusStop, no `require`, no events. If BusStop is not installed the table just sits unused.

---

## Server configuration

Once your mod exposes the API, the server admin enables the integration via sandbox options:

| Option | Value |
|---|---|
| `BusStop.UseBankPayment` | `true` |
| `BusStop.BankModGlobal` | The exact name of your Lua global (e.g. `MyBankMod`) |
| `BusStop.UseItemPayment` | `true` to use items first, `false` for bank-only |

### Payment combinations

| UseItemPayment | UseBankPayment | Behaviour |
|---|---|---|
| ✓ | — | Items only (default) |
| — | ✓ | Bank only |
| ✓ | ✓ | Items first; bank covers the remainder |
| — | — | Falls back to item-only (safe default) |

---

## Survivor Shop — bridge workaround

Survivor Shop does not natively expose a `.API` table. If you are running a server with both mods and want them to work together **without modifying Survivor Shop's files**, you can create a small bridge script inside your server's `Lua/` scripts folder (not inside either mod):

```lua
-- File: <server>/Lua/SurvivorShopBusBridge.lua
-- This is a server-side workaround. The ideal solution is for Survivor Shop
-- to add MyBankMod.API natively to its own mod files.

SurvivorShopBus = SurvivorShopBus or {}

SurvivorShopBus.API = {

    canAfford = function(player, amount)
        if not SurvivorShop then
            return false, "err_no_currency", { "SS Bank", tostring(amount), "0" }
        end
        local key = SurvivorShop.getAccountKey(player)
        local md  = ModData.getOrCreate("SurvivorShop_Balances")
        local bal = (md.balances and tonumber(md.balances[key])) or 0
        if bal >= amount then return true end
        return false, "err_no_currency", { "SS Bank", tostring(amount), tostring(bal) }
    end,

    deduct = function(player, amount)
        if not SurvivorShop then return end
        local key = SurvivorShop.getAccountKey(player)
        local md  = ModData.getOrCreate("SurvivorShop_Balances")
        if not md.balances then md.balances = {} end
        local bal = tonumber(md.balances[key]) or 0
        md.balances[key] = math.max(0, bal - amount)
    end,

    formatLabel = function(amount)
        if amount <= 0 then return "Free" end
        return "$" .. string.format("%.2f", amount)
    end,
}
```

Set `BusStop.BankModGlobal = SurvivorShopBus` in sandbox options.

---

## Fail-safe behaviour

| Condition | Result |
|---|---|
| Both options disabled | Falls back to item-only — no crash |
| `UseBankPayment = true`, `BankModGlobal` empty | Travel blocked, error logged |
| Global set but mod not loaded | Same — global not found |
| Global found but `.API` fields missing | Same — integration incomplete |

All failures are logged with the `[BusStop][ECON]` prefix on the server console. No crash, no silent money loss.

---

## Logging reference

```
[BusStop][ECON] getAPI: 'MyBankMod'.API OK
[BusStop][PRICE] canAfford: price=5 useItem=true have=3 useBank=true
[BusStop][PRICE] deductCurrency: removed 3x Base.Money
[BusStop][PRICE] deductCurrency: deducted 2 from bank
```

---

## Integration checklist (for mod authors)

- [ ] Add `MyBankMod.API` with `canAfford`, `deduct`, `formatLabel` to a server-side Lua file in your mod
- [ ] Document the global name (e.g. `MyBankMod`) so server admins know what to put in `BankModGlobal`
- [ ] Verify `canAfford` handles `amount = 0` gracefully (should return `true`)
- [ ] Verify `deduct` never sets balance below zero
- [ ] Test with `UseBankPayment = true` and `UseItemPayment = false` (bank-only)
- [ ] Test with both enabled: player has fewer items than the fare — items go first, bank covers the rest
