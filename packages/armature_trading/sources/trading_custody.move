/// Custody of an OU's triex `TradingAccount` and its three caps.
///
/// A triex `TradingAccount` has a fixed `owner` address, and since cycle 7
/// `trading_account::new_with_custom_owner_and_caps` *transfers* the Deposit,
/// Withdraw and Trade caps to that owner instead of returning them. An OU has
/// no key to sign as, so the owner is a `TradingCustody` object's address:
///
///   1. `SetupTradingAccount` runs `create`, which shares a custody and a
///      TradingAccount owned by the custody's address. triex sends the three
///      caps to that address.
///   2. Anyone calls `claim_caps` in a later transaction (received objects are
///      only visible once the creating transaction commits). Each cap is checked
///      against the custody's own account before it is stored, so caps from
///      another account sent to this address cannot be claimed in their place.
///
/// The caps never leave the custody. Only this package can borrow them
/// (`public(package)`), and every `trading_ops` handler asserts the custody
/// belongs to the OU that approved its ticket. Owner-only triex functions
/// (`withdraw`, `mint_*_cap`, `register_trading_account`, ...) can never be
/// called, since nobody can sign as the custody's address.
module armature_trading::trading_custody {
    use sui::{coin, event, sui::SUI, transfer::Receiving};
    use triex::trading_account::{Self, TradingAccount, DepositCap, WithdrawCap, TradeCap};

    // === Errors ===

    const EWrongTradingAccount: u64 = 0;
    const ECapsAlreadyClaimed: u64 = 1;
    const ECapsNotClaimed: u64 = 2;

    // === Structs ===

    /// Owner of one OU TradingAccount, and holder of its caps once claimed.
    public struct TradingCustody has key {
        id: UID,
        ou_id: ID,
        trading_account_id: ID,
        deposit_cap: Option<DepositCap>,
        withdraw_cap: Option<WithdrawCap>,
        trade_cap: Option<TradeCap>,
    }

    // === Events ===

    public struct TradingCustodyCreated has copy, drop {
        custody_id: ID,
        ou_id: ID,
        trading_account_id: ID,
    }

    public struct TradingCapsClaimed has copy, drop {
        custody_id: ID,
        trading_account_id: ID,
    }

    // === Create ===

    /// Share a custody for `ou_id` and a TradingAccount owned by its address.
    /// triex transfers the account's caps to the custody; `claim_caps` stores
    /// them. Returns (custody_id, trading_account_id).
    public(package) fun create(ou_id: ID, ctx: &mut TxContext): (ID, ID) {
        let id = object::new(ctx);
        let trading_account = trading_account::new_with_custom_owner_and_caps(
            id.to_address(),
            ctx,
        );
        let trading_account_id = object::id(&trading_account);
        let custody = TradingCustody {
            id,
            ou_id,
            trading_account_id,
            deposit_cap: option::none(),
            withdraw_cap: option::none(),
            trade_cap: option::none(),
        };
        let custody_id = object::id(&custody);

        event::emit(TradingCustodyCreated { custody_id, ou_id, trading_account_id });

        transfer::share_object(custody);
        transfer::public_share_object(trading_account);
        (custody_id, trading_account_id)
    }

    // === Claim ===

    /// Receive the three caps triex sent to this custody and store them.
    /// Permissionless: the caps can only be used by this package's handlers,
    /// and each is proven to belong to `trading_account` first.
    ///
    /// The Deposit check deposits a zero SUI coin, which leaves an empty SUI
    /// balance entry on the account.
    public fun claim_caps(
        self: &mut TradingCustody,
        trading_account: &mut TradingAccount,
        deposit_cap: Receiving<DepositCap>,
        withdraw_cap: Receiving<WithdrawCap>,
        trade_cap: Receiving<TradeCap>,
        ctx: &mut TxContext,
    ) {
        assert!(object::id(trading_account) == self.trading_account_id, EWrongTradingAccount);
        assert!(
            self.deposit_cap.is_none() && self.withdraw_cap.is_none() && self.trade_cap.is_none(),
            ECapsAlreadyClaimed,
        );

        let deposit_cap = transfer::public_receive(&mut self.id, deposit_cap);
        let withdraw_cap = transfer::public_receive(&mut self.id, withdraw_cap);
        let trade_cap = transfer::public_receive(&mut self.id, trade_cap);

        // triex exposes no cap -> account getter. These no-op calls abort unless
        // the cap is on `trading_account`'s allow-list.
        let _ = trading_account.generate_proof_as_trader(&trade_cap, ctx);
        trading_account.withdraw_with_cap<SUI>(&withdraw_cap, 0, ctx).destroy_zero();
        trading_account.deposit_with_cap(&deposit_cap, coin::zero<SUI>(ctx), ctx);

        self.deposit_cap.fill(deposit_cap);
        self.withdraw_cap.fill(withdraw_cap);
        self.trade_cap.fill(trade_cap);

        event::emit(TradingCapsClaimed {
            custody_id: object::id(self),
            trading_account_id: self.trading_account_id,
        });
    }

    // === Accessors ===

    public fun ou_id(self: &TradingCustody): ID { self.ou_id }

    public fun trading_account_id(self: &TradingCustody): ID { self.trading_account_id }

    /// True once `claim_caps` has run.
    public fun caps_claimed(self: &TradingCustody): bool { self.trade_cap.is_some() }

    // === Package-only cap access ===

    public(package) fun deposit_cap(self: &TradingCustody): &DepositCap {
        assert!(self.deposit_cap.is_some(), ECapsNotClaimed);
        self.deposit_cap.borrow()
    }

    public(package) fun withdraw_cap(self: &TradingCustody): &WithdrawCap {
        assert!(self.withdraw_cap.is_some(), ECapsNotClaimed);
        self.withdraw_cap.borrow()
    }

    public(package) fun trade_cap(self: &TradingCustody): &TradeCap {
        assert!(self.trade_cap.is_some(), ECapsNotClaimed);
        self.trade_cap.borrow()
    }
}
