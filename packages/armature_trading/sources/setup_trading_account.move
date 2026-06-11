/// Payload: create a BalanceManager owned by the DAO and store its
/// DepositCap / WithdrawCap / TradeCap in the DAO's CapabilityVault.
/// Empty payload — the DAO is identified by the ExecutionRequest, not the payload.
module armature_trading::setup_trading_account {
    public struct SetupTradingAccount has drop, store {}

    public fun new(): SetupTradingAccount { SetupTradingAccount {} }
}
