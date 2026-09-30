/// Central dispatcher: the eleven triex trading handlers.
///
/// Every handler consumes an `ExecutionTicket<P>` from armature_framework, so
/// each works standalone, inside a composite proposal, and via an
/// `ExternalExecutionCap` through one function. Each handler:
///   - reads `ticket.ticket_payload()` -> &P
///   - checks every object it was passed against the payload and the ticket's OU
///   - reaches the ticket's request (`ticket_request`) and closes the ticket
///     (`discharge`) with `P`'s package-only `permit()`
///
/// The OU's TradingAccount caps live in a `TradingCustody` (see
/// `trading_custody`), not in the CapabilityVault: the custody owns the account
/// and keeps its caps where only this package can borrow them. So no
/// handler borrows from the vault, and no type needs VAULT_BORROW or a borrow
/// scope. Only `DepositCoinToBook` and `CreateMulticoinPool` call a framework
/// mutator (`treasury_vault::withdraw`); `trading_permissions` lists the bits.
module armature_trading::trading_ops {
    use armature::{ou::OU, proposal::ExecutionTicket, treasury_vault::TreasuryVault};
    use armature_trading::{
        cancel_order::{Self, CancelOrder},
        cancel_order_coin::{Self, CancelOrderCoin},
        create_multicoin_pool::{Self, CreateMulticoinPool},
        deposit_coin_to_book::{Self, DepositCoinToBook},
        deposit_from_ou_vault_to_book::{Self, DepositFromOuVaultToBook},
        place_limit_order::{Self, PlaceLimitOrder},
        place_limit_order_coin::{Self, PlaceLimitOrderCoin},
        place_market_order::{Self, PlaceMarketOrder},
        setup_trading_account::{Self, SetupTradingAccount},
        sweep_coin_to_treasury::{Self, SweepCoinToTreasury},
        sweep_multicoin_to_ou_vault::{Self, SweepMulticoinToOuVault},
        trading_custody::{Self, TradingCustody}
    };
    use armature_vault::ou_receipt_vault::OuReceiptVault;
    use multicoin::multicoin::Collection;
    use sui::clock::Clock;
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        multicoin_pool::{Self, MultiCoinPool},
        pool::Pool,
        registry::Registry,
        trading_account::TradingAccount
    };

    // === Errors ===

    const EWrongTradingAccount: u64 = 0;
    const EWrongCustody: u64 = 1;
    const EWrongVault: u64 = 2;
    const EWrongPool: u64 = 3;
    const EWrongOu: u64 = 4;
    const EWrongTreasury: u64 = 5;
    const EWrongCollection: u64 = 6;

    // === setup ===

    /// Open a TradingAccount for the ticket's OU, owned by a new shared
    /// `TradingCustody` that holds its caps. The account can trade as soon as
    /// this transaction commits.
    public fun execute_setup_trading_account(
        ticket: ExecutionTicket<SetupTradingAccount>,
        ctx: &mut TxContext,
    ) {
        let (_, _) = trading_custody::create(ticket.ticket_ou_id(), ctx);
        ticket.discharge(setup_trading_account::permit());
    }

    // === deposits (OU -> book) ===

    public fun execute_deposit_coin_to_book<T>(
        treasury: &mut TreasuryVault,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        ticket: ExecutionTicket<DepositCoinToBook<T>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let coin = treasury.withdraw<T, _>(
            payload.amount(),
            ticket.ticket_request(deposit_coin_to_book::permit()),
            ctx,
        );
        trading_account.deposit_with_cap(custody.deposit_cap(), coin, ctx);

        ticket.discharge(deposit_coin_to_book::permit());
    }

    /// Move a multicoin asset from an OuReceiptVault into the OU's
    /// TradingAccount, ready to back asks. The vault must list a principal the
    /// executor satisfies for `Withdraw` (typically `Ou { ou_id }`, with the
    /// executor on its board); `ou` must be the ticket's OU.
    public fun execute_deposit_from_ou_vault_to_book(
        vault: &mut OuReceiptVault,
        ou: &OU,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        ticket: ExecutionTicket<DepositFromOuVaultToBook>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(ou.id() == ticket.ticket_ou_id(), EWrongOu);
        assert!(object::id(vault) == payload.vault_id(), EWrongVault);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let bal = vault.withdraw_receipt(ou, payload.asset_id(), payload.amount(), ctx);
        trading_account.deposit_multicoin_with_cap(custody.deposit_cap(), bal, ctx);

        ticket.discharge(deposit_from_ou_vault_to_book::permit());
    }

    // === pool creation ===

    /// Create a permissionless `MultiCoinPool<QuoteAsset>` for the payload's
    /// collection/asset, paying the CRED creation fee from the OU treasury.
    /// triex shares the pool and emits `MultiCoinPoolCreated` with its ID.
    public fun execute_create_multicoin_pool<QuoteAsset>(
        registry: &mut Registry,
        policy: &FeePolicy,
        collection: &Collection,
        treasury: &mut TreasuryVault,
        ticket: ExecutionTicket<CreateMulticoinPool<QuoteAsset>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(object::id(collection) == payload.collection_id(), EWrongCollection);

        let fee = treasury.withdraw<CRED, _>(
            constants::pool_creation_fee(),
            ticket.ticket_request(create_multicoin_pool::permit()),
            ctx,
        );
        let _pool_id = multicoin_pool::create_permissionless_pool<QuoteAsset>(
            registry,
            policy,
            collection,
            payload.asset_id(),
            fee,
            ctx,
        );

        ticket.discharge(create_multicoin_pool::permit());
    }

    // === trading ===

    public fun execute_place_limit_order<QuoteAsset>(
        pool: &mut MultiCoinPool<QuoteAsset>,
        policy: &FeePolicy,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        clock: &Clock,
        ticket: ExecutionTicket<PlaceLimitOrder<QuoteAsset>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(object::id(pool) == payload.pool_id(), EWrongPool);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let proof = trading_account.generate_proof_as_trader(custody.trade_cap(), ctx);
        let _order_info = pool.place_limit_order(
            policy,
            trading_account,
            &proof,
            payload.order_type(),
            payload.self_matching_option(),
            payload.price(),
            payload.quantity(),
            payload.is_bid(),
            payload.expire_timestamp(),
            clock,
            ctx,
        );

        ticket.discharge(place_limit_order::permit());
    }

    public fun execute_place_market_order<QuoteAsset>(
        pool: &mut MultiCoinPool<QuoteAsset>,
        policy: &FeePolicy,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        clock: &Clock,
        ticket: ExecutionTicket<PlaceMarketOrder<QuoteAsset>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(object::id(pool) == payload.pool_id(), EWrongPool);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let proof = trading_account.generate_proof_as_trader(custody.trade_cap(), ctx);
        let _order_info = pool.place_market_order(
            policy,
            trading_account,
            &proof,
            payload.self_matching_option(),
            payload.quantity(),
            payload.is_bid(),
            clock,
            ctx,
        );

        ticket.discharge(place_market_order::permit());
    }

    public fun execute_cancel_order<QuoteAsset>(
        pool: &mut MultiCoinPool<QuoteAsset>,
        policy: &FeePolicy,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        clock: &Clock,
        ticket: ExecutionTicket<CancelOrder<QuoteAsset>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(object::id(pool) == payload.pool_id(), EWrongPool);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let proof = trading_account.generate_proof_as_trader(custody.trade_cap(), ctx);
        pool.cancel_order(policy, trading_account, &proof, payload.order_id(), clock, ctx);

        ticket.discharge(cancel_order::permit());
    }

    // === coin pool trading ===

    public fun execute_place_limit_order_coin<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        policy: &FeePolicy,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        clock: &Clock,
        ticket: ExecutionTicket<PlaceLimitOrderCoin<BaseAsset, QuoteAsset>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(object::id(pool) == payload.pool_id(), EWrongPool);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let proof = trading_account.generate_proof_as_trader(custody.trade_cap(), ctx);
        let _order_info = pool.place_limit_order(
            policy,
            trading_account,
            &proof,
            payload.order_type(),
            payload.self_matching_option(),
            payload.price(),
            payload.quantity(),
            payload.is_bid(),
            payload.expire_timestamp(),
            clock,
            ctx,
        );

        ticket.discharge(place_limit_order_coin::permit());
    }

    public fun execute_cancel_order_coin<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        clock: &Clock,
        ticket: ExecutionTicket<CancelOrderCoin<BaseAsset, QuoteAsset>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(object::id(pool) == payload.pool_id(), EWrongPool);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let proof = trading_account.generate_proof_as_trader(custody.trade_cap(), ctx);
        pool.cancel_order(trading_account, &proof, payload.order_id(), clock, ctx);

        ticket.discharge(cancel_order_coin::permit());
    }

    // === sweeps (book -> OU) ===

    public fun execute_sweep_coin_to_treasury<T>(
        treasury: &mut TreasuryVault,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        ticket: ExecutionTicket<SweepCoinToTreasury<T>>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        // `treasury_vault::deposit` is permissionless, so nothing else stops the
        // executor from passing another OU's treasury.
        assert!(treasury.ou_id() == ticket.ticket_ou_id(), EWrongTreasury);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let coin = trading_account.withdraw_with_cap<T>(
            custody.withdraw_cap(),
            payload.amount(),
            ctx,
        );
        treasury.deposit<T>(coin, ctx);

        ticket.discharge(sweep_coin_to_treasury::permit());
    }

    /// Withdraw a multicoin asset from the OU's TradingAccount and park it in an
    /// OuReceiptVault. Inverse of `execute_deposit_from_ou_vault_to_book`. The
    /// executor must satisfy the vault's `Deposit` role, with `ou` (the ticket's
    /// OU) as their OU context.
    public fun execute_sweep_multicoin_to_ou_vault(
        vault: &mut OuReceiptVault,
        ou: &OU,
        custody: &TradingCustody,
        trading_account: &mut TradingAccount,
        ticket: ExecutionTicket<SweepMulticoinToOuVault>,
        ctx: &mut TxContext,
    ) {
        let payload = ticket.ticket_payload();
        assert!(ou.id() == ticket.ticket_ou_id(), EWrongOu);
        assert!(object::id(vault) == payload.vault_id(), EWrongVault);
        assert_custody(
            custody,
            ticket.ticket_ou_id(),
            trading_account,
            payload.trading_account_id(),
        );

        let bal = trading_account.withdraw_multicoin_with_cap(
            custody.withdraw_cap(),
            payload.collection_id(),
            payload.asset_id(),
            payload.amount(),
            ctx,
        );
        vault.deposit_receipt(ou, bal, ctx);

        ticket.discharge(sweep_multicoin_to_ou_vault::permit());
    }

    // === Internal ===

    /// `trading_account` is the one the payload names, and `custody` belongs to
    /// the ticket's OU and holds that account's caps.
    fun assert_custody(
        custody: &TradingCustody,
        ou_id: ID,
        trading_account: &TradingAccount,
        trading_account_id: ID,
    ) {
        assert!(object::id(trading_account) == trading_account_id, EWrongTradingAccount);
        assert!(custody.ou_id() == ou_id, EWrongCustody);
        assert!(custody.trading_account_id() == trading_account_id, EWrongCustody);
    }
}
