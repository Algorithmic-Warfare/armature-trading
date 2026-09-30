/// Tests for the coin-pool order handlers (`PlaceLimitOrderCoin`,
/// `CancelOrderCoin`) and `CreateMulticoinPool`, run against a real triex
/// Registry, a bootstrapped FeePolicy and a registered `Pool<BASE, QUOTE>`.
/// The `sve_*` tests go through `board_voting::submit_vote_execute`, so the
/// ticket carries only the bits the type was enabled with.
#[test_only]
module armature_trading::coin_trading_tests {
    use armature::{
        board_voting,
        emergency::EmergencyFreeze,
        ou::OU,
        proposal,
        treasury_vault::TreasuryVault
    };
    use armature_trading::{
        cancel_order_coin::{Self, CancelOrderCoin},
        create_multicoin_pool::{Self, CreateMulticoinPool},
        place_limit_order_coin::{Self, PlaceLimitOrderCoin},
        trading_custody::TradingCustody,
        trading_ops,
        trading_permissions,
        trading_test_utils as utils
    };
    use multicoin::multicoin::Collection;
    use std::unit_test::destroy;
    use sui::{clock::{Self, Clock}, coin, test_scenario::{Self as ts, Scenario}};
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::{Self, FeePolicy},
        multicoin_pool::MultiCoinPool,
        pool::{Self, Pool},
        registry::{Self, Registry, TriexAdminCap},
        trading_account::TradingAccount
    };

    public struct BASE has drop {}
    public struct QUOTE has drop {}

    const OFFICER: address = @0xD1;
    const OTHER_OU: address = @0x0B0B;
    const ASSET: u64 = 7;
    const LARGE_EXPIRE: u64 = 1_000_000_000_000;
    /// 10^6: QUOTE is priced like CRED/USDC.
    const QUOTE_UNIT: u128 = 1_000_000;

    // Abort codes in armature_trading::trading_ops.
    const EWrongTradingAccount: u64 = 0;
    const EWrongCustody: u64 = 1;
    const EWrongPool: u64 = 3;
    const EWrongCollection: u64 = 6;
    // Abort code in armature::proposal.
    const EPermissionDenied: u64 = 21;
    // Abort codes in armature::treasury_vault.
    const EInsufficientBalance: u64 = 0;
    const EOUIdMismatch: u64 = 1;

    /// Shared triex Registry and FeePolicy with QUOTE approved and bootstrapped.
    /// Returns (registry_id, policy_id, admin_cap).
    fun setup_exchange(scenario: &mut Scenario): (ID, ID, TriexAdminCap) {
        ts::next_tx(scenario, OFFICER);
        let registry_id = registry::test_registry(scenario.ctx());
        let cap = registry::get_admin_cap_for_testing(scenario.ctx());
        let mut policy = fee_policy::create_for_testing(scenario.ctx());
        policy.bootstrap_quote<QUOTE>(0, 1, QUOTE_UNIT, &cap, scenario.ctx());
        let policy_id = object::id(&policy);
        policy.share_for_testing();

        ts::next_tx(scenario, OFFICER);
        let mut registry = ts::take_shared_by_id<Registry>(scenario, registry_id);
        registry.add_approved_quote_unchecked<QUOTE>(&cap);
        ts::return_shared(registry);
        (registry_id, policy_id, cap)
    }

    /// Create a registered `Pool<BASE, QUOTE>`. Returns its id.
    fun create_coin_pool(scenario: &mut Scenario, registry_id: ID, policy_id: ID): ID {
        ts::next_tx(scenario, OFFICER);
        let mut registry = ts::take_shared_by_id<Registry>(scenario, registry_id);
        let policy = ts::take_shared_by_id<FeePolicy>(scenario, policy_id);
        let fee = coin::mint_for_testing<CRED>(constants::pool_creation_fee(), scenario.ctx());
        let pool_id = pool::create_permissionless_pool_for_testing<BASE, QUOTE>(
            &mut registry,
            &policy,
            6,
            6,
            fee,
            scenario.ctx(),
        );
        ts::return_shared(policy);
        ts::return_shared(registry);
        pool_id
    }

    /// An OU (sole member OFFICER), its TradingCustody and TradingAccount funded
    /// with QUOTE, and a registered coin pool. Leaves the scenario in an OFFICER
    /// transaction. Returns (ou_id, pool_id, policy_id, admin_cap).
    fun start(scenario: &mut Scenario): (ID, ID, ID, TriexAdminCap) {
        let ou_id = utils::make_ou(scenario, OFFICER, vector[OFFICER]);
        let (registry_id, policy_id, cap) = setup_exchange(scenario);
        let pool_id = create_coin_pool(scenario, registry_id, policy_id);

        let (custody, mut account) = utils::setup(scenario, OFFICER, ou_id);
        account.deposit_with_cap(
            custody.deposit_cap(),
            coin::mint_for_testing<QUOTE>(1_000 * constants::float_scaling(), scenario.ctx()),
            scenario.ctx(),
        );
        ts::return_shared(custody);
        ts::return_shared(account);

        ts::next_tx(scenario, OFFICER);
        (ou_id, pool_id, policy_id, cap)
    }

    /// A bid for 1 BASE at 1 QUOTE on `pool_id`.
    fun bid(account_id: ID, pool_id: ID): PlaceLimitOrderCoin<BASE, QUOTE> {
        place_limit_order_coin::new<BASE, QUOTE>(
            account_id,
            pool_id,
            constants::float_scaling(),
            constants::float_scaling(),
            true,
            0,
            0,
            LARGE_EXPIRE,
        )
    }

    fun place_bid(
        scenario: &mut Scenario,
        pool: &mut Pool<BASE, QUOTE>,
        policy: &FeePolicy,
        custody: &TradingCustody,
        account: &mut TradingAccount,
        clock: &Clock,
        ou_id: ID,
    ) {
        let account_id = object::id(account);
        let pool_id = object::id(pool);
        trading_ops::execute_place_limit_order_coin(
            pool,
            policy,
            custody,
            account,
            clock,
            utils::ticket(ou_id, bid(account_id, pool_id)),
            scenario.ctx(),
        );
    }

    /// Enable `P` on the OU with a zero-delay 1-of-1 config carrying `bits`.
    fun enable<P>(scenario: &mut Scenario, ou_id: ID, key: vector<u8>, bits: u64) {
        ts::next_tx(scenario, OFFICER);
        let mut ou = ts::take_shared_by_id<OU>(scenario, ou_id);
        let config = proposal::new_config(10_000, 10_000, 0, 3_600_000, 0, 0).with_permissions(
            bits,
        );
        ou.test_enable_type<P>(key.to_ascii_string(), config);
        ts::return_shared(ou);
    }

    // === PlaceLimitOrderCoin / CancelOrderCoin ===

    #[test]
    fun place_and_cancel_order_coin_ok() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, policy_id, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let clock = clock::create_for_testing(scenario.ctx());

        place_bid(&mut scenario, &mut pool, &policy, &custody, &mut account, &clock, ou_id);
        let open = pool.account_open_orders(&account);
        assert!(open.length() == 1);
        let order_id = open.into_keys()[0];
        let account_id = object::id(&account);

        trading_ops::execute_cancel_order_coin(
            &mut pool,
            &custody,
            &mut account,
            &clock,
            utils::ticket(
                ou_id,
                cancel_order_coin::new<BASE, QUOTE>(account_id, pool_id, order_id),
            ),
            scenario.ctx(),
        );
        assert!(pool.account_open_orders(&account).is_empty());

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EWrongPool, location = armature_trading::trading_ops)]
    fun place_order_coin_wrong_pool_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, policy_id, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let account_id = object::id(&account);
        let clock = clock::create_for_testing(scenario.ctx());

        trading_ops::execute_place_limit_order_coin(
            &mut pool,
            &policy,
            &custody,
            &mut account,
            &clock,
            utils::ticket(ou_id, bid(account_id, object::id_from_address(@0xBAD))),
            scenario.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EWrongTradingAccount, location = armature_trading::trading_ops)]
    fun cancel_order_coin_wrong_account_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, _, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let clock = clock::create_for_testing(scenario.ctx());

        trading_ops::execute_cancel_order_coin(
            &mut pool,
            &custody,
            &mut account,
            &clock,
            utils::ticket(
                ou_id,
                cancel_order_coin::new<BASE, QUOTE>(object::id_from_address(@0xDEAD), pool_id, 0),
            ),
            scenario.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    /// A resting bid locks its QUOTE principal plus the maker fee; cancelling it
    /// settles all of that back into the OU's TradingAccount except the share
    /// of the fee triex retains on cancel.
    #[test]
    fun cancel_order_coin_returns_funds() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, policy_id, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let account_id = object::id(&account);
        let clock = clock::create_for_testing(scenario.ctx());
        let before = account.balance<QUOTE>();

        place_bid(&mut scenario, &mut pool, &policy, &custody, &mut account, &clock, ou_id);
        let (_, locked, _) = pool.locked_balance(&account);
        assert!(locked > 0);
        assert!(account.balance<QUOTE>() == before - locked);

        let order_id = pool.account_open_orders(&account).into_keys()[0];
        // The bid is 1 BASE at 1 QUOTE, so its principal is one QUOTE unit.
        let maker_fee = locked - constants::float_scaling();
        assert!(maker_fee > 0);
        let retained = maker_fee * pool.get_order(order_id).cancel_retention_bps() / 10_000;
        trading_ops::execute_cancel_order_coin(
            &mut pool,
            &custody,
            &mut account,
            &clock,
            utils::ticket(
                ou_id,
                cancel_order_coin::new<BASE, QUOTE>(account_id, pool_id, order_id),
            ),
            scenario.ctx(),
        );
        let (_, locked, _) = pool.locked_balance(&account);
        assert!(locked == 0);
        assert!(account.balance<QUOTE>() == before - retained);

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    /// The resting order carries the payload's account, side, price, quantity
    /// and expiry. Price and quantity differ so a swap would show.
    #[test]
    fun place_order_coin_forwards_payload() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, policy_id, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let account_id = object::id(&account);
        let clock = clock::create_for_testing(scenario.ctx());
        let price = 2 * constants::float_scaling();
        let quantity = 3 * constants::float_scaling();
        let expire = LARGE_EXPIRE - 1;

        trading_ops::execute_place_limit_order_coin(
            &mut pool,
            &policy,
            &custody,
            &mut account,
            &clock,
            utils::ticket(
                ou_id,
                place_limit_order_coin::new<BASE, QUOTE>(
                    account_id,
                    pool_id,
                    price,
                    quantity,
                    true,
                    0,
                    0,
                    expire,
                ),
            ),
            scenario.ctx(),
        );
        let order_id = pool.account_open_orders(&account).into_keys()[0];
        // triex encodes the side in the top bit of the order id: 0 for a bid.
        assert!(order_id >> 127 == 0);
        let order = pool.get_order(order_id);
        assert!(order.trading_account_id() == account_id);
        assert!(order.price() == price);
        assert!(order.quantity() == quantity);
        assert!(order.expire_timestamp() == expire);

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    /// A custody belonging to another OU cannot serve this ticket.
    #[test]
    #[expected_failure(abort_code = EWrongCustody, location = armature_trading::trading_ops)]
    fun place_order_coin_with_other_ou_ticket_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (_, pool_id, policy_id, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let account_id = object::id(&account);
        let clock = clock::create_for_testing(scenario.ctx());

        trading_ops::execute_place_limit_order_coin(
            &mut pool,
            &policy,
            &custody,
            &mut account,
            &clock,
            utils::ticket(object::id_from_address(OTHER_OU), bid(account_id, pool_id)),
            scenario.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    /// A custody belonging to another OU cannot serve this ticket.
    #[test]
    #[expected_failure(abort_code = EWrongCustody, location = armature_trading::trading_ops)]
    fun cancel_order_coin_with_other_ou_ticket_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, policy_id, cap) = start(&mut scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let account_id = object::id(&account);
        let clock = clock::create_for_testing(scenario.ctx());

        place_bid(&mut scenario, &mut pool, &policy, &custody, &mut account, &clock, ou_id);
        let order_id = pool.account_open_orders(&account).into_keys()[0];
        trading_ops::execute_cancel_order_coin(
            &mut pool,
            &custody,
            &mut account,
            &clock,
            utils::ticket(
                object::id_from_address(OTHER_OU),
                cancel_order_coin::new<BASE, QUOTE>(account_id, pool_id, order_id),
            ),
            scenario.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    /// Governance path: a 1-of-1 board submits, votes and executes in one call.
    /// Both coin order types need no permission bits.
    #[test]
    fun sve_place_and_cancel_order_coin_ok() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, pool_id, policy_id, cap) = start(&mut scenario);
        enable<PlaceLimitOrderCoin<BASE, QUOTE>>(
            &mut scenario,
            ou_id,
            b"PlaceLimitOrderCoin",
            trading_permissions::no_bits(),
        );
        enable<CancelOrderCoin<BASE, QUOTE>>(
            &mut scenario,
            ou_id,
            b"CancelOrderCoin",
            trading_permissions::no_bits(),
        );

        ts::next_tx(&mut scenario, OFFICER);
        let mut ou = ts::take_shared_by_id<OU>(&scenario, ou_id);
        let freeze = ts::take_shared<EmergencyFreeze>(&scenario);
        let mut pool = ts::take_shared_by_id<Pool<BASE, QUOTE>>(&scenario, pool_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let custody = ts::take_shared<TradingCustody>(&scenario);
        let mut account = ts::take_shared_by_id<TradingAccount>(
            &scenario,
            custody.trading_account_id(),
        );
        let account_id = object::id(&account);
        let clock = clock::create_for_testing(scenario.ctx());

        let ticket = board_voting::submit_vote_execute(
            &mut ou,
            option::none(),
            bid(account_id, pool_id),
            &freeze,
            &clock,
            scenario.ctx(),
        );
        trading_ops::execute_place_limit_order_coin(
            &mut pool,
            &policy,
            &custody,
            &mut account,
            &clock,
            ticket,
            scenario.ctx(),
        );
        let order_id = pool.account_open_orders(&account).into_keys()[0];

        let ticket = board_voting::submit_vote_execute(
            &mut ou,
            option::none(),
            cancel_order_coin::new<BASE, QUOTE>(account_id, pool_id, order_id),
            &freeze,
            &clock,
            scenario.ctx(),
        );
        trading_ops::execute_cancel_order_coin(
            &mut pool,
            &custody,
            &mut account,
            &clock,
            ticket,
            scenario.ctx(),
        );
        assert!(pool.account_open_orders(&account).is_empty());

        clock.destroy_for_testing();
        ts::return_shared(ou);
        ts::return_shared(freeze);
        ts::return_shared(pool);
        ts::return_shared(policy);
        ts::return_shared(custody);
        ts::return_shared(account);
        destroy(cap);
        ts::end(scenario);
    }

    // === CreateMulticoinPool ===

    /// An OU with `cred` CRED in its treasury, a Collection and an exchange.
    /// Leaves the scenario in an OFFICER transaction.
    /// Returns (ou_id, registry_id, policy_id, collection_id, admin_cap).
    fun start_pool_creation(
        scenario: &mut Scenario,
        cred: u64,
    ): (ID, ID, ID, ID, TriexAdminCap) {
        let ou_id = utils::make_ou(scenario, OFFICER, vector[OFFICER]);
        let collection_id = utils::make_collection(scenario, OFFICER);
        let (registry_id, policy_id, cap) = setup_exchange(scenario);

        ts::next_tx(scenario, OFFICER);
        let mut treasury = ts::take_shared<TreasuryVault>(scenario);
        treasury.deposit(
            coin::mint_for_testing<CRED>(cred, scenario.ctx()),
            scenario.ctx(),
        );
        ts::return_shared(treasury);

        ts::next_tx(scenario, OFFICER);
        (ou_id, registry_id, policy_id, collection_id, cap)
    }

    #[test]
    fun create_multicoin_pool_ok() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, registry_id, policy_id, collection_id, cap) = start_pool_creation(
            &mut scenario,
            constants::pool_creation_fee(),
        );
        let mut registry = ts::take_shared_by_id<Registry>(&scenario, registry_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let collection = ts::take_shared_by_id<Collection>(&scenario, collection_id);
        let mut treasury = ts::take_shared<TreasuryVault>(&scenario);

        trading_ops::execute_create_multicoin_pool(
            &mut registry,
            &policy,
            &collection,
            &mut treasury,
            utils::ticket(ou_id, create_multicoin_pool::new<QUOTE>(collection_id, ASSET)),
            scenario.ctx(),
        );
        assert!(treasury.balance<CRED>() == 0);

        ts::return_shared(registry);
        ts::return_shared(policy);
        ts::return_shared(collection);
        ts::return_shared(treasury);

        ts::next_tx(&mut scenario, OFFICER);
        let pool = ts::take_shared<MultiCoinPool<QUOTE>>(&scenario);
        assert!(pool.collection_id() == collection_id);
        assert!(pool.asset_id() == ASSET);
        ts::return_shared(pool);

        destroy(cap);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EWrongCollection, location = armature_trading::trading_ops)]
    fun create_multicoin_pool_wrong_collection_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, registry_id, policy_id, collection_id, cap) = start_pool_creation(
            &mut scenario,
            constants::pool_creation_fee(),
        );
        let mut registry = ts::take_shared_by_id<Registry>(&scenario, registry_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let collection = ts::take_shared_by_id<Collection>(&scenario, collection_id);
        let mut treasury = ts::take_shared<TreasuryVault>(&scenario);

        trading_ops::execute_create_multicoin_pool(
            &mut registry,
            &policy,
            &collection,
            &mut treasury,
            utils::ticket(
                ou_id,
                create_multicoin_pool::new<QUOTE>(object::id_from_address(@0xBAD), ASSET),
            ),
            scenario.ctx(),
        );

        ts::return_shared(registry);
        ts::return_shared(policy);
        ts::return_shared(collection);
        ts::return_shared(treasury);
        destroy(cap);
        ts::end(scenario);
    }

    /// Run CreateMulticoinPool with a ticket for `ticket_ou_id`, paying from the
    /// treasury `treasury_id`. Returns the CRED left in that treasury.
    fun execute_create_pool(
        scenario: &mut Scenario,
        ticket_ou_id: ID,
        treasury_id: ID,
        registry_id: ID,
        policy_id: ID,
        collection_id: ID,
    ): u64 {
        let mut registry = ts::take_shared_by_id<Registry>(scenario, registry_id);
        let policy = ts::take_shared_by_id<FeePolicy>(scenario, policy_id);
        let collection = ts::take_shared_by_id<Collection>(scenario, collection_id);
        let mut treasury = ts::take_shared_by_id<TreasuryVault>(scenario, treasury_id);

        trading_ops::execute_create_multicoin_pool(
            &mut registry,
            &policy,
            &collection,
            &mut treasury,
            utils::ticket(ticket_ou_id, create_multicoin_pool::new<QUOTE>(collection_id, ASSET)),
            scenario.ctx(),
        );
        let left = treasury.balance<CRED>();

        ts::return_shared(registry);
        ts::return_shared(policy);
        ts::return_shared(collection);
        ts::return_shared(treasury);
        left
    }

    fun treasury_id(scenario: &Scenario, ou_id: ID): ID {
        let ou = ts::take_shared_by_id<OU>(scenario, ou_id);
        let id = ou.treasury_id();
        ts::return_shared(ou);
        id
    }

    /// Only the creation fee leaves the treasury; the rest of its CRED stays.
    #[test]
    fun create_multicoin_pool_takes_only_fee() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, registry_id, policy_id, collection_id, cap) = start_pool_creation(
            &mut scenario,
            constants::pool_creation_fee() + 500,
        );
        let treasury_id = treasury_id(&scenario, ou_id);

        let left = execute_create_pool(
            &mut scenario,
            ou_id,
            treasury_id,
            registry_id,
            policy_id,
            collection_id,
        );
        assert!(left == 500);

        destroy(cap);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EInsufficientBalance, location = armature::treasury_vault)]
    fun create_multicoin_pool_insufficient_cred_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, registry_id, policy_id, collection_id, cap) = start_pool_creation(
            &mut scenario,
            constants::pool_creation_fee() - 1,
        );
        let treasury_id = treasury_id(&scenario, ou_id);

        execute_create_pool(
            &mut scenario,
            ou_id,
            treasury_id,
            registry_id,
            policy_id,
            collection_id,
        );

        destroy(cap);
        ts::end(scenario);
    }

    /// Another OU's ticket cannot spend this OU's CRED on the creation fee.
    #[test]
    #[expected_failure(abort_code = EOUIdMismatch, location = armature::treasury_vault)]
    fun create_multicoin_pool_from_other_ou_treasury_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, registry_id, policy_id, collection_id, cap) = start_pool_creation(
            &mut scenario,
            constants::pool_creation_fee(),
        );
        let other_ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        ts::next_tx(&mut scenario, OFFICER);
        let treasury_id = treasury_id(&scenario, ou_id);

        execute_create_pool(
            &mut scenario,
            other_ou_id,
            treasury_id,
            registry_id,
            policy_id,
            collection_id,
        );

        destroy(cap);
        ts::end(scenario);
    }

    /// Run CreateMulticoinPool through submit_vote_execute with the type enabled
    /// with `bits`.
    fun sve_create_multicoin_pool(bits: u64) {
        let mut scenario = ts::begin(OFFICER);
        let (ou_id, registry_id, policy_id, collection_id, cap) = start_pool_creation(
            &mut scenario,
            constants::pool_creation_fee(),
        );
        enable<CreateMulticoinPool<QUOTE>>(&mut scenario, ou_id, b"CreateMulticoinPool", bits);

        ts::next_tx(&mut scenario, OFFICER);
        let mut ou = ts::take_shared_by_id<OU>(&scenario, ou_id);
        let freeze = ts::take_shared<EmergencyFreeze>(&scenario);
        let mut registry = ts::take_shared_by_id<Registry>(&scenario, registry_id);
        let policy = ts::take_shared_by_id<FeePolicy>(&scenario, policy_id);
        let collection = ts::take_shared_by_id<Collection>(&scenario, collection_id);
        let mut treasury = ts::take_shared<TreasuryVault>(&scenario);
        let clock = clock::create_for_testing(scenario.ctx());

        let ticket = board_voting::submit_vote_execute(
            &mut ou,
            option::none(),
            create_multicoin_pool::new<QUOTE>(collection_id, ASSET),
            &freeze,
            &clock,
            scenario.ctx(),
        );
        trading_ops::execute_create_multicoin_pool(
            &mut registry,
            &policy,
            &collection,
            &mut treasury,
            ticket,
            scenario.ctx(),
        );
        assert!(treasury.balance<CRED>() == 0);

        clock.destroy_for_testing();
        ts::return_shared(ou);
        ts::return_shared(freeze);
        ts::return_shared(registry);
        ts::return_shared(policy);
        ts::return_shared(collection);
        ts::return_shared(treasury);
        destroy(cap);
        ts::end(scenario);
    }

    #[test]
    fun sve_create_multicoin_pool_ok() {
        sve_create_multicoin_pool(trading_permissions::create_multicoin_pool());
    }

    /// Without TREASURY_WITHDRAW the fee withdrawal is refused.
    #[test]
    #[expected_failure(abort_code = EPermissionDenied, location = armature::proposal)]
    fun sve_create_multicoin_pool_without_bits_aborts() {
        sve_create_multicoin_pool(trading_permissions::no_bits());
    }
}
