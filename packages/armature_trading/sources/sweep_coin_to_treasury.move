/// Payload: withdraw `amount` of coin `T` from the OU's TradingAccount back
/// into the OU treasury (e.g. quote proceeds after an ask fills).
module armature_trading::sweep_coin_to_treasury {
    use std::internal::{Self, Permit};

    public struct SweepCoinToTreasury<phantom T> has drop, store {
        trading_account_id: ID,
        amount: u64,
    }

    public fun new<T>(trading_account_id: ID, amount: u64): SweepCoinToTreasury<T> {
        SweepCoinToTreasury { trading_account_id, amount }
    }

    public fun trading_account_id<T>(self: &SweepCoinToTreasury<T>): ID { self.trading_account_id }

    public fun amount<T>(self: &SweepCoinToTreasury<T>): u64 { self.amount }

    public(package) fun permit<T>(): Permit<SweepCoinToTreasury<T>> { internal::permit() }
}
