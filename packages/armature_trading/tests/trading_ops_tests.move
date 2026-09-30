/// Tests for the `trading_ops` deposit and sweep handlers, run against a real
/// OU, a TradingCustody and an OuReceiptVault gated on the OU. The
/// order handlers need a registered pool and FeePolicy and are not covered here.
#[test_only]
module armature_trading::trading_ops_tests {
    use armature::{ou::OU, treasury_vault::TreasuryVault};
    use armature_trading::{
        deposit_coin_to_book,
        deposit_from_ou_vault_to_book,
        sweep_coin_to_treasury,
        sweep_multicoin_to_ou_vault,
        trading_custody::TradingCustody,
        trading_ops,
        trading_test_utils as utils
    };
    use armature_vault::{
        acl::{Self as acl, Principal},
        ou_receipt_vault::{Self as vault, OuReceiptVault, Role}
    };
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use sui::{coin, sui::SUI, test_scenario as ts, vec_map};
    use triex::trading_account::TradingAccount;

    const OFFICER: address = @0xD1;
    const ASSET: u64 = 7;
    const OTHER_OU: address = @0x0B0B;

    // Abort codes in armature_trading::trading_ops.
    const EWrongTradingAccount: u64 = 0;
    const EWrongCustody: u64 = 1;
    const EWrongVault: u64 = 2;
    const EWrongOu: u64 = 4;
    const EWrongTreasury: u64 = 5;

    /// An OU (sole member OFFICER) with 100 SUI in its treasury, a TradingCustody,
    /// and an OuReceiptVault holding 100 of ASSET whose
    /// roles are all the OU. Leaves the scenario in an OFFICER transaction.
    fun start(
        scenario: &mut ts::Scenario,
    ): (OU, TreasuryVault, TradingCustody, TradingAccount, OuReceiptVault, ID) {
        let ou_id = utils::make_ou(scenario, OFFICER, vector[OFFICER]);
        let collection_id = utils::make_collection(scenario, OFFICER);
        let (custody, account) = utils::setup(scenario, OFFICER, ou_id);
        ts::return_shared(custody);
        ts::return_shared(account);

        ts::next_tx(scenario, OFFICER);
        let ou = ts::take_shared_by_id<OU>(scenario, ou_id);
        let mut treasury = ts::take_shared<TreasuryVault>(scenario);
        treasury.deposit(coin::mint_for_testing<SUI>(100, scenario.ctx()), scenario.ctx());

        let principals = vector[acl::ou(ou_id)];
        let mut acl_map = vec_map::empty<Role, vector<Principal>>();
        acl_map.insert(vault::role_deposit(), principals);
        acl_map.insert(vault::role_withdraw(), principals);
        acl_map.insert(vault::role_edit(), principals);
        let mut rv = vault::new_for_testing(
            object::id_from_address(@0x5501),
            collection_id,
            acl_map,
            scenario.ctx(),
        );

        let mut collection = ts::take_shared_by_id<Collection>(scenario, collection_id);
        let cap = ts::take_from_sender<CollectionCap>(scenario);
        let bal = multicoin::mint_balance(&cap, &mut collection, ASSET, 100, scenario.ctx());
        rv.deposit_receipt(&ou, bal, scenario.ctx());
        ts::return_to_sender(scenario, cap);
        ts::return_shared(collection);

        let custody = ts::take_shared<TradingCustody>(scenario);
        let account = ts::take_shared_by_id<TradingAccount>(
            scenario,
            custody.trading_account_id(),
        );
        (ou, treasury, custody, account, rv, collection_id)
    }

    fun finish(
        ou: OU,
        treasury: TreasuryVault,
        custody: TradingCustody,
        account: TradingAccount,
        rv: OuReceiptVault,
        scenario: ts::Scenario,
    ) {
        ts::return_shared(ou);
        ts::return_shared(treasury);
        ts::return_shared(custody);
        ts::return_shared(account);
        vault::share_for_testing(rv);
        ts::end(scenario);
    }

    // === multicoin: OuReceiptVault <-> TradingAccount ===

