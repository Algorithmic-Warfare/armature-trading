# Trading Proposal Types

`armature-trading` adds DEX trading proposal types to any Armature DAO. Each type integrates with [TriexBook](https://trinary.exchange) order books and routes through the DAO's `BalanceManager` and `TreasuryVault`.

All types follow the `ExecutionTicket<P>` hot-potato pattern from `armature_framework`: each handler reads `ticket.ticket_payload()` and ends with `ticket.discharge()`, making them composable inside `CompositeFrame` proposals and usable via `ExternalExecutionCap`.

---

## Account Setup

### `SetupTradingAccount`
Create a `BalanceManager` owned by the DAO and store the resulting `DepositCap`, `WithdrawCap`, and `TradeCap` in the DAO's `CapabilityVault`. Empty payload — the DAO is identified by the `ExecutionRequest`. This must be executed before any other trading proposals can run.

---

## Deposits

### `DepositCoinToBook<T>`
Move `amount` of `Coin<T>` from the DAO treasury into the `BalanceManager` (the DEX-side balance), making it available to back bids or fill orders.

### `DepositMulticoinToBook`
Move a multicoin asset (identified by `collection_id` / `asset_id`) from the DAO treasury into the `BalanceManager`, making it available to back asks.

---

## Order Placement

### `PlaceLimitOrder<QuoteAsset>`
Place a limit order on a TriexBook `MultiCoinPool<QuoteAsset>`. Used for pools where the base is a non-fungible or multicoin collection asset and the quote is a `Coin<QuoteAsset>`. `is_bid = true` buys items; `is_bid = false` sells items.

### `PlaceLimitOrderCoin<BaseAsset, QuoteAsset>`
Place a limit order on a TriexBook `Pool<BaseAsset, QuoteAsset>` where both sides are standard `Coin<T>` types. `is_bid = true` buys `BaseAsset`; `is_bid = false` sells `BaseAsset`.

---

## Order Cancellation

### `CancelOrder<QuoteAsset>`
Cancel a resting order on a TriexBook `MultiCoinPool<QuoteAsset>`. Unlocked funds settle back into the `BalanceManager`.

### `CancelOrderCoin<BaseAsset, QuoteAsset>`
Cancel a resting order on a TriexBook `Pool<BaseAsset, QuoteAsset>`. Unlocked funds settle back into the `BalanceManager`.

---

## Pool Management

### `CreateMulticoinPool<QuoteAsset>`
Create a permissionless `MultiCoinPool<QuoteAsset>` for a given collection/asset pair, paying the creation fee from the DAO treasury.

---

## Sweeps (DEX → Treasury)

### `SweepCoinToTreasury<T>`
Withdraw `amount` of `Coin<T>` from the `BalanceManager` back into the DAO treasury. Typical use: sweeping quote proceeds (e.g. SUI) after a sell order fills.

### `SweepMulticoinToTreasury`
Withdraw a multicoin asset from the `BalanceManager` back into the DAO treasury. Typical use: collecting items received after a bid fills.

Before sweeping, `withdraw_settled_amounts_permissionless` must push settled fills from the order book into the `BalanceManager`. This function is callable by anyone without governance (typically a bot or the DAO itself) and is not a proposal type.

---

## Trade Lifecycle

A complete trade cycle follows a predictable pattern.

**Selling items (ask):** deposit the multicoin asset via `DepositMulticoinToBook` → place a limit order with `PlaceLimitOrder<QuoteAsset>` (`is_bid = false`) → wait for the order to fill → call `withdraw_settled_amounts_permissionless` to push proceeds into the `BalanceManager` → sweep quote currency back to treasury via `SweepCoinToTreasury`.

**Buying items (bid):** deposit fungible quote currency via `DepositCoinToBook<T>` → place a limit order with `PlaceLimitOrder<QuoteAsset>` (`is_bid = true`) → wait for the order to fill → call `withdraw_settled_amounts_permissionless` to push received items into the `BalanceManager` → sweep items back to treasury via `SweepMulticoinToTreasury`.
