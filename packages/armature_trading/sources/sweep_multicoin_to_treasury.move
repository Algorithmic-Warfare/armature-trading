/// Payload: withdraw a multicoin asset from the BalanceManager back into the
/// DAO treasury (e.g. items received after a bid fills).
module armature_trading::sweep_multicoin_to_treasury;

use sui::object::ID;

public struct SweepMulticoinToTreasury has drop, store {
    balance_manager_id: ID,
    collection_id: ID,
    asset_id: u64,
    amount: u64,
}

public fun new(
    balance_manager_id: ID,
    collection_id: ID,
    asset_id: u64,
    amount: u64,
): SweepMulticoinToTreasury {
    SweepMulticoinToTreasury { balance_manager_id, collection_id, asset_id, amount }
}

public fun balance_manager_id(self: &SweepMulticoinToTreasury): ID { self.balance_manager_id }
public fun collection_id(self: &SweepMulticoinToTreasury): ID { self.collection_id }
public fun asset_id(self: &SweepMulticoinToTreasury): u64 { self.asset_id }
public fun amount(self: &SweepMulticoinToTreasury): u64 { self.amount }
