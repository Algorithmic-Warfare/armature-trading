# Changelog

## 2026-09-30

- Published `armature_trading` to `testnet_stillness` (cycle 7): package `0xe7060901772310333cfe7ca055ce5bb06a067e4209b5db3fe684ac3e6b2a0fce`, UpgradeCap `0x6aa743ed7c609b129190d0e7282744b7d3bb1e252cc8c610ba3608ea2c8b3e60`, digest `AP7dG6VH52GnqrydYiNUkLPy4EXQCSws9YnW1Px6CQ5m`. Only `Published.toml` changed.

- Port the coin-trading proposals from `feat/coin-trading` onto the cycle-7 custody model, against triex main (`bdcdaed`):
  - `PlaceLimitOrderCoin<B, Q>` and `CancelOrderCoin<B, Q>` trade on triex coin `Pool<Base, Quote>` through the OU's `TradingAccount` (no permission bits).
  - `CreateMulticoinPool<Q>` creates a permissionless `MultiCoinPool<Q>`, paying the 500 CRED fee from the OU treasury (`TREASURY_WITHDRAW`; `trading_permissions::create_multicoin_pool`).
  - Added a direct `token` dependency (trinary-exchange `packages/token` at `bdcdaed`) for `CRED`, and a new `EWrongCollection` (6) abort.
  - Added `coin_trading_tests`, including `submit_vote_execute` runs.

- Align with armature main and trinary-exchange main: re-pin `triex` to `bdcdaed` (live `testnet_stillness` publish `0xdbf259ed…`).
- `TradingCustody` now creates the account with triex's `new_with_uid_owner_and_caps` (TRIEX-158) and stores the caps in the setup transaction. Removed `claim_caps`, `caps_claimed` and `ECapsNotClaimed`; updated tests and docs.
- Cleared the publish record (`Published.toml`, `Move.lock`) for a from-scratch redeploy.

- Port `armature_trading` to cycle 7 (`testnet_stillness`). Depends on `triex` (trinary-exchange `packages/triex`), `armature_vault` and `armature` at their cycle-7 revs, and on multicoin 2772c26.
- New modules:
  - `trading_custody`: a `TradingCustody` object owns the OU's `TradingAccount`; its caps are stored by `claim_caps`.
  - `trading_permissions`.
  - `place_market_order`.
  - `deposit_from_ou_vault_to_book` and `sweep_multicoin_to_ou_vault`, which replace `deposit_multicoin_to_book` and `sweep_multicoin_to_treasury`.
- Reworked `trading_ops`, `setup_trading_account`, the order handlers, and coin deposit/sweep for the `trading_account` API.
- Added custody and ops tests.
- Cleared the `testnet_wip` publish record. The package is not yet published for cycle 7.

## 2026-06-19

- Initial Cortex onboarding: created `.cortex/manifest.yaml`, `overview.md`, `changelog.md`, and `docs/proposal-types.md`
