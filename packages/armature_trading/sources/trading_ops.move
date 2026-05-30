/// Central dispatcher: the seven TriexBook trading handlers.
///
/// Every handler runs through the unified `ExecutionTicket<P>` hot potato from
/// armature_framework (commit 5ed3786). Each handler:
///   - reads `ticket.ticket_payload()`   -> &P
///   - reads `ticket.ticket_request()`   -> &ExecutionRequest<P>  (vault auth)
///   - ends with `ticket.discharge()`
/// No `_step` twins: ExecutionTicket<P> makes each handler usable standalone,
/// inside a composite proposal, and via ExternalExecutionCap through one fn.
///
/// Caps are resolved from the vault by type: DepositCap / WithdrawCap / TradeCap
/// each appear exactly once (deposited by SetupTradingAccount). They are borrowed
/// IMMUTABLY (`borrow_cap -> &T`); triexbook takes every cap by `&`, so no
/// framework change is needed.
///
/// ============================ OPEN ITEMS ============================
/// (1) BLOCKER — cap <-> balance_manager binding assertion.
///     The doc asserts e.g. `trade_cap.balance_manager_id() == payload.bm_id`,
///     but triexbook exposes NO public getter for the cap's bound BM id, and its
///     `validate_*` fns are private. triexbook DOES enforce the binding inside
///     each op (deposit_with_cap / generate_proof_as_trader call validate_*),
///     so an attacker cannot use a cap against the wrong BM. But the caller
///     cannot *pre-assert* it. Resolution options (pick one before merge):
///       a) Add a public `balance_manager_id(&Cap): ID` accessor to triexbook.
///       b) Rely on triexbook's internal validation + assert only
///          `object::id(balance_manager) == payload.balance_manager_id`
///          (proves the caller passed the BM the proposal voted on).
///     Below uses option (b) as the compilable default; revisit if (a) lands.
/// (2) SetupTradingAccount multiplicity: handler aborts if a DepositCap already
///     exists, enforcing one trading account per vault so `ids_for_type[0]` is
///     unambiguous. Relax later if multi-BM support is wanted.
/// ====================================================================
module armature_trading::trading_ops;

use armature::capability_vault::CapabilityVault;
use armature::proposal::ExecutionTicket;
use armature::treasury_vault::TreasuryVault;
use sui::clock::Clock;
use triexbook::balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap, TradeCap};
use triexbook::multicoin_pool::MultiCoinPool;

use armature_trading::setup_trading_account::SetupTradingAccount;
use armature_trading::deposit_coin_to_book::DepositCoinToBook;
use armature_trading::deposit_multicoin_to_book::DepositMulticoinToBook;
use armature_trading::place_limit_order::PlaceLimitOrder;
use armature_trading::cancel_order::CancelOrder;
use armature_trading::sweep_coin_to_treasury::SweepCoinToTreasury;
use armature_trading::sweep_multicoin_to_treasury::SweepMulticoinToTreasury;

const EAlreadySetUp: u64 = 0;
const EWrongBalanceManager: u64 = 1;

// === setup ===

/// Create the DAO's BalanceManager and stash its three caps in the vault.
/// The DAO is identified by the ExecutionRequest carried in the ticket; the
/// new BalanceManager is owned by the DAO id (req.req_dao_id() -> address).
public fun execute_setup_trading_account(
    cap_vault: &mut CapabilityVault,
    ticket: ExecutionTicket<SetupTradingAccount>,
    ctx: &mut TxContext,
) {
    let req = ticket.ticket_request();

    // Enforce single trading account so `ids_for_type<_>()[0]` is unambiguous.
    assert!(cap_vault.ids_for_type<DepositCap>().is_empty(), EAlreadySetUp);

    // TODO(owner): confirm how the DAO's on-chain address is derived. The vault
    // is keyed by dao_id (an ID). triexbook wants an `owner: address`. Either
    // the DAO has a canonical address accessor, or the BM is owned by the
    // package / a derived address. Using req DAO id -> address as a placeholder.
    let dao_owner: address = req.req_dao_id().to_address();

    let (balance_manager, deposit_cap, withdraw_cap, trade_cap) =
        balance_manager::new_with_custom_owner_and_caps(dao_owner, ctx);

    cap_vault.store_cap<DepositCap, _>(deposit_cap, req);
    cap_vault.store_cap<WithdrawCap, _>(withdraw_cap, req);
    cap_vault.store_cap<TradeCap, _>(trade_cap, req);

    transfer::public_share_object(balance_manager);
    ticket.discharge();
}

// === deposits (treasury -> book) ===

public fun execute_deposit_coin_to_book<T>(
    treasury: &mut TreasuryVault,
    balance_manager: &mut BalanceManager,
    cap_vault: &CapabilityVault,
    ticket: ExecutionTicket<DepositCoinToBook<T>>,
    ctx: &mut TxContext,
) {
    let payload = ticket.ticket_payload();
    let req = ticket.ticket_request();

    let deposit_cap_id = cap_vault.ids_for_type<DepositCap>()[0];
    let deposit_cap = cap_vault.borrow_cap<DepositCap, _>(deposit_cap_id, req);

    let coin = treasury.withdraw<T, _>(payload.amount(), req, ctx);
    balance_manager.deposit_with_cap(deposit_cap, coin, ctx);

    ticket.discharge();
}

