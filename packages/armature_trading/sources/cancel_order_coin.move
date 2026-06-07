/// Payload: cancel a resting order on a TriexBook Pool<BaseAsset, QuoteAsset>.
/// Unlocked funds settle back into the BalanceManager.
module armature_trading::cancel_order_coin;

public struct CancelOrderCoin<phantom BaseAsset, phantom QuoteAsset> has drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
}

public fun new<BaseAsset, QuoteAsset>(
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
): CancelOrderCoin<BaseAsset, QuoteAsset> {
    CancelOrderCoin { balance_manager_id, pool_id, order_id }
}

public fun balance_manager_id<B, Q>(self: &CancelOrderCoin<B, Q>): ID { self.balance_manager_id }
public fun pool_id<B, Q>(self: &CancelOrderCoin<B, Q>): ID { self.pool_id }
public fun order_id<B, Q>(self: &CancelOrderCoin<B, Q>): u64 { self.order_id }
