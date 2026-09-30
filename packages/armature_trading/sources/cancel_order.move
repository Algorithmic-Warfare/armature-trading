/// Payload: cancel a resting order on a triex MultiCoinPool<QuoteAsset>.
/// Unlocked funds settle back into the OU's TradingAccount.
module armature_trading::cancel_order {
    use std::internal::{Self, Permit};

    public struct CancelOrder<phantom QuoteAsset> has drop, store {
        trading_account_id: ID,
        pool_id: ID,
        order_id: u128,
    }

    public fun new<QuoteAsset>(
        trading_account_id: ID,
        pool_id: ID,
        order_id: u128,
    ): CancelOrder<QuoteAsset> {
        CancelOrder { trading_account_id, pool_id, order_id }
    }

    public fun trading_account_id<Q>(self: &CancelOrder<Q>): ID { self.trading_account_id }

    public fun pool_id<Q>(self: &CancelOrder<Q>): ID { self.pool_id }

    public fun order_id<Q>(self: &CancelOrder<Q>): u128 { self.order_id }

    public(package) fun permit<Q>(): Permit<CancelOrder<Q>> { internal::permit() }
}
