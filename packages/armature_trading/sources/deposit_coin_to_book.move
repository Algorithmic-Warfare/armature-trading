/// Payload: move `amount` of coin `T` from the OU treasury into the OU's
/// TradingAccount (the exchange-side balance), ready to back bids.
module armature_trading::deposit_coin_to_book {
    use std::internal::{Self, Permit};

    public struct DepositCoinToBook<phantom T> has drop, store {
        trading_account_id: ID,
        amount: u64,
    }

    public fun new<T>(trading_account_id: ID, amount: u64): DepositCoinToBook<T> {
        DepositCoinToBook { trading_account_id, amount }
    }

    public fun trading_account_id<T>(self: &DepositCoinToBook<T>): ID { self.trading_account_id }

    public fun amount<T>(self: &DepositCoinToBook<T>): u64 { self.amount }

    public(package) fun permit<T>(): Permit<DepositCoinToBook<T>> { internal::permit() }
}
