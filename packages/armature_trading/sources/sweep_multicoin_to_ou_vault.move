/// Payload: withdraw a multicoin asset from the OU's TradingAccount into an
/// OuReceiptVault (armature_vault) — the inverse of DepositFromOuVaultToBook
/// (e.g. items received after a bid fills). The account and destination vault
/// are identified by object ID in the payload and verified at execution time;
/// OU authorization comes from the ticket.
module armature_trading::sweep_multicoin_to_ou_vault {
    use std::internal::{Self, Permit};

    public struct SweepMulticoinToOuVault has drop, store {
        trading_account_id: ID,
        vault_id: ID,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
    }

    public fun new(
        trading_account_id: ID,
        vault_id: ID,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
    ): SweepMulticoinToOuVault {
        SweepMulticoinToOuVault { trading_account_id, vault_id, collection_id, asset_id, amount }
    }

    public fun trading_account_id(self: &SweepMulticoinToOuVault): ID { self.trading_account_id }

    public fun vault_id(self: &SweepMulticoinToOuVault): ID { self.vault_id }

    public fun collection_id(self: &SweepMulticoinToOuVault): ID { self.collection_id }

    public fun asset_id(self: &SweepMulticoinToOuVault): u64 { self.asset_id }

    public fun amount(self: &SweepMulticoinToOuVault): u64 { self.amount }

    public(package) fun permit(): Permit<SweepMulticoinToOuVault> { internal::permit() }
}
