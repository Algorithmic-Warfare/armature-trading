/// Payload: place a limit order on a TriexBook Pool<BaseAsset, QuoteAsset>.
/// Both sides of the pool are standard Coin<T> types.
/// is_bid = false -> selling base (ask); is_bid = true -> buying base (bid).
module armature_trading::place_limit_order_coin;

public struct PlaceLimitOrderCoin<phantom BaseAsset, phantom QuoteAsset> has drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    price: u64,
    quantity: u64,
    is_bid: bool,
    order_type: u8,
    self_matching_option: u8,
    expire_timestamp: u64,
}

public fun new<BaseAsset, QuoteAsset>(
    balance_manager_id: ID,
    pool_id: ID,
    price: u64,
    quantity: u64,
    is_bid: bool,
    order_type: u8,
    self_matching_option: u8,
    expire_timestamp: u64,
): PlaceLimitOrderCoin<BaseAsset, QuoteAsset> {
    PlaceLimitOrderCoin {
        balance_manager_id,
        pool_id,
        price,
        quantity,
        is_bid,
        order_type,
        self_matching_option,
        expire_timestamp,
    }
}

public fun balance_manager_id<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): ID { self.balance_manager_id }
public fun pool_id<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): ID { self.pool_id }
public fun price<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): u64 { self.price }
public fun quantity<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): u64 { self.quantity }
public fun is_bid<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): bool { self.is_bid }
public fun order_type<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): u8 { self.order_type }
public fun self_matching_option<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): u8 { self.self_matching_option }
public fun expire_timestamp<B, Q>(self: &PlaceLimitOrderCoin<B, Q>): u64 { self.expire_timestamp }
