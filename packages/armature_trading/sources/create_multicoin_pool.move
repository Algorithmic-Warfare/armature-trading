/// Payload: create a permissionless MultiCoinPool<QuoteAsset> for the given
/// collection/asset pair, paying the creation fee from the DAO treasury.
module armature_trading::create_multicoin_pool;

public struct CreateMulticoinPool<phantom QuoteAsset> has drop, store {
    collection_id: ID,
    asset_id: u64,
}

public fun new<QuoteAsset>(collection_id: ID, asset_id: u64): CreateMulticoinPool<QuoteAsset> {
    CreateMulticoinPool { collection_id, asset_id }
}

public fun collection_id<Q>(self: &CreateMulticoinPool<Q>): ID { self.collection_id }
public fun asset_id<Q>(self: &CreateMulticoinPool<Q>): u64 { self.asset_id }
