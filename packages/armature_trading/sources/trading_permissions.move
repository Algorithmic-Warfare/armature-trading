/// The permission bits each armature_trading payload type needs, for the
/// config that enables it: a `ProposalTypeInit` override at OU creation, or the
/// config in an `EnableProposalType` / `EnableBypassType` payload. A type
/// enabled without them aborts with `proposal::EPermissionDenied` when its
/// handler runs.
///
/// No type borrows from the CapabilityVault (the TradingAccount caps live in
/// `trading_custody`), so every borrow scope is empty.
module armature_trading::trading_permissions {
    use armature::permissions;

    /// DepositCoinToBook<T>: withdraws from the treasury.
    public fun deposit_coin_to_book(): u64 { permissions::treasury_withdraw() }

    /// SetupTradingAccount, DepositFromOuVaultToBook, PlaceLimitOrder<Q>,
    /// PlaceMarketOrder<Q>, CancelOrder<Q>, SweepCoinToTreasury<T>,
    /// SweepMulticoinToOuVault: call no framework mutator, so no bits.
    public fun no_bits(): u64 { 0 }
}
