/// Payload: place a market order on a triex MultiCoinPool<QuoteAsset>.
/// is_bid = false -> selling items (ask); is_bid = true -> buying items (bid).
/// Unlike PlaceLimitOrder, there is no price/order_type/expire_timestamp: triex
/// fills market orders immediate-or-cancel at the best available price.
module armature_trading::place_market_order {
    use std::internal::{Self, Permit};

    public struct PlaceMarketOrder<phantom QuoteAsset> has drop, store {
        trading_account_id: ID,
        pool_id: ID,
        quantity: u64,
        is_bid: bool,
        self_matching_option: u8,
    }

    public fun new<QuoteAsset>(
        trading_account_id: ID,
        pool_id: ID,
        quantity: u64,
        is_bid: bool,
        self_matching_option: u8,
    ): PlaceMarketOrder<QuoteAsset> {
        PlaceMarketOrder {
            trading_account_id,
            pool_id,
            quantity,
            is_bid,
            self_matching_option,
        }
    }

    public fun trading_account_id<Q>(self: &PlaceMarketOrder<Q>): ID { self.trading_account_id }

    public fun pool_id<Q>(self: &PlaceMarketOrder<Q>): ID { self.pool_id }

    public fun quantity<Q>(self: &PlaceMarketOrder<Q>): u64 { self.quantity }

    public fun is_bid<Q>(self: &PlaceMarketOrder<Q>): bool { self.is_bid }

    public fun self_matching_option<Q>(self: &PlaceMarketOrder<Q>): u8 { self.self_matching_option }

    public(package) fun permit<Q>(): Permit<PlaceMarketOrder<Q>> { internal::permit() }
}
