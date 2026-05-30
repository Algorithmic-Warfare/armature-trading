# armature-trading

`armature_trading` — a standalone, optional Move package wiring the Armature DAO
`TreasuryVault` to the [TriexBook](https://github.com/loash-industries/triex-book)
DEX. Every trading operation (setup, deposit, place/cancel order, sweep) executes
through the unified `ExecutionTicket<P>` proposal pipeline in `armature_framework`,
so each one works standalone, inside a composite proposal, or via an
`ExternalExecutionCap` — with no changes to the framework.

## Target environment: `testnet_stillness` only

On `testnet_stillness`, all three dependencies resolve to the **same** multicoin
build (`Algorithmic-Warfare/multicoin` @ `c7a97f2`, matching manifest digests),
so `TreasuryVault`'s `MultiCoinBalance` and TriexBook's are the identical type and
the treasury ⇄ BalanceManager handoff type-checks.

**Do not add `testnet_utopia`** — TriexBook pins a different multicoin commit
there (`281bd7d`), which would make the two `MultiCoinBalance` types incompatible.

## Dependencies (pinned)

| Dep | Source | Rev |
|-----|--------|-----|
| `armature` (framework) | loash-industries/armature `packages/armature_framework` | `main` |
| `triexbook` | loash-industries/triex-book `packages/triexbook` | `7630922` |
| `multicoin` | Algorithmic-Warfare/multicoin `packages/multicoin` | `c7a97f2` |

> `armature_framework`'s multicoin + `ExecutionTicket<P>` foundation lives on
> `main` (commit `5ed3786`), **not** on `feat/composed-proposal-actions`.

## Modules

- `trading_ops` — central dispatcher, the seven `execute_*` handlers.
- `setup_trading_account`, `deposit_coin_to_book`, `deposit_multicoin_to_book`,
  `place_limit_order`, `cancel_order`, `sweep_coin_to_treasury`,
  `sweep_multicoin_to_treasury` — one payload type each.

## Trade lifecycle

**Selling items (ask):** `DepositMulticoinToBook` → `PlaceLimitOrder(is_bid=false)`
→ *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepCoinToTreasury`.

**Buying items (bid):** `DepositCoinToBook` → `PlaceLimitOrder(is_bid=true)`
→ *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepMulticoinToTreasury`.

`withdraw_settled_amounts_permissionless` is callable by anyone (no cap, no
governance) — a bot or the DAO pushes settled fills into the BalanceManager
before sweeping.

## ⚠️ Open items before this is merge-ready

1. **Cap ⇄ BalanceManager assertion (blocker).** TriexBook exposes no public
   getter for a cap's bound `balance_manager_id`, and its `validate_*` fns are
   private. TriexBook still enforces the binding *internally* on every op, so it
   is not exploitable — but handlers can only pre-assert
   `object::id(balance_manager) == payload.balance_manager_id` (done). Decide
   whether to add a public accessor upstream in TriexBook for a stronger guard.
2. **DAO owner address.** `setup_trading_account` derives the BalanceManager
   owner from `req.req_dao_id().to_address()` as a placeholder — confirm the
   canonical DAO address derivation.
3. **Single trading account.** `setup_trading_account` aborts if a `DepositCap`
   already exists, so `ids_for_type<_>()[0]` is unambiguous. Relax if multi-BM
   support is needed.
4. **Published address.** `Move.toml` `[environments] testnet_stillness = "0x0"`
   until first publish.
5. **Tests.** No tests yet — `tests/` is empty.

This is a scaffold generated from the design note
`loash-industries/notes/dao/08_triexbook_trading_integration.md`, with the
external APIs verified against the real TriexBook / multicoin sources. It has not
yet been compiled against a live `sui move build` (requires the network-fetched
git deps). Build on `testnet_stillness` before relying on it.