public fun execute_deposit_multicoin_to_book(
    treasury: &mut TreasuryVault,
    balance_manager: &mut BalanceManager,
    cap_vault: &CapabilityVault,
    ticket: ExecutionTicket<DepositMulticoinToBook>,
    ctx: &mut TxContext,
) {
    let payload = ticket.ticket_payload();
    let req = ticket.ticket_request();

    let deposit_cap_id = cap_vault.ids_for_type<DepositCap>()[0];
    let deposit_cap = cap_vault.borrow_cap<DepositCap, _>(deposit_cap_id, req);

    let bal = treasury.withdraw_multicoin<_>(
        payload.collection_id(),
        payload.asset_id(),
        payload.amount(),
        req,
        ctx,
    );
    balance_manager.deposit_multicoin_with_cap(deposit_cap, bal, ctx);

    ticket.discharge();
}

// === trading ===

public fun execute_place_limit_order<QuoteAsset>(
    pool: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    cap_vault: &CapabilityVault,
    clock: &Clock,
    ticket: ExecutionTicket<PlaceLimitOrder<QuoteAsset>>,
    ctx: &mut TxContext,
) {
    let payload = ticket.ticket_payload();
    let req = ticket.ticket_request();

    // See OPEN ITEM (1): assert the caller passed the BM the proposal voted on.
    // triexbook's generate_proof_as_trader internally validates cap<->BM.
    assert!(object::id(balance_manager) == payload.balance_manager_id(), EWrongBalanceManager);

    let trade_cap_id = cap_vault.ids_for_type<TradeCap>()[0];
    let trade_cap = cap_vault.borrow_cap<TradeCap, _>(trade_cap_id, req);

    let proof = balance_manager.generate_proof_as_trader(trade_cap, ctx);
    // place_limit_order returns OrderInfo; bind and drop it (or surface it later).
    let _order_info = pool.place_limit_order(
        balance_manager,
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

    ticket.discharge();
}

public fun execute_cancel_order<QuoteAsset>(
    pool: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    cap_vault: &CapabilityVault,
    clock: &Clock,
    ticket: ExecutionTicket<CancelOrder<QuoteAsset>>,
    ctx: &mut TxContext,
) {
    let payload = ticket.ticket_payload();
    let req = ticket.ticket_request();

    assert!(object::id(balance_manager) == payload.balance_manager_id(), EWrongBalanceManager);

    let trade_cap_id = cap_vault.ids_for_type<TradeCap>()[0];
    let trade_cap = cap_vault.borrow_cap<TradeCap, _>(trade_cap_id, req);

    let proof = balance_manager.generate_proof_as_trader(trade_cap, ctx);
    pool.cancel_order(balance_manager, &proof, payload.order_id(), clock, ctx);

    ticket.discharge();
}

// === sweeps (book -> treasury) ===

public fun execute_sweep_coin_to_treasury<T>(
    treasury: &mut TreasuryVault,
    balance_manager: &mut BalanceManager,
    cap_vault: &CapabilityVault,
    ticket: ExecutionTicket<SweepCoinToTreasury<T>>,
    ctx: &mut TxContext,
) {
    let payload = ticket.ticket_payload();
    let req = ticket.ticket_request();

    assert!(object::id(balance_manager) == payload.balance_manager_id(), EWrongBalanceManager);

    let withdraw_cap_id = cap_vault.ids_for_type<WithdrawCap>()[0];
    let withdraw_cap = cap_vault.borrow_cap<WithdrawCap, _>(withdraw_cap_id, req);

    let coin = balance_manager.withdraw_with_cap<T>(withdraw_cap, payload.amount(), ctx);
    treasury.deposit<T>(coin, ctx);

    ticket.discharge();
}

public fun execute_sweep_multicoin_to_treasury(
    treasury: &mut TreasuryVault,
    balance_manager: &mut BalanceManager,
    cap_vault: &CapabilityVault,
    ticket: ExecutionTicket<SweepMulticoinToTreasury>,
    ctx: &mut TxContext,
) {
    let payload = ticket.ticket_payload();
    let req = ticket.ticket_request();

    assert!(object::id(balance_manager) == payload.balance_manager_id(), EWrongBalanceManager);

    let withdraw_cap_id = cap_vault.ids_for_type<WithdrawCap>()[0];
    let withdraw_cap = cap_vault.borrow_cap<WithdrawCap, _>(withdraw_cap_id, req);

    let bal = balance_manager.withdraw_multicoin_with_cap(
        withdraw_cap,
        payload.collection_id(),
        payload.asset_id(),
        payload.amount(),
        ctx,
    );
    treasury.deposit_multicoin(bal, ctx);

    ticket.discharge();
}
