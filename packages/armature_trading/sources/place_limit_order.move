/// Payload: place a limit order on a triex MultiCoinPool<QuoteAsset>.
/// is_bid = false -> selling items (ask); is_bid = true -> buying items (bid).
/// Quantity is in base (multicoin) units; fees are quote-denominated.
module armature_trading::place_limit_order {
    use std::internal::{Self, Permit};

    public struct PlaceLimitOrder<phantom QuoteAsset> has drop, store {
        trading_account_id: ID,
        pool_id: ID,
        price: u64,
        quantity: u64,
        is_bid: bool,
        order_type: u8,
        self_matching_option: u8,
        expire_timestamp: u64,
    }

    public fun new<QuoteAsset>(
        trading_account_id: ID,
        pool_id: ID,
        price: u64,
        quantity: u64,
        is_bid: bool,
        order_type: u8,
        self_matching_option: u8,
        expire_timestamp: u64,
    ): PlaceLimitOrder<QuoteAsset> {
        PlaceLimitOrder {
            trading_account_id,
            pool_id,
            price,
            quantity,
            is_bid,
            order_type,
            self_matching_option,
            expire_timestamp,
        }
    }

    public fun trading_account_id<Q>(self: &PlaceLimitOrder<Q>): ID { self.trading_account_id }

    public fun pool_id<Q>(self: &PlaceLimitOrder<Q>): ID { self.pool_id }

    public fun price<Q>(self: &PlaceLimitOrder<Q>): u64 { self.price }

    public fun quantity<Q>(self: &PlaceLimitOrder<Q>): u64 { self.quantity }

    public fun is_bid<Q>(self: &PlaceLimitOrder<Q>): bool { self.is_bid }

    public fun order_type<Q>(self: &PlaceLimitOrder<Q>): u8 { self.order_type }

    public fun self_matching_option<Q>(self: &PlaceLimitOrder<Q>): u8 { self.self_matching_option }

    public fun expire_timestamp<Q>(self: &PlaceLimitOrder<Q>): u64 { self.expire_timestamp }

    public(package) fun permit<Q>(): Permit<PlaceLimitOrder<Q>> { internal::permit() }
}
