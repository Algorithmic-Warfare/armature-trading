#[test_only]
module armature_trading::submit_vote_execute_trading_tests;

use armature::board_voting;
use armature::capability_vault::CapabilityVault;
use armature::dao::{Self, DAO};
use armature::emergency::EmergencyFreeze;
use armature::governance;
use armature::proposal;
use armature::treasury_vault::TreasuryVault;
use multicoin::multicoin::{Self, Collection, CollectionCap};
use std::string;
use std::unit_test;
use sui::clock;
use sui::coin;
use sui::test_scenario::{Self as ts, Scenario};
use token::cred::CRED;
use triexbook::balance_manager::{Self, BalanceManager};
use triexbook::constants;
use triexbook::multicoin_pool::{Self, MultiCoinPool};
use triexbook::pool::{Self, Pool};
use triexbook::registry::{Self, Registry, TriexbookAdminCap};

use armature_trading::cancel_order;
use armature_trading::cancel_order_coin;
use armature_trading::create_multicoin_pool;
use armature_trading::deposit_coin_to_book;
use armature_trading::deposit_multicoin_to_book;
use armature_trading::place_limit_order;
use armature_trading::place_limit_order_coin;
use armature_trading::sweep_coin_to_treasury;
use armature_trading::sweep_multicoin_to_treasury;
use armature_trading::trading_ops;

// === Mock coin types ===
public struct BASE has drop {}
public struct QUOTE has drop {}

// === Constants ===
const ADMIN: address = @0xAD;
const ASSET_ID: u64 = 1;
const LARGE_EXPIRE: u64 = 1_000_000_000_000;

// ============================================================
// Helpers
// ============================================================

fun setup_dao(test: &mut Scenario): ID {
    test.next_tx(ADMIN);
    let gov_init = governance::init_board(vector[ADMIN]);
    dao::create(
        &gov_init,
        string::utf8(b"Trading DAO"),
        string::utf8(b"desc"),
        string::utf8(b"url"),
        test.ctx(),
    )
}

/// Enable a proposal type with zero execution delay so submit_vote_execute works.
fun enable_type_zero_delay(test: &mut Scenario, type_key: vector<u8>) {
    test.next_tx(ADMIN);
    let mut dao = test.take_shared<DAO>();
    // quorum=50%, threshold=50%, propose_threshold=0, expiry=1h, delay=0, cooldown=0
    let config = proposal::new_config(5_000, 5_000, 0, 3_600_000, 0, 0);
    dao.test_enable_type(type_key.to_ascii_string(), config);
    ts::return_shared(dao);
}

fun seed_trading_caps(cap_vault: &mut CapabilityVault, test: &mut Scenario): ID {
    let (bm, deposit_cap, withdraw_cap, trade_cap) =
        balance_manager::new_with_custom_owner_and_caps(ADMIN, test.ctx());
    let bm_id = object::id(&bm);
    cap_vault.store_cap_for_testing(deposit_cap);
    cap_vault.store_cap_for_testing(withdraw_cap);
    cap_vault.store_cap_for_testing(trade_cap);
    transfer::public_share_object(bm);
    bm_id
}

fun setup_registry(test: &mut Scenario): (ID, TriexbookAdminCap) {
    test.next_tx(ADMIN);
    let registry_id = registry::test_registry(test.ctx());
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    (registry_id, admin_cap)
}

fun create_coin_pool(registry_id: ID, admin_cap: &TriexbookAdminCap, test: &mut Scenario): ID {
    test.next_tx(ADMIN);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    registry.add_approved_quote_unchecked<QUOTE>(admin_cap);
    let fee = coin::mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx());
    let pool_id = pool::create_permissionless_pool<BASE, QUOTE>(&mut registry, fee, test.ctx());
    ts::return_shared(registry);
    pool_id
}

fun setup_collection(test: &mut Scenario): (ID, CollectionCap) {
    test.next_tx(ADMIN);
    let (collection, cap) = multicoin::new_collection(test.ctx());
    let collection_id = object::id(&collection);
    transfer::public_share_object(collection);
    (collection_id, cap)
}

fun create_multicoin_pool(
    registry_id: ID,
    admin_cap: &TriexbookAdminCap,
    collection_id: ID,
    asset_id: u64,
    test: &mut Scenario,
): ID {
    test.next_tx(ADMIN);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let collection = test.take_shared_by_id<Collection>(collection_id);
    registry.add_approved_quote_unchecked<QUOTE>(admin_cap);
    let fee = coin::mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx());
    let pool_id = multicoin_pool::create_permissionless_pool<QUOTE>(
        &mut registry,
        &collection,
        asset_id,
        fee,
        test.ctx(),
    );
    ts::return_shared(collection);
    ts::return_shared(registry);
    pool_id
}

