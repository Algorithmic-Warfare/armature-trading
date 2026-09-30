/// Custody of an OU's triex `TradingAccount` and its three caps.
///
/// A triex `TradingAccount` has a fixed `owner` address, and only the owner may
/// mint caps or call owner-only functions. An OU has no key to sign as, so the
/// owner is a `TradingCustody` object's address. `SetupTradingAccount` runs
/// `create`, which calls `trading_account::new_with_uid_owner_and_caps` with the
/// custody's UID: triex returns the Deposit, Withdraw and Trade caps directly,
/// and they are stored in the custody in the same transaction.
///
/// The caps never leave the custody. Only this package can borrow them
/// (`public(package)`), and every `trading_ops` handler asserts the custody
/// belongs to the OU that approved its ticket. Owner-only triex functions
/// (`withdraw`, `mint_*_cap`, `revoke_trade_cap`, `register_trading_account`,
/// ...) can never be called, since nobody can sign as the custody's address, so
/// the stored caps cannot be revoked or replaced.
module armature_trading::trading_custody {
    use sui::event;
    use triex::trading_account::{Self, DepositCap, WithdrawCap, TradeCap};

    // === Structs ===

    /// Owner of one OU TradingAccount, and holder of its caps.
    public struct TradingCustody has key {
        id: UID,
        ou_id: ID,
        trading_account_id: ID,
        deposit_cap: DepositCap,
        withdraw_cap: WithdrawCap,
        trade_cap: TradeCap,
    }

    // === Events ===

    public struct TradingCustodyCreated has copy, drop {
        custody_id: ID,
        ou_id: ID,
        trading_account_id: ID,
    }

    // === Create ===

    /// Share a custody for `ou_id` holding the caps of a new TradingAccount
    /// owned by the custody's address, and share the account.
    /// Returns (custody_id, trading_account_id).
    public(package) fun create(ou_id: ID, ctx: &mut TxContext): (ID, ID) {
        let mut id = object::new(ctx);
        let (trading_account, deposit_cap, withdraw_cap, trade_cap) =
            trading_account::new_with_uid_owner_and_caps(&mut id, ctx);
        let trading_account_id = object::id(&trading_account);
        let custody = TradingCustody {
            id,
            ou_id,
            trading_account_id,
            deposit_cap,
            withdraw_cap,
            trade_cap,
        };
        let custody_id = object::id(&custody);

        event::emit(TradingCustodyCreated { custody_id, ou_id, trading_account_id });

        transfer::share_object(custody);
        transfer::public_share_object(trading_account);
        (custody_id, trading_account_id)
    }

    // === Accessors ===

    public fun ou_id(self: &TradingCustody): ID { self.ou_id }

    public fun trading_account_id(self: &TradingCustody): ID { self.trading_account_id }

    // === Package-only cap access ===

    public(package) fun deposit_cap(self: &TradingCustody): &DepositCap { &self.deposit_cap }

    public(package) fun withdraw_cap(self: &TradingCustody): &WithdrawCap { &self.withdraw_cap }

    public(package) fun trade_cap(self: &TradingCustody): &TradeCap { &self.trade_cap }
}
