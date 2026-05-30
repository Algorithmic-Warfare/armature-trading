/// Payload: move `amount` of coin `T` from the DAO treasury into the
/// BalanceManager (the DEX-side balance), ready to back bids.
module armature_trading::deposit_coin_to_book;

public struct DepositCoinToBook<phantom T> has drop, store {
    amount: u64,
}

public fun new<T>(amount: u64): DepositCoinToBook<T> {
    DepositCoinToBook { amount }
}

public fun amount<T>(self: &DepositCoinToBook<T>): u64 { self.amount }
