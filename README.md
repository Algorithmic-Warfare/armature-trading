# armature-trading

`armature_trading` is a standalone, optional Move package that lets an Armature
OU trade on the [Trinary Exchange](https://trinary.exchange) order book
(`triex`). Every trading operation (setup, deposit, place/cancel order, sweep)
runs through the `ExecutionTicket<P>` proposal pipeline in `armature_framework`.
Each one works on its own, inside a composite proposal, or through an
`ExternalExecutionCap`, with no changes to the framework.

## Target environment: `testnet_stillness` (cycle 7)

| Dep | Source | Rev |
|-----|--------|-----|
| `armature` (framework) | loash-industries/armature `packages/armature_framework` | `ae60685` |
| `armature_vault` | Algorithmic-Warfare/armature-vault `packages/armature_vault` | `3e80649` |
| `triex` | loash-industries/trinary-exchange `packages/triex` (`main`, published `0xdbf259ed…`) | `bdcdaed` |
| `multicoin` | Algorithmic-Warfare/multicoin `packages/multicoin` | `2772c26` |

triex and armature_vault both pin multicoin at `2772c26`. The `override = true`
on multicoin (and on armature, which armature_vault also pins) unifies them, so
the `OuReceiptVault`'s `multicoin::Balance` and the `TradingAccount`'s are the
same type.

## How an OU holds a TradingAccount

A triex `TradingAccount` has a fixed `owner` address, and only the owner may
mint caps. An OU cannot sign as any address, so the account is owned by a
shared `TradingCustody` object. **`SetupTradingAccount`** (governance) creates
the custody and calls triex's `new_with_uid_owner_and_caps` (TRIEX-158) with
the custody's UID. triex returns the Deposit, Withdraw and Trade caps, and they
are stored in the custody in the same transaction. The account can trade as
soon as setup commits.

The caps never leave the custody. Only this package can borrow them, and every
handler checks that the custody belongs to the OU that approved the ticket.
Because nobody can sign as the custody's address, the owner-only triex functions
(`withdraw`, `mint_*_cap`, `revoke_trade_cap`, `register_trading_account`) are
never callable on the account.

An OU can run `SetupTradingAccount` more than once. Each run makes a separate
custody and account, and payloads name the account by ID.

## Modules

- `trading_ops`: the eight `execute_*` handlers.
- `trading_custody`: the `TradingCustody` object and cap access
  limited to this package.
- `trading_permissions`: the permission bits each type needs in its enabling
  config.
- One payload module per type: `setup_trading_account`, `deposit_coin_to_book`,
  `deposit_from_ou_vault_to_book`, `place_limit_order`, `place_market_order`,
  `cancel_order`, `sweep_coin_to_treasury`, `sweep_multicoin_to_ou_vault`.

See [docs/proposal-types.md](docs/proposal-types.md) for each type.

## Trade lifecycle

The framework's `TreasuryVault` holds only coins, so multicoin items move
between an armature_vault `OuReceiptVault` and the book.

**Selling items (ask):** `DepositFromOuVaultToBook` → `PlaceLimitOrder(is_bid=false)`
→ *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepCoinToTreasury`.

**Buying items (bid):** `DepositCoinToBook` → `PlaceLimitOrder(is_bid=true)`
→ *(fill)* → `withdraw_settled_amounts_permissionless` → `SweepMulticoinToOuVault`.

Anyone can call `multicoin_pool::withdraw_settled_amounts_permissionless` (no
cap, no governance). A bot or an OU member runs it to move settled fills into
the TradingAccount before a sweep.

## Enabling the types

Enable each type on the OU with `EnableProposalType` (or a `ProposalTypeInit`
override at OU creation). Take the permission bits from `trading_permissions`:
`DepositCoinToBook<T>` needs `TREASURY_WITHDRAW`, and the others need none. No
type borrows from the `CapabilityVault`, so every borrow scope stays empty.

The two `OuReceiptVault` handlers also need the executor to satisfy the vault's
ACL: its `Withdraw` role for `DepositFromOuVaultToBook` and its `Deposit` role
for `SweepMulticoinToOuVault`. With an `Ou { ou_id }` principal, that means the
executor is a board member of the ticket's OU.

## Build & test

```bash
cd packages/armature_trading
sui move build -e testnet_stillness
# triex exceeds the default 10 MB test arena; needs sui >= 1.81
sui move test -e testnet_stillness --package-size 16
```

The tests cover setup and the deposit and sweep handlers. The order handlers
(`PlaceLimitOrder`, `PlaceMarketOrder`, `CancelOrder`) are only type-checked:
testing them needs a registered `MultiCoinPool` and `FeePolicy`.

## Publishing for cycle 7

This is a breaking change from the published `testnet_stillness` package: the
dependencies, payload fields and handler signatures all differ. It needs a
fresh publish, not an upgrade. The package has no publish record (no
`Published.toml` or `Move.lock`); publishing to `testnet_stillness` creates
both. Publish after triex, armature and armature_vault are published for the
cycle.

## Open items

- **Custody migration.** A custody is tied to one OU for good. Moving an
  account to a migrated OU would need a new governance type.
- **Coin-pair pools.** Only `MultiCoinPool` is wired. Coin-pair `Pool` order
  types are not implemented.