// ============================================================
// Coin pool tests
// ============================================================

#[test]
fun test_sve_deposit_coin_to_book() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    enable_type_zero_delay(&mut test, b"DepositCoinToBook");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    let treasury_amount = 1_000_000_000u64;
    test.next_tx(ADMIN);
    {
        let mut treasury = test.take_shared<TreasuryVault>();
        treasury.deposit(coin::mint_for_testing<QUOTE>(treasury_amount, test.ctx()), test.ctx());
        ts::return_shared(treasury);
    };

    let deposit_amount = treasury_amount / 2;
    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut treasury = test.take_shared<TreasuryVault>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<deposit_coin_to_book::DepositCoinToBook<QUOTE>>(
            &mut dao,
            b"DepositCoinToBook".to_ascii_string(),
            option::none(),
            deposit_coin_to_book::new<QUOTE>(deposit_amount),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_deposit_coin_to_book<QUOTE>(
            &mut treasury, &mut bm, &cap_vault, ticket, test.ctx(),
        );

        assert!(bm.balance<QUOTE>() == deposit_amount);
        assert!(treasury.balance<QUOTE>() == treasury_amount - deposit_amount);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(treasury);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    ts::end(test);
}

#[test]
fun test_sve_sweep_coin_to_treasury() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    enable_type_zero_delay(&mut test, b"SweepCoinToTreasury");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    let bm_amount = 1_000_000_000u64;
    test.next_tx(ADMIN);
    {
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        bm.deposit(coin::mint_for_testing<QUOTE>(bm_amount, test.ctx()), test.ctx());
        ts::return_shared(bm);
    };

    let sweep_amount = 400_000_000u64;
    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut treasury = test.take_shared<TreasuryVault>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<sweep_coin_to_treasury::SweepCoinToTreasury<QUOTE>>(
            &mut dao,
            b"SweepCoinToTreasury".to_ascii_string(),
            option::none(),
            sweep_coin_to_treasury::new<QUOTE>(bm_id, sweep_amount),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_sweep_coin_to_treasury<QUOTE>(
            &mut treasury, &mut bm, &cap_vault, ticket, test.ctx(),
        );

        assert!(treasury.balance<QUOTE>() == sweep_amount);
        assert!(bm.balance<QUOTE>() == bm_amount - sweep_amount);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(treasury);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    ts::end(test);
}

