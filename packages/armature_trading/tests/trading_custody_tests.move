/// Tests for SetupTradingAccount and `trading_custody::claim_caps`: the custody
/// owns the new TradingAccount, receives its caps, and refuses caps minted for
/// any other account.
#[test_only]
module armature_trading::trading_custody_tests {
    use armature_trading::{trading_custody::TradingCustody, trading_test_utils as utils};
    use sui::{sui::SUI, test_scenario as ts};
    use triex::trading_account::{Self, TradingAccount};

    const OFFICER: address = @0xD1;
    const GRIEFER: address = @0xBAD;

    // Abort codes in armature_trading::trading_custody.
    const EWrongTradingAccount: u64 = 0;
    const ECapsAlreadyClaimed: u64 = 1;
    // triex::trading_account::EInvalidTrader: a cap not on the account's allow-list.
    const EInvalidTrader: u64 = 1;

    /// As GRIEFER, share a TradingAccount owned by the custody's address, as
    /// anyone can: triex sends its caps to the custody. Returns the account id.
    fun send_foreign_caps(scenario: &mut ts::Scenario, custody_id: ID): ID {
        ts::next_tx(scenario, GRIEFER);
        let foreign = trading_account::new_with_custom_owner_and_caps(
            custody_id.to_address(),
            scenario.ctx(),
        );
        let foreign_id = object::id(&foreign);
        transfer::public_share_object(foreign);
        foreign_id
    }

    /// Start a transaction as GRIEFER holding the custody and `account_id`.
    fun take(scenario: &mut ts::Scenario, account_id: ID): (TradingCustody, TradingAccount) {
        ts::next_tx(scenario, GRIEFER);
        let custody = ts::take_shared<TradingCustody>(scenario);
        let account = ts::take_shared_by_id<TradingAccount>(scenario, account_id);
        (custody, account)
    }

    #[test]
    fun setup_then_claim_ok() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (mut custody, mut account) = utils::setup(&mut scenario, OFFICER, ou_id);

        assert!(custody.ou_id() == ou_id);
        assert!(custody.trading_account_id() == object::id(&account));
        assert!(account.owner() == object::id(&custody).to_address());
        assert!(!custody.caps_claimed());

        utils::claim(&mut scenario, &mut custody, &mut account);
        assert!(custody.caps_claimed());
        // The DepositCap check leaves an empty SUI balance.
        assert!(account.balance<SUI>() == 0);

        ts::return_shared(custody);
        ts::return_shared(account);
        ts::end(scenario);
    }

    /// Two setups give the OU two independent custodies and accounts.
    #[test]
    fun setup_twice_gives_two_accounts() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (custody_a, account_a) = utils::setup_claimed(&mut scenario, OFFICER, ou_id);
        let account_a_id = object::id(&account_a);
        ts::return_shared(custody_a);
        ts::return_shared(account_a);

        let (custody_b, account_b) = utils::setup_claimed(&mut scenario, OFFICER, ou_id);
        assert!(object::id(&account_b) != account_a_id);
        assert!(custody_b.caps_claimed());

        ts::return_shared(custody_b);
        ts::return_shared(account_b);
        ts::end(scenario);
    }

    /// Caps for another account, sent to the custody before the real claim,
    /// cannot be claimed against the custody's account.
    #[test]
    #[expected_failure(abort_code = EInvalidTrader, location = triex::trading_account)]
    fun claim_foreign_caps_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (custody, account) = utils::setup(&mut scenario, OFFICER, ou_id);
        let custody_id = object::id(&custody);
        let account_id = object::id(&account);
        ts::return_shared(custody);
        ts::return_shared(account);

        // The griefer's caps are now the most recent ones sent to the custody.
        send_foreign_caps(&mut scenario, custody_id);
        let (mut custody, mut account) = take(&mut scenario, account_id);
        utils::claim(&mut scenario, &mut custody, &mut account);
        abort 0
    }

    /// Passing the griefer's account instead of the custody's aborts.
    #[test]
    #[
        expected_failure(
            abort_code = EWrongTradingAccount,
            location = armature_trading::trading_custody,
        ),
    ]
    fun claim_with_wrong_account_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (custody, account) = utils::setup(&mut scenario, OFFICER, ou_id);
        let custody_id = object::id(&custody);
        ts::return_shared(custody);
        ts::return_shared(account);

        let foreign_id = send_foreign_caps(&mut scenario, custody_id);
        let (mut custody, mut foreign) = take(&mut scenario, foreign_id);
        utils::claim(&mut scenario, &mut custody, &mut foreign);
        abort 0
    }

    /// Once claimed, further caps sent to the custody cannot be claimed.
    #[test]
    #[
        expected_failure(
            abort_code = ECapsAlreadyClaimed,
            location = armature_trading::trading_custody,
        ),
    ]
    fun claim_twice_aborts() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (custody, account) = utils::setup_claimed(&mut scenario, OFFICER, ou_id);
        let custody_id = object::id(&custody);
        let account_id = object::id(&account);
        ts::return_shared(custody);
        ts::return_shared(account);

        send_foreign_caps(&mut scenario, custody_id);
        let (mut custody, mut account) = take(&mut scenario, account_id);
        utils::claim(&mut scenario, &mut custody, &mut account);
        abort 0
    }
}
