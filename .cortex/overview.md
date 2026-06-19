# armature-trading

Optional Move package that wires an Armature DAO's `TreasuryVault` to the TriexBook DEX. Every trading operation executes through the unified `ExecutionTicket<P>` proposal pipeline from `armature_framework`, making each type usable standalone, inside a `CompositeFrame`, or via `ExternalExecutionCap` with no changes to the framework.

## Architecture

This package is a pure extension — it adds proposal payload types and handlers; all governance, voting, and execution infrastructure remains in `armature_framework`.

```
armature_framework (ExecutionTicket<P>, TreasuryVault, CapabilityVault)
    ↑
armature_trading (proposal handlers + payload types)
    ↓
TriexBook (Pool, MultiCoinPool, BalanceManager)
```

## Dependencies

| Dep | Source |
|-----|--------|
| `armature_framework` | loash-industries/armature |
| `triexbook` | loash-industries/triex-book |
| `multicoin` | Algorithmic-Warfare/multicoin |

Both `armature_framework` and `triexbook` depend on `multicoin` at the same revision, requiring `override = true` in `Move.toml` to unify the package ID and make `MultiCoinBalance` the same type on both sides.

## Proposal Types

See [docs/proposal-types.md](../docs/proposal-types.md) for the full list with descriptions.

| Type | What it does |
|------|-------------|
| `SetupTradingAccount` | Creates a DAO-owned `BalanceManager` and stores its caps in the vault |
| `DepositCoinToBook<T>` | Moves `Coin<T>` from treasury → `BalanceManager` |
| `DepositMulticoinToBook` | Moves multicoin asset from treasury → `BalanceManager` |
| `PlaceLimitOrder<QuoteAsset>` | Places a limit order on a `MultiCoinPool` |
| `PlaceLimitOrderCoin<BaseAsset, QuoteAsset>` | Places a limit order on a coin-pair `Pool` |
| `CancelOrder<QuoteAsset>` | Cancels a resting order on a `MultiCoinPool` |
| `CancelOrderCoin<BaseAsset, QuoteAsset>` | Cancels a resting order on a coin-pair `Pool` |
| `CreateMulticoinPool<QuoteAsset>` | Creates a permissionless `MultiCoinPool` |
| `SweepCoinToTreasury<T>` | Moves `Coin<T>` from `BalanceManager` → treasury |
| `SweepMulticoinToTreasury` | Moves multicoin asset from `BalanceManager` → treasury |

## Trade Lifecycle

**Selling items (ask):** `DepositMulticoinToBook` → `PlaceLimitOrder(is_bid=false)` → *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepCoinToTreasury`

**Buying items (bid):** `DepositCoinToBook` → `PlaceLimitOrder(is_bid=true)` → *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepMulticoinToTreasury`

`withdraw_settled_amounts_permissionless` is callable by anyone (no cap, no governance) — a bot or the DAO pushes settled fills into the BalanceManager before sweeping.

## Modules

- `trading_ops` — central dispatcher with the `execute_*` handlers for all proposal types
- One payload module per proposal type (10 modules)
