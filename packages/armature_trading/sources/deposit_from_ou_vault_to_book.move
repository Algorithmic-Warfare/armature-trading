/// Payload: move a multicoin asset from an OuReceiptVault (armature_vault)
/// into the OU's TradingAccount, ready to back asks on the book.
/// The vault and account are identified by object ID in the payload and
/// verified at execution time; OU authorization comes from the ticket.
module armature_trading::deposit_from_ou_vault_to_book {
    use std::internal::{Self, Permit};

    public struct DepositFromOuVaultToBook has drop, store {
        vault_id: ID,
        trading_account_id: ID,
        asset_id: u64,
        amount: u64,
    }

    public fun new(
        vault_id: ID,
        trading_account_id: ID,
        asset_id: u64,
        amount: u64,
    ): DepositFromOuVaultToBook {
        DepositFromOuVaultToBook { vault_id, trading_account_id, asset_id, amount }
    }

    public fun vault_id(self: &DepositFromOuVaultToBook): ID { self.vault_id }

    public fun trading_account_id(self: &DepositFromOuVaultToBook): ID { self.trading_account_id }

    public fun asset_id(self: &DepositFromOuVaultToBook): u64 { self.asset_id }

    public fun amount(self: &DepositFromOuVaultToBook): u64 { self.amount }

    public(package) fun permit(): Permit<DepositFromOuVaultToBook> { internal::permit() }
}
