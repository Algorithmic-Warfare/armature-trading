#[test_only]
module armature_trading::trading_ops_tests {
    use armature::{
        capability_vault::CapabilityVault,
        dao,
        governance,
        proposal,
        treasury_vault::TreasuryVault
    };
    use armature_trading::{
        cancel_order,
        cancel_order_coin,
        create_multicoin_pool,
        deposit_coin_to_book,
        deposit_multicoin_to_book,
        place_limit_order,
        place_limit_order_coin,
        setup_trading_account,
        sweep_coin_to_treasury,
        sweep_multicoin_to_treasury,
        trading_ops
    };
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::{string, unit_test};
    use sui::{clock, coin, test_scenario::{Self as ts, Scenario}};
    use token::cred::CRED;
    use triexbook::{
        balance_manager::{Self, BalanceManager, DepositCap, TradeCap, WithdrawCap},
        constants,
        multicoin_pool::{Self, MultiCoinPool},
        pool::{Self, Pool},
        registry::{Self, Registry, TriexbookAdminCap}
    };

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

    /// Creates a DAO; all companion objects are shared. Returns dao_id.
    fun setup_dao(test: &mut Scenario): ID {
        test.next_tx(ADMIN);
        let gov_init = governance::init_board(vector[ADMIN]);
        dao::create(
            &gov_init,
            string::utf8(b"Test DAO"),
            string::utf8(b"desc"),
            string::utf8(b"url"),
            test.ctx(),
        )
    }

    /// Creates a BalanceManager (owner = ADMIN) with all three trading caps.
    /// Stores the caps in `cap_vault` using the test-only bypass, shares the BM.
    /// Returns the BM's ID.
    fun seed_trading_caps(cap_vault: &mut CapabilityVault, test: &mut Scenario): ID {
        let (
            bm,
            deposit_cap,
            withdraw_cap,
            trade_cap,
        ) = balance_manager::new_with_custom_owner_and_caps(ADMIN, test.ctx());
        let bm_id = object::id(&bm);
        cap_vault.store_cap_for_testing(deposit_cap);
        cap_vault.store_cap_for_testing(withdraw_cap);
        cap_vault.store_cap_for_testing(trade_cap);
        transfer::public_share_object(bm);
        bm_id
    }

    /// Wraps a payload in a standalone ExecutionTicket with a dummy proposal ID.
    fun make_ticket<P: store>(dao_id: ID, payload: P): proposal::ExecutionTicket<P> {
        proposal::new_standalone_ticket_for_testing(
            dao_id,
            object::id_from_address(@0xBEEF),
            payload,
            1,
            1,
        )
    }

    /// Creates a test Registry. Returns (registry_id, admin_cap).
    fun setup_registry(test: &mut Scenario): (ID, TriexbookAdminCap) {
        test.next_tx(ADMIN);
        let registry_id = registry::test_registry(test.ctx());
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        (registry_id, admin_cap)
    }

