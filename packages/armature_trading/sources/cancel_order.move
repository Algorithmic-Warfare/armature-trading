/// Payload: cancel a resting order on a TriexBook MultiCoinPool<QuoteAsset>.
/// Unlocked funds settle back into the BalanceManager.
module armature_trading::cancel_order;

use sui::object::ID;

public struct CancelOrder<phantom QuoteAsset> has drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
}

public fun new<QuoteAsset>(
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
): CancelOrder<QuoteAsset> {
    CancelOrder { balance_manager_id, pool_id, order_id }
}

public fun balance_manager_id<Q>(self: &CancelOrder<Q>): ID { self.balance_manager_id }
public fun pool_id<Q>(self: &CancelOrder<Q>): ID { self.pool_id }
public fun order_id<Q>(self: &CancelOrder<Q>): u64 { self.order_id }
