/// Payload: withdraw `amount` of coin `T` from the BalanceManager back into
/// the DAO treasury (e.g. quote proceeds after a fill).
module armature_trading::sweep_coin_to_treasury;

use sui::object::ID;

public struct SweepCoinToTreasury<phantom T> has drop, store {
    balance_manager_id: ID,
    amount: u64,
}

public fun new<T>(balance_manager_id: ID, amount: u64): SweepCoinToTreasury<T> {
    SweepCoinToTreasury { balance_manager_id, amount }
}

public fun balance_manager_id<T>(self: &SweepCoinToTreasury<T>): ID { self.balance_manager_id }
public fun amount<T>(self: &SweepCoinToTreasury<T>): u64 { self.amount }
