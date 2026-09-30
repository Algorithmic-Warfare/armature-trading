# Changelog

## 2026-09-30

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