    /// 60 of 100 moved vault -> account, then 25 swept back.
    #[test]
    fun vault_to_book_and_back_ok() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, treasury, custody, mut account, mut rv, collection_id) = start(&mut scenario);
        let ou_id = ou.id();
        let account_id = object::id(&account);
        let rv_id = object::id(&rv);

        trading_ops::execute_deposit_from_ou_vault_to_book(
            &mut rv,
            &ou,
            &custody,
            &mut account,
            utils::ticket(ou_id, deposit_from_ou_vault_to_book::new(rv_id, account_id, ASSET, 60)),
            scenario.ctx(),
        );
        assert!(rv.vault_balance(ASSET) == 40);
        assert!(account.multicoin_balance(collection_id, ASSET) == 60);

        trading_ops::execute_sweep_multicoin_to_ou_vault(
            &mut rv,
            &ou,
            &custody,
            &mut account,
            utils::ticket(
                ou_id,
                sweep_multicoin_to_ou_vault::new(account_id, rv_id, collection_id, ASSET, 25),
            ),
            scenario.ctx(),
        );
        assert!(rv.vault_balance(ASSET) == 65);
        assert!(account.multicoin_balance(collection_id, ASSET) == 35);

        finish(ou, treasury, custody, account, rv, scenario);
    }

    #[test]
    #[expected_failure(abort_code = EWrongVault, location = armature_trading::trading_ops)]
    fun deposit_from_wrong_vault_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, treasury, custody, mut account, mut rv, _) = start(&mut scenario);
        let ou_id = ou.id();
        let account_id = object::id(&account);

        trading_ops::execute_deposit_from_ou_vault_to_book(
            &mut rv,
            &ou,
            &custody,
            &mut account,
            utils::ticket(
                ou_id,
                deposit_from_ou_vault_to_book::new(
                    object::id_from_address(@0xDEAD),
                    account_id,
                    ASSET,
                    60,
                ),
            ),
            scenario.ctx(),
        );
        finish(ou, treasury, custody, account, rv, scenario);
    }

    /// The `&OU` witness must be the ticket's OU.
    #[test]
    #[expected_failure(abort_code = EWrongOu, location = armature_trading::trading_ops)]
    fun deposit_from_vault_with_other_ou_ticket_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, treasury, custody, mut account, mut rv, _) = start(&mut scenario);
        let account_id = object::id(&account);
        let rv_id = object::id(&rv);

        trading_ops::execute_deposit_from_ou_vault_to_book(
            &mut rv,
            &ou,
            &custody,
            &mut account,
            utils::ticket(
                object::id_from_address(OTHER_OU),
                deposit_from_ou_vault_to_book::new(rv_id, account_id, ASSET, 60),
            ),
            scenario.ctx(),
        );
        finish(ou, treasury, custody, account, rv, scenario);
    }

    #[test]
    #[expected_failure(abort_code = EWrongTradingAccount, location = armature_trading::trading_ops)]
    fun sweep_wrong_account_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, treasury, custody, mut account, mut rv, collection_id) = start(&mut scenario);
        let ou_id = ou.id();
        let rv_id = object::id(&rv);

        trading_ops::execute_sweep_multicoin_to_ou_vault(
            &mut rv,
            &ou,
            &custody,
            &mut account,
            utils::ticket(
                ou_id,
                sweep_multicoin_to_ou_vault::new(
                    object::id_from_address(@0xDEAD),
                    rv_id,
                    collection_id,
                    ASSET,
                    1,
                ),
            ),
            scenario.ctx(),
        );
        finish(ou, treasury, custody, account, rv, scenario);
    }

    // === coin: TreasuryVault <-> TradingAccount ===

    /// 70 of 100 SUI moved treasury -> account, then 20 swept back.
    #[test]
    fun treasury_to_book_and_back_ok() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, mut treasury, custody, mut account, rv, _) = start(&mut scenario);
        let ou_id = ou.id();
        let account_id = object::id(&account);

        trading_ops::execute_deposit_coin_to_book(
            &mut treasury,
            &custody,
            &mut account,
            utils::ticket(ou_id, deposit_coin_to_book::new<SUI>(account_id, 70)),
            scenario.ctx(),
        );
        assert!(treasury.balance<SUI>() == 30);
        assert!(account.balance<SUI>() == 70);

        trading_ops::execute_sweep_coin_to_treasury(
            &mut treasury,
            &custody,
            &mut account,
            utils::ticket(ou_id, sweep_coin_to_treasury::new<SUI>(account_id, 20)),
            scenario.ctx(),
        );
        assert!(treasury.balance<SUI>() == 50);
        assert!(account.balance<SUI>() == 50);

        finish(ou, treasury, custody, account, rv, scenario);
    }

    /// A custody belonging to another OU cannot serve this ticket.
    #[test]
    #[expected_failure(abort_code = EWrongCustody, location = armature_trading::trading_ops)]
    fun deposit_coin_with_other_ou_ticket_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, mut treasury, custody, mut account, rv, _) = start(&mut scenario);
        let account_id = object::id(&account);

        trading_ops::execute_deposit_coin_to_book(
            &mut treasury,
            &custody,
            &mut account,
            utils::ticket(
                object::id_from_address(OTHER_OU),
                deposit_coin_to_book::new<SUI>(account_id, 70),
            ),
            scenario.ctx(),
        );
        finish(ou, treasury, custody, account, rv, scenario);
    }

    /// Sweeps only land in the ticket's own OU treasury.
    #[test]
    #[expected_failure(abort_code = EWrongTreasury, location = armature_trading::trading_ops)]
    fun sweep_coin_to_other_ou_treasury_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let (ou, mut treasury, custody, mut account, rv, _) = start(&mut scenario);
        let account_id = object::id(&account);

        trading_ops::execute_sweep_coin_to_treasury(
            &mut treasury,
            &custody,
            &mut account,
            utils::ticket(
                object::id_from_address(OTHER_OU),
                sweep_coin_to_treasury::new<SUI>(account_id, 0),
            ),
            scenario.ctx(),
        );
        finish(ou, treasury, custody, account, rv, scenario);
    }
}
