/// Payload: cancel a resting order on a triex coin `Pool<BaseAsset, QuoteAsset>`.
/// Unlocked funds settle back into the OU's TradingAccount.
module armature_trading::cancel_order_coin {
    use std::internal::{Self, Permit};

    public struct CancelOrderCoin<phantom BaseAsset, phantom QuoteAsset> has drop, store {
        trading_account_id: ID,
        pool_id: ID,
        order_id: u128,
    }

    public fun new<BaseAsset, QuoteAsset>(
        trading_account_id: ID,
        pool_id: ID,
        order_id: u128,
    ): CancelOrderCoin<BaseAsset, QuoteAsset> {
        CancelOrderCoin { trading_account_id, pool_id, order_id }
    }

    public fun trading_account_id<B, Q>(self: &CancelOrderCoin<B, Q>): ID {
        self.trading_account_id
    }

    public fun pool_id<B, Q>(self: &CancelOrderCoin<B, Q>): ID { self.pool_id }

    public fun order_id<B, Q>(self: &CancelOrderCoin<B, Q>): u128 { self.order_id }

    public(package) fun permit<B, Q>(): Permit<CancelOrderCoin<B, Q>> { internal::permit() }
}
