# armature-trading

Optional Move package that lets an Armature OU trade on the Trinary Exchange (`triex`) order book. Every trading operation executes through the `ExecutionTicket<P>` proposal pipeline from `armature_framework`, so each type works standalone, inside a composite proposal, or via `ExternalExecutionCap`, with no changes to the framework.

## Architecture

This package is a pure extension: it adds payload types, handlers, and a custody object. All governance, voting, and execution stay in `armature_framework`.

```
armature_framework (ExecutionTicket<P>, OU, TreasuryVault)   armature_vault (OuReceiptVault)
                     ↑                                                ↑
        armature_trading (payload types + handlers + TradingCustody)
                     ↓
        triex (MultiCoinPool, TradingAccount, FeePolicy)
```

The OU's triex `TradingAccount` is owned by a shared `TradingCustody` object. `SetupTradingAccount` creates the custody and calls triex's `new_with_uid_owner_and_caps` (TRIEX-158) with the custody's UID, which returns the account's caps; the custody stores them in the same transaction. The caps stay in the custody, usable only by this package's handlers; they are not in the `CapabilityVault`, so no type needs `VAULT_BORROW` or a borrow scope.

## Dependencies (testnet_stillness, cycle 7)

| Dep | Source | Rev |
|-----|--------|-----|
| `armature` | loash-industries/armature `packages/armature_framework` | `ae60685` |
| `armature_vault` | Algorithmic-Warfare/armature-vault | `3e80649` |
| `triex` | loash-industries/trinary-exchange `packages/triex` (`main`, published `0xdbf259ed…`) | `bdcdaed` |
| `multicoin` | Algorithmic-Warfare/multicoin | `2772c26` |

`multicoin` (and `armature`) carry `override = true` so the `multicoin::Balance` in `OuReceiptVault` and in `TradingAccount` is the same type.

`armature_trading` itself is not yet published for cycle 7: it has no `Published.toml` or `Move.lock`, and will be published fresh to `testnet_stillness`.

## Proposal Types

See [docs/proposal-types.md](../docs/proposal-types.md) for the full list with descriptions.

| Type | What it does |
|------|-------------|
| `SetupTradingAccount` | Creates a `TradingCustody` and a `TradingAccount` it owns |
| `DepositCoinToBook<T>` | Moves `Coin<T>` from treasury → `TradingAccount` |
| `DepositFromOuVaultToBook` | Moves a multicoin asset from an `OuReceiptVault` → `TradingAccount` |
| `PlaceLimitOrder<QuoteAsset>` | Places a limit order on a `MultiCoinPool` |
| `PlaceMarketOrder<QuoteAsset>` | Places a market order on a `MultiCoinPool` |
| `CancelOrder<QuoteAsset>` | Cancels a resting order on a `MultiCoinPool` |
| `CreateMulticoinPool<QuoteAsset>` | Creates a permissionless `MultiCoinPool`, paying the CRED fee from treasury |
| `PlaceLimitOrderCoin<BaseAsset, QuoteAsset>` | Places a limit order on a coin `Pool<BaseAsset, QuoteAsset>` |
| `CancelOrderCoin<BaseAsset, QuoteAsset>` | Cancels a resting order on a coin `Pool<BaseAsset, QuoteAsset>` |
| `SweepCoinToTreasury<T>` | Moves `Coin<T>` from `TradingAccount` → treasury |
| `SweepMulticoinToOuVault` | Moves a multicoin asset from `TradingAccount` → `OuReceiptVault` |

## Trade Lifecycle

**Selling items (ask):** `DepositFromOuVaultToBook` → `PlaceLimitOrder(is_bid=false)` → *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepCoinToTreasury`

**Buying items (bid):** `DepositCoinToBook` → `PlaceLimitOrder(is_bid=true)` → *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepMulticoinToOuVault`

`withdraw_settled_amounts_permissionless` is callable by anyone (no cap, no governance). A bot or OU member moves settled fills into the `TradingAccount` before sweeping.

## Modules

- `trading_ops`: the `execute_*` handlers for all proposal types
- `trading_custody`: `TradingCustody` and cap access limited to this package
- `trading_permissions`: permission bits for each type's enabling config
- One payload module per proposal type (11 modules)
