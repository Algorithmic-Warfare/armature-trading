# Trading Proposal Types

`armature-trading` adds order-book trading proposal types to any Armature OU. Each type trades on [Trinary Exchange](https://trinary.exchange) (`triex`) through a `TradingAccount` held by the OU's `TradingCustody`, and moves funds between that account and the OU's `TreasuryVault` (coins) or an armature_vault `OuReceiptVault` (multicoin items).

All types follow the `ExecutionTicket<P>` hot-potato pattern from `armature_framework`. Each handler reads `ticket.ticket_payload()`, checks every object it is passed against the payload and the ticket's OU, and closes the ticket with `ticket.discharge(permit)`. That makes each type usable inside composite proposals and through an `ExternalExecutionCap`.

Every payload except `SetupTradingAccount` and `CreateMulticoinPool` names its `trading_account_id`. The handler aborts unless the passed `TradingAccount` has that ID and the passed `TradingCustody` holds it for the ticket's OU.

---

## Account Setup

### `SetupTradingAccount`
Create a shared `TradingCustody` for the ticket's OU and a shared `TradingAccount` owned by the custody's address. triex's `new_with_uid_owner_and_caps` returns the account's `DepositCap`, `WithdrawCap` and `TradeCap`, and the custody stores them in the same transaction, so the other types can run as soon as setup commits. Empty payload: the OU comes from the ticket. Permission bits: none.

An OU may run this more than once to hold several accounts.

---

## Deposits

### `DepositCoinToBook<T>`
Move `amount` of `Coin<T>` from the OU treasury into the `TradingAccount`, to back bids. Permission bits: `TREASURY_WITHDRAW`.

### `DepositFromOuVaultToBook`
Move `amount` of multicoin asset `asset_id` from the `OuReceiptVault` named by `vault_id` into the `TradingAccount`, to back asks. The `&OU` passed must be the ticket's OU, and the executor must satisfy the vault's `Withdraw` role. Permission bits: none.

---

## Pool Creation

### `CreateMulticoinPool<QuoteAsset>`
Create a permissionless triex `MultiCoinPool<QuoteAsset>` for multicoin asset `asset_id` in the `Collection` named by `collection_id`, paying the 500 CRED creation fee (`constants::pool_creation_fee()`) from the OU treasury. `QuoteAsset` must be registry-approved and bootstrapped in the `FeePolicy`. triex shares the pool and emits `MultiCoinPoolCreated` with its ID. Permission bits: `TREASURY_WITHDRAW`.

---

## Orders

### `PlaceLimitOrder<QuoteAsset>`
Place a limit order on the triex `MultiCoinPool<QuoteAsset>` named by `pool_id`. The base is a multicoin asset and the quote is `Coin<QuoteAsset>`; `quantity` is in base units. `is_bid = true` buys items; `is_bid = false` sells them. Fees are quote-denominated and follow the shared `FeePolicy`. Permission bits: none.

### `PlaceMarketOrder<QuoteAsset>`
Place an immediate-or-cancel market order on the named `MultiCoinPool<QuoteAsset>`. Same fields as `PlaceLimitOrder` without price, order type or expiry. Permission bits: none.

### `CancelOrder<QuoteAsset>`
Cancel resting order `order_id` (`u128`) on the named `MultiCoinPool<QuoteAsset>`. Unlocked funds settle back into the `TradingAccount`. Permission bits: none.

### `PlaceLimitOrderCoin<BaseAsset, QuoteAsset>`
Place a limit order on the triex coin `Pool<BaseAsset, QuoteAsset>` named by `pool_id`. Both sides are `Coin<T>` types; `quantity` is in base units. `is_bid = true` buys base; `is_bid = false` sells it. Same fields as `PlaceLimitOrder`. Permission bits: none.

### `CancelOrderCoin<BaseAsset, QuoteAsset>`
Cancel resting order `order_id` (`u128`) on the named coin `Pool<BaseAsset, QuoteAsset>`. Unlocked funds settle back into the `TradingAccount`. Unlike the multicoin cancel, the handler takes no `FeePolicy`. Permission bits: none.

---

## Sweeps (book → OU)

### `SweepCoinToTreasury<T>`
Withdraw `amount` of `Coin<T>` from the `TradingAccount` into the OU treasury, for example quote proceeds after an ask fills. The treasury must belong to the ticket's OU. Permission bits: none.

### `SweepMulticoinToOuVault`
Withdraw `amount` of multicoin asset (`collection_id`, `asset_id`) from the `TradingAccount` into the `OuReceiptVault` named by `vault_id`, for example items received after a bid fills. The `&OU` passed must be the ticket's OU, and the executor must satisfy the vault's `Deposit` role. Permission bits: none.

Before a sweep, `multicoin_pool::withdraw_settled_amounts_permissionless` must move settled fills from the pool into the `TradingAccount`. Anyone can call it without governance (typically a bot or an OU member). It is not a proposal type.

---

## Trade Lifecycle

**Selling items (ask):** `DepositFromOuVaultToBook` → `PlaceLimitOrder<QuoteAsset>` (`is_bid = false`) → *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepCoinToTreasury<QuoteAsset>`.

**Buying items (bid):** `DepositCoinToBook<QuoteAsset>` → `PlaceLimitOrder<QuoteAsset>` (`is_bid = true`) → *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepMulticoinToOuVault`.

**Trading a coin pair:** `DepositCoinToBook<QuoteAsset>` (bid) or `DepositCoinToBook<BaseAsset>` (ask) → `PlaceLimitOrderCoin<BaseAsset, QuoteAsset>` → *(fill)* → `pool::withdraw_settled_amounts_permissionless` → `SweepCoinToTreasury<BaseAsset>` or `SweepCoinToTreasury<QuoteAsset>`.
