/// Payload: open a triex TradingAccount for the OU, held by a new
/// `TradingCustody` (see `trading_custody`). Empty payload: the OU is
/// identified by the ExecutionTicket, not the payload.
module armature_trading::setup_trading_account {
    use std::internal::{Self, Permit};

    public struct SetupTradingAccount has drop, store {}

    public fun new(): SetupTradingAccount { SetupTradingAccount {} }

    public(package) fun permit(): Permit<SetupTradingAccount> { internal::permit() }
}