#[test]
fun test_sve_place_limit_order_coin_pool() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (registry_id, admin_cap) = setup_registry(&mut test);
    let pool_id = create_coin_pool(registry_id, &admin_cap, &mut test);
    enable_type_zero_delay(&mut test, b"PlaceLimitOrderCoin");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    test.next_tx(ADMIN);
    {
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        bm.deposit(
            coin::mint_for_testing<QUOTE>(1_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        ts::return_shared(bm);
    };

    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<place_limit_order_coin::PlaceLimitOrderCoin<BASE, QUOTE>>(
            &mut dao,
            b"PlaceLimitOrderCoin".to_ascii_string(),
            option::none(),
            place_limit_order_coin::new<BASE, QUOTE>(
                bm_id,
                pool_id,
                constants::float_scaling(), // price: 1 QUOTE per BASE
                constants::float_scaling(), // quantity: 1 BASE
                true,                       // is_bid
                0,
                0,
                LARGE_EXPIRE,
            ),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_place_limit_order_coin<BASE, QUOTE>(
            &mut pool, &mut bm, &cap_vault, &clock, ticket, test.ctx(),
        );

        assert!(pool.account_open_orders(&bm).length() == 1);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(pool);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    unit_test::destroy(admin_cap);
    ts::end(test);
}

#[test]
fun test_sve_cancel_order_coin_pool() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (registry_id, admin_cap) = setup_registry(&mut test);
    let pool_id = create_coin_pool(registry_id, &admin_cap, &mut test);
    enable_type_zero_delay(&mut test, b"CancelOrderCoin");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    test.next_tx(ADMIN);
    {
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        bm.deposit(
            coin::mint_for_testing<QUOTE>(1_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        ts::return_shared(bm);
    };

    // Place an order directly as BM owner to get an order_id.
    let order_id: u64;
    test.next_tx(ADMIN);
    {
        let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let clock = clock::create_for_testing(test.ctx());
        let proof = bm.generate_proof_as_owner(test.ctx());
        let order_info = pool.place_limit_order<BASE, QUOTE>(
            &mut bm,
            &proof,
            0,
            0,
            constants::float_scaling(),
            constants::float_scaling(),
            true,
            LARGE_EXPIRE,
            &clock,
            test.ctx(),
        );
        order_id = order_info.order_id();
        clock.destroy_for_testing();
        ts::return_shared(bm);
        ts::return_shared(pool);
    };

    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<cancel_order_coin::CancelOrderCoin<BASE, QUOTE>>(
            &mut dao,
            b"CancelOrderCoin".to_ascii_string(),
            option::none(),
            cancel_order_coin::new<BASE, QUOTE>(bm_id, pool_id, order_id),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_cancel_order_coin<BASE, QUOTE>(
            &mut pool, &mut bm, &cap_vault, &clock, ticket, test.ctx(),
        );

        assert!(pool.account_open_orders(&bm).length() == 0);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(pool);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    unit_test::destroy(admin_cap);
    ts::end(test);
}

// ============================================================
// Multicoin pool tests
// ============================================================

#[test]
fun test_sve_deposit_multicoin_to_book() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (collection_id, collection_cap) = setup_collection(&mut test);
    enable_type_zero_delay(&mut test, b"DepositMulticoinToBook");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    let mint_amount = 100u64;
    test.next_tx(ADMIN);
    {
        let mut collection = test.take_shared_by_id<Collection>(collection_id);
        let mut treasury = test.take_shared<TreasuryVault>();
        let bal = multicoin::mint_balance(
            &collection_cap, &mut collection, ASSET_ID, mint_amount, test.ctx(),
        );
        treasury.deposit_multicoin(bal, test.ctx());
        ts::return_shared(treasury);
        ts::return_shared(collection);
    };

    let deposit_amount = 50u64;
    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut treasury = test.take_shared<TreasuryVault>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<deposit_multicoin_to_book::DepositMulticoinToBook>(
            &mut dao,
            b"DepositMulticoinToBook".to_ascii_string(),
            option::none(),
            deposit_multicoin_to_book::new(collection_id, ASSET_ID, deposit_amount),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_deposit_multicoin_to_book(
            &mut treasury, &mut bm, &cap_vault, ticket, test.ctx(),
        );

        assert!(bm.multicoin_balance(collection_id, ASSET_ID) == deposit_amount);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(treasury);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    unit_test::destroy(collection_cap);
    ts::end(test);
}

#[test]
fun test_sve_sweep_multicoin_to_treasury() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (collection_id, collection_cap) = setup_collection(&mut test);
    enable_type_zero_delay(&mut test, b"SweepMulticoinToTreasury");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    let bm_amount = 100u64;
    test.next_tx(ADMIN);
    {
        let mut collection = test.take_shared_by_id<Collection>(collection_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let bal = multicoin::mint_balance(
            &collection_cap, &mut collection, ASSET_ID, bm_amount, test.ctx(),
        );
        bm.deposit_multicoin(bal, test.ctx());
        ts::return_shared(bm);
        ts::return_shared(collection);
    };

    let sweep_amount = 60u64;
    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut treasury = test.take_shared<TreasuryVault>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<sweep_multicoin_to_treasury::SweepMulticoinToTreasury>(
            &mut dao,
            b"SweepMulticoinToTreasury".to_ascii_string(),
            option::none(),
            sweep_multicoin_to_treasury::new(bm_id, collection_id, ASSET_ID, sweep_amount),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_sweep_multicoin_to_treasury(
            &mut treasury, &mut bm, &cap_vault, ticket, test.ctx(),
        );

        assert!(bm.multicoin_balance(collection_id, ASSET_ID) == bm_amount - sweep_amount);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(treasury);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    unit_test::destroy(collection_cap);
    ts::end(test);
}

#[test]
fun test_sve_place_limit_order_multicoin_pool() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (registry_id, admin_cap) = setup_registry(&mut test);
    let (collection_id, collection_cap) = setup_collection(&mut test);
    let pool_id = create_multicoin_pool(registry_id, &admin_cap, collection_id, ASSET_ID, &mut test);
    enable_type_zero_delay(&mut test, b"PlaceLimitOrder");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    let mc_price = 100u64;
    let mc_qty = 10u64;

    test.next_tx(ADMIN);
    {
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        bm.deposit(coin::mint_for_testing<QUOTE>(1_000_000, test.ctx()), test.ctx());
        ts::return_shared(bm);
    };

    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut pool = test.take_shared_by_id<MultiCoinPool<QUOTE>>(pool_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<place_limit_order::PlaceLimitOrder<QUOTE>>(
            &mut dao,
            b"PlaceLimitOrder".to_ascii_string(),
            option::none(),
            place_limit_order::new<QUOTE>(
                bm_id,
                pool_id,
                mc_price,
                mc_qty,
                true, // is_bid
                0,
                0,
                LARGE_EXPIRE,
            ),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_place_limit_order<QUOTE>(
            &mut pool, &mut bm, &cap_vault, &clock, ticket, test.ctx(),
        );

        assert!(pool.account_open_orders(&bm).length() == 1);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(pool);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    unit_test::destroy(admin_cap);
    unit_test::destroy(collection_cap);
    ts::end(test);
}

#[test]
fun test_sve_cancel_order_multicoin_pool() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (registry_id, admin_cap) = setup_registry(&mut test);
    let (collection_id, collection_cap) = setup_collection(&mut test);
    let pool_id = create_multicoin_pool(registry_id, &admin_cap, collection_id, ASSET_ID, &mut test);
    enable_type_zero_delay(&mut test, b"CancelOrder");

    test.next_tx(ADMIN);
    let bm_id = {
        let mut cap_vault = test.take_shared<CapabilityVault>();
        let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
        ts::return_shared(cap_vault);
        bm_id
    };

    let mc_price = 100u64;
    let mc_qty = 10u64;

    test.next_tx(ADMIN);
    {
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        bm.deposit(coin::mint_for_testing<QUOTE>(1_000_000, test.ctx()), test.ctx());
        ts::return_shared(bm);
    };

    // Place an order directly as BM owner to get an order_id.
    let order_id: u64;
    test.next_tx(ADMIN);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<QUOTE>>(pool_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let clock = clock::create_for_testing(test.ctx());
        let proof = bm.generate_proof_as_owner(test.ctx());
        let order_info = pool.place_limit_order<QUOTE>(
            &mut bm,
            &proof,
            0,
            0,
            mc_price,
            mc_qty,
            true,
            LARGE_EXPIRE,
            &clock,
            test.ctx(),
        );
        order_id = order_info.order_id();
        clock.destroy_for_testing();
        ts::return_shared(bm);
        ts::return_shared(pool);
    };

    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut pool = test.take_shared_by_id<MultiCoinPool<QUOTE>>(pool_id);
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let cap_vault = test.take_shared<CapabilityVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<cancel_order::CancelOrder<QUOTE>>(
            &mut dao,
            b"CancelOrder".to_ascii_string(),
            option::none(),
            cancel_order::new<QUOTE>(bm_id, pool_id, order_id),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_cancel_order<QUOTE>(
            &mut pool, &mut bm, &cap_vault, &clock, ticket, test.ctx(),
        );

        assert!(pool.account_open_orders(&bm).length() == 0);

        clock.destroy_for_testing();
        ts::return_shared(cap_vault);
        ts::return_shared(bm);
        ts::return_shared(pool);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    unit_test::destroy(admin_cap);
    unit_test::destroy(collection_cap);
    ts::end(test);
}

#[test]
fun test_sve_create_multicoin_pool() {
    let mut test = ts::begin(ADMIN);
    let _dao_id = setup_dao(&mut test);
    let (registry_id, admin_cap) = setup_registry(&mut test);
    let (collection_id, collection_cap) = setup_collection(&mut test);

    // Approve QUOTE for pool creation.
    test.next_tx(ADMIN);
    {
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        registry.add_approved_quote_unchecked<QUOTE>(&admin_cap);
        ts::return_shared(registry);
    };

    enable_type_zero_delay(&mut test, b"CreateMulticoinPool");

    // Fund the treasury with the creation fee.
    test.next_tx(ADMIN);
    {
        let mut treasury = test.take_shared<TreasuryVault>();
        treasury.deposit(
            coin::mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );
        ts::return_shared(treasury);
    };

    test.next_tx(ADMIN);
    {
        let mut dao = test.take_shared<DAO>();
        let freeze = test.take_shared<EmergencyFreeze>();
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let collection = test.take_shared_by_id<Collection>(collection_id);
        let mut treasury = test.take_shared<TreasuryVault>();
        let clock = clock::create_for_testing(test.ctx());

        let ticket = board_voting::submit_vote_execute<create_multicoin_pool::CreateMulticoinPool<QUOTE>>(
            &mut dao,
            b"CreateMulticoinPool".to_ascii_string(),
            option::none(),
            create_multicoin_pool::new<QUOTE>(collection_id, ASSET_ID),
            &freeze,
            &clock,
            test.ctx(),
        );
        trading_ops::execute_create_multicoin_pool<QUOTE>(
            &mut registry, &collection, &mut treasury, ticket, test.ctx(),
        );

        assert!(treasury.balance<CRED>() == 0);

        clock.destroy_for_testing();
        ts::return_shared(treasury);
        ts::return_shared(collection);
        ts::return_shared(registry);
        ts::return_shared(freeze);
        ts::return_shared(dao);
    };

    // Pool is now live as a shared object.
    test.next_tx(ADMIN);
    {
        let pool = test.take_shared<MultiCoinPool<QUOTE>>();
        ts::return_shared(pool);
    };

    unit_test::destroy(admin_cap);
    unit_test::destroy(collection_cap);
    ts::end(test);
}
