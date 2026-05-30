/// Payload: move a multicoin asset (collection_id / asset_id) from the DAO
/// treasury into the BalanceManager, ready to back asks.
module armature_trading::deposit_multicoin_to_book;

use sui::object::ID;

public struct DepositMulticoinToBook has drop, store {
    collection_id: ID,
    asset_id: u64,
    amount: u64,
}

public fun new(collection_id: ID, asset_id: u64, amount: u64): DepositMulticoinToBook {
    DepositMulticoinToBook { collection_id, asset_id, amount }
}

public fun collection_id(self: &DepositMulticoinToBook): ID { self.collection_id }
public fun asset_id(self: &DepositMulticoinToBook): u64 { self.asset_id }
public fun amount(self: &DepositMulticoinToBook): u64 { self.amount }