    /// Approves QUOTE in the registry and creates a Pool<BASE, QUOTE>. Returns pool_id.
    fun create_coin_pool(registry_id: ID, admin_cap: &TriexbookAdminCap, test: &mut Scenario): ID {
        test.next_tx(ADMIN);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        registry.add_approved_quote_unchecked<QUOTE>(admin_cap);
        let fee = coin::mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx());
        let pool_id = pool::create_permissionless_pool<BASE, QUOTE>(&mut registry, fee, test.ctx());
        ts::return_shared(registry);
        pool_id
    }

    /// Creates a multicoin Collection. Returns (collection_id, CollectionCap).
    fun setup_collection(test: &mut Scenario): (ID, CollectionCap) {
        test.next_tx(ADMIN);
        let (collection, cap) = multicoin::new_collection(test.ctx());
        let collection_id = object::id(&collection);
        transfer::public_share_object(collection);
        (collection_id, cap)
    }

    /// Approves QUOTE and creates a MultiCoinPool<QUOTE> for the given collection/asset.
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
    // Tests
    // ============================================================

    #[test]
    fun test_setup_trading_account() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);

        // Execute the proposal handler.
        test.next_tx(ADMIN);
        {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let ticket = make_ticket(dao_id, setup_trading_account::new());
            trading_ops::execute_setup_trading_account(&mut cap_vault, ticket, test.ctx());
            assert!(cap_vault.ids_for_type<DepositCap>().length() == 1);
            assert!(cap_vault.ids_for_type<WithdrawCap>().length() == 1);
            assert!(cap_vault.ids_for_type<TradeCap>().length() == 1);
            ts::return_shared(cap_vault);
        };

        // The BalanceManager created during setup is now a shared object.
        test.next_tx(ADMIN);
        {
            let bm = test.take_shared<BalanceManager>();
            assert!(bm.owner() == dao_id.to_address());
            ts::return_shared(bm);
        };

        ts::end(test);
    }

    #[test]
    fun test_deposit_coin_to_book() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);

        // Seed vault with caps and share a funded BalanceManager.
        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Fund the treasury.
        let treasury_amount = 1_000_000_000u64;
        test.next_tx(ADMIN);
        {
            let mut treasury = test.take_shared<TreasuryVault>();
            treasury.deposit(
                coin::mint_for_testing<QUOTE>(treasury_amount, test.ctx()),
                test.ctx(),
            );
            ts::return_shared(treasury);
        };

        // Move half the treasury balance into the book.
        let deposit_amount = treasury_amount / 2;
        test.next_tx(ADMIN);
        {
            let mut treasury = test.take_shared<TreasuryVault>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let ticket = make_ticket(dao_id, deposit_coin_to_book::new<QUOTE>(deposit_amount));
            trading_ops::execute_deposit_coin_to_book<QUOTE>(
                &mut treasury,
                &mut bm,
                &cap_vault,
                ticket,
                test.ctx(),
            );
            assert!(bm.balance<QUOTE>() == deposit_amount);
            assert!(treasury.balance<QUOTE>() == treasury_amount - deposit_amount);
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(treasury);
        };

        ts::end(test);
    }

    #[test]
    fun test_sweep_coin_to_treasury() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Pre-fund the balance manager directly.
        let bm_amount = 1_000_000_000u64;
        test.next_tx(ADMIN);
        {
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            bm.deposit(coin::mint_for_testing<QUOTE>(bm_amount, test.ctx()), test.ctx());
            ts::return_shared(bm);
        };

        // Sweep part of the balance back to the treasury.
        let sweep_amount = 400_000_000u64;
        test.next_tx(ADMIN);
        {
            let mut treasury = test.take_shared<TreasuryVault>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let ticket = make_ticket(
                dao_id,
                sweep_coin_to_treasury::new<QUOTE>(bm_id, sweep_amount),
            );
            trading_ops::execute_sweep_coin_to_treasury<QUOTE>(
                &mut treasury,
                &mut bm,
                &cap_vault,
                ticket,
                test.ctx(),
            );
            assert!(treasury.balance<QUOTE>() == sweep_amount);
            assert!(bm.balance<QUOTE>() == bm_amount - sweep_amount);
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(treasury);
        };

        ts::end(test);
    }

    #[test]
    fun test_deposit_multicoin_to_book() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (collection_id, collection_cap) = setup_collection(&mut test);

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Mint multicoin items and deposit them into the treasury.
        let mint_amount = 100u64;
        test.next_tx(ADMIN);
        {
            let mut collection = test.take_shared_by_id<Collection>(collection_id);
            let mut treasury = test.take_shared<TreasuryVault>();
            let bal = multicoin::mint_balance(
                &collection_cap,
                &mut collection,
                ASSET_ID,
                mint_amount,
                test.ctx(),
            );
            treasury.deposit_multicoin(bal, test.ctx());
            ts::return_shared(treasury);
            ts::return_shared(collection);
        };

        // Move 50 items from treasury into the book.
        let deposit_amount = 50u64;
        test.next_tx(ADMIN);
        {
            let mut treasury = test.take_shared<TreasuryVault>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let ticket = make_ticket(
                dao_id,
                deposit_multicoin_to_book::new(collection_id, ASSET_ID, deposit_amount),
            );
            trading_ops::execute_deposit_multicoin_to_book(
                &mut treasury,
                &mut bm,
                &cap_vault,
                ticket,
                test.ctx(),
            );
            assert!(bm.multicoin_balance(collection_id, ASSET_ID) == deposit_amount);
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(treasury);
        };

        unit_test::destroy(collection_cap);
        ts::end(test);
    }

    #[test]
    fun test_sweep_multicoin_to_treasury() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (collection_id, collection_cap) = setup_collection(&mut test);

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Mint multicoin items and deposit directly into the balance manager.
        let bm_amount = 100u64;
        test.next_tx(ADMIN);
        {
            let mut collection = test.take_shared_by_id<Collection>(collection_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let bal = multicoin::mint_balance(
                &collection_cap,
                &mut collection,
                ASSET_ID,
                bm_amount,
                test.ctx(),
            );
            bm.deposit_multicoin(bal, test.ctx());
            ts::return_shared(bm);
            ts::return_shared(collection);
        };

        // Sweep part of the items back to the treasury.
        let sweep_amount = 60u64;
        test.next_tx(ADMIN);
        {
            let mut treasury = test.take_shared<TreasuryVault>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let ticket = make_ticket(
                dao_id,
                sweep_multicoin_to_treasury::new(bm_id, collection_id, ASSET_ID, sweep_amount),
            );
            trading_ops::execute_sweep_multicoin_to_treasury(
                &mut treasury,
                &mut bm,
                &cap_vault,
                ticket,
                test.ctx(),
            );
            assert!(bm.multicoin_balance(collection_id, ASSET_ID) == bm_amount - sweep_amount);
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(treasury);
        };

        unit_test::destroy(collection_cap);
        ts::end(test);
    }

    #[test]
    fun test_place_limit_order_coin_pool() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let pool_id = create_coin_pool(registry_id, &admin_cap, &mut test);

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Fund balance manager with QUOTE for a bid order.
        test.next_tx(ADMIN);
        {
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            bm.deposit(
                coin::mint_for_testing<QUOTE>(1_000 * constants::float_scaling(), test.ctx()),
                test.ctx(),
            );
            ts::return_shared(bm);
        };

        // Place a bid limit order via the governance handler.
        test.next_tx(ADMIN);
        {
            let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let clock = clock::create_for_testing(test.ctx());
            let ticket = make_ticket(
                dao_id,
                place_limit_order_coin::new<BASE, QUOTE>(
                    bm_id,
                    pool_id,
                    constants::float_scaling(), // price: 1 QUOTE per BASE
                    constants::float_scaling(), // quantity: 1 BASE
                    true, // is_bid
                    0, // order_type: no restriction
                    0, // self_matching: allowed
                    LARGE_EXPIRE,
                ),
            );
            trading_ops::execute_place_limit_order_coin<BASE, QUOTE>(
                &mut pool,
                &mut bm,
                &cap_vault,
                &clock,
                ticket,
                test.ctx(),
            );
            assert!(pool.account_open_orders(&bm).length() == 1);
            clock.destroy_for_testing();
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        ts::end(test);
    }

    #[test]
    fun test_cancel_order_coin_pool() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let pool_id = create_coin_pool(registry_id, &admin_cap, &mut test);

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

        // Place an order as BM owner to obtain its order_id.
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
                0, // no restriction
                0, // self_matching allowed
                constants::float_scaling(),
                constants::float_scaling(),
                true, // bid
                LARGE_EXPIRE,
                &clock,
                test.ctx(),
            );
            order_id = order_info.order_id();
            assert!(pool.account_open_orders(&bm).length() == 1);
            clock.destroy_for_testing();
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        // Cancel via the governance handler.
        test.next_tx(ADMIN);
        {
            let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let clock = clock::create_for_testing(test.ctx());
            let ticket = make_ticket(
                dao_id,
                cancel_order_coin::new<BASE, QUOTE>(bm_id, pool_id, order_id),
            );
            trading_ops::execute_cancel_order_coin<BASE, QUOTE>(
                &mut pool,
                &mut bm,
                &cap_vault,
                &clock,
                ticket,
                test.ctx(),
            );
            assert!(pool.account_open_orders(&bm).length() == 0);
            clock.destroy_for_testing();
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        ts::end(test);
    }

    #[test]
    fun test_place_limit_order_multicoin_pool() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let pool_id = create_multicoin_pool(
            registry_id,
            &admin_cap,
            collection_id,
            ASSET_ID,
            &mut test,
        );

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // MultiCoin pools use price_scaling = 1 (raw units, not float_scaled).
        // locked_quote = price * quantity, so keep both small.
        let mc_price = 100u64;
        let mc_qty = 10u64;

        // Fund balance manager with QUOTE for a bid (buying items with QUOTE).
        test.next_tx(ADMIN);
        {
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            bm.deposit(
                coin::mint_for_testing<QUOTE>(1_000_000, test.ctx()),
                test.ctx(),
            );
            ts::return_shared(bm);
        };

        // Place a bid via the governance handler.
        test.next_tx(ADMIN);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<QUOTE>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let clock = clock::create_for_testing(test.ctx());
            let ticket = make_ticket(
                dao_id,
                place_limit_order::new<QUOTE>(
                    bm_id,
                    pool_id,
                    mc_price, // raw price (price_scaling = 1 for multicoin)
                    mc_qty, // raw quantity
                    true, // is_bid
                    0, // no restriction
                    0, // self_matching allowed
                    LARGE_EXPIRE,
                ),
            );
            trading_ops::execute_place_limit_order<QUOTE>(
                &mut pool,
                &mut bm,
                &cap_vault,
                &clock,
                ticket,
                test.ctx(),
            );
            assert!(pool.account_open_orders(&bm).length() == 1);
            clock.destroy_for_testing();
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        unit_test::destroy(collection_cap);
        ts::end(test);
    }

    #[test]
    fun test_cancel_order_multicoin_pool() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let pool_id = create_multicoin_pool(
            registry_id,
            &admin_cap,
            collection_id,
            ASSET_ID,
            &mut test,
        );

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // MultiCoin pools use price_scaling = 1 (raw units, not float_scaled).
        let mc_price = 100u64;
        let mc_qty = 10u64;

        test.next_tx(ADMIN);
        {
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            bm.deposit(
                coin::mint_for_testing<QUOTE>(1_000_000, test.ctx()),
                test.ctx(),
            );
            ts::return_shared(bm);
        };

        // Place an order as BM owner to obtain its order_id.
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
            assert!(pool.account_open_orders(&bm).length() == 1);
            clock.destroy_for_testing();
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        // Cancel via the governance handler.
        test.next_tx(ADMIN);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<QUOTE>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let clock = clock::create_for_testing(test.ctx());
            let ticket = make_ticket(
                dao_id,
                cancel_order::new<QUOTE>(bm_id, pool_id, order_id),
            );
            trading_ops::execute_cancel_order<QUOTE>(
                &mut pool,
                &mut bm,
                &cap_vault,
                &clock,
                ticket,
                test.ctx(),
            );
            assert!(pool.account_open_orders(&bm).length() == 0);
            clock.destroy_for_testing();
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        unit_test::destroy(collection_cap);
        ts::end(test);
    }

    // ============================================================
    // Negative tests — wrong-object assertions
    // ============================================================

    #[test]
    #[expected_failure(abort_code = 2, location = armature_trading::trading_ops)]
    fun test_wrong_collection_aborts() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        // Two distinct collections: payload names A, executor receives B.
        let (collection_id_a, collection_cap_a) = setup_collection(&mut test);
        let (collection_id_b, collection_cap_b) = setup_collection(&mut test);

        test.next_tx(ADMIN);
        {
            let mut registry = test.take_shared_by_id<Registry>(registry_id);
            registry.add_approved_quote_unchecked<QUOTE>(&admin_cap);
            ts::return_shared(registry);
        };

        test.next_tx(ADMIN);
        {
            let mut registry = test.take_shared_by_id<Registry>(registry_id);
            let collection_b = test.take_shared_by_id<Collection>(collection_id_b);
            let mut treasury = test.take_shared<TreasuryVault>();
            let ticket = make_ticket(dao_id, create_multicoin_pool::new<QUOTE>(collection_id_a, ASSET_ID));
            trading_ops::execute_create_multicoin_pool<QUOTE>(
                &mut registry,
                &collection_b,
                &mut treasury,
                ticket,
                test.ctx(),
            );
            // Unreachable — satisfy the compiler's resource analysis.
            ts::return_shared(treasury);
            ts::return_shared(collection_b);
            ts::return_shared(registry);
        };

        unit_test::destroy(admin_cap);
        unit_test::destroy(collection_cap_a);
        unit_test::destroy(collection_cap_b);
        ts::end(test);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = armature_trading::trading_ops)]
    fun test_wrong_pool_aborts_place_limit_order_coin() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let pool_id = create_coin_pool(registry_id, &admin_cap, &mut test);

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Payload carries the correct bm_id but a wrong pool_id → EWrongPool.
        test.next_tx(ADMIN);
        {
            let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let clock = clock::create_for_testing(test.ctx());
            let wrong_pool_id = object::id_from_address(@0xBAD);
            let ticket = make_ticket(
                dao_id,
                place_limit_order_coin::new<BASE, QUOTE>(
                    bm_id,
                    wrong_pool_id,
                    constants::float_scaling(),
                    constants::float_scaling(),
                    true,
                    0,
                    0,
                    LARGE_EXPIRE,
                ),
            );
            trading_ops::execute_place_limit_order_coin<BASE, QUOTE>(
                &mut pool,
                &mut bm,
                &cap_vault,
                &clock,
                ticket,
                test.ctx(),
            );
            // Unreachable — satisfy the compiler's resource analysis.
            clock.destroy_for_testing();
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        ts::end(test);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = armature_trading::trading_ops)]
    fun test_wrong_pool_aborts_cancel_order_coin() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let pool_id = create_coin_pool(registry_id, &admin_cap, &mut test);

        test.next_tx(ADMIN);
        let bm_id = {
            let mut cap_vault = test.take_shared<CapabilityVault>();
            let bm_id = seed_trading_caps(&mut cap_vault, &mut test);
            ts::return_shared(cap_vault);
            bm_id
        };

        // Payload carries the correct bm_id but a wrong pool_id → EWrongPool.
        test.next_tx(ADMIN);
        {
            let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
            let cap_vault = test.take_shared<CapabilityVault>();
            let clock = clock::create_for_testing(test.ctx());
            let wrong_pool_id = object::id_from_address(@0xBAD);
            let ticket = make_ticket(
                dao_id,
                cancel_order_coin::new<BASE, QUOTE>(bm_id, wrong_pool_id, 0),
            );
            trading_ops::execute_cancel_order_coin<BASE, QUOTE>(
                &mut pool,
                &mut bm,
                &cap_vault,
                &clock,
                ticket,
                test.ctx(),
            );
            // Unreachable — satisfy the compiler's resource analysis.
            clock.destroy_for_testing();
            ts::return_shared(cap_vault);
            ts::return_shared(bm);
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        ts::end(test);
    }

    #[test]
    fun test_create_multicoin_pool() {
        let mut test = ts::begin(ADMIN);
        let dao_id = setup_dao(&mut test);
        let (registry_id, admin_cap) = setup_registry(&mut test);
        let (collection_id, collection_cap) = setup_collection(&mut test);

        // Approve QUOTE so the pool creation succeeds.
        test.next_tx(ADMIN);
        {
            let mut registry = test.take_shared_by_id<Registry>(registry_id);
            registry.add_approved_quote_unchecked<QUOTE>(&admin_cap);
            ts::return_shared(registry);
        };

        // Fund the treasury with enough CRED to cover the creation fee.
        test.next_tx(ADMIN);
        {
            let mut treasury = test.take_shared<TreasuryVault>();
            treasury.deposit(
                coin::mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
                test.ctx(),
            );
            ts::return_shared(treasury);
        };

        // Execute the proposal handler.
        test.next_tx(ADMIN);
        {
            let mut registry = test.take_shared_by_id<Registry>(registry_id);
            let collection = test.take_shared_by_id<Collection>(collection_id);
            let mut treasury = test.take_shared<TreasuryVault>();
            let ticket = make_ticket(
                dao_id,
                create_multicoin_pool::new<QUOTE>(collection_id, ASSET_ID),
            );
            trading_ops::execute_create_multicoin_pool<QUOTE>(
                &mut registry,
                &collection,
                &mut treasury,
                ticket,
                test.ctx(),
            );
            // Treasury CRED should now be zero (paid as creation fee).
            assert!(treasury.balance<CRED>() == 0);
            ts::return_shared(treasury);
            ts::return_shared(collection);
            ts::return_shared(registry);
        };

        // The pool is now a shared object.
        test.next_tx(ADMIN);
        {
            let pool = test.take_shared<triexbook::multicoin_pool::MultiCoinPool<QUOTE>>();
            ts::return_shared(pool);
        };

        unit_test::destroy(admin_cap);
        unit_test::destroy(collection_cap);
        ts::end(test);
    }
}
