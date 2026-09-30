/// Tests for SetupTradingAccount: the custody owns the new TradingAccount and
/// holds its caps from the setup transaction on.
#[test_only]
module armature_trading::trading_custody_tests {
    use armature_trading::trading_test_utils as utils;
    use sui::test_scenario as ts;

    const OFFICER: address = @0xD1;

    #[test]
    fun setup_ok() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (custody, account) = utils::setup(&mut scenario, OFFICER, ou_id);

        assert!(custody.ou_id() == ou_id);
        assert!(custody.trading_account_id() == object::id(&account));
        assert!(account.owner() == object::id(&custody).to_address());

        ts::return_shared(custody);
        ts::return_shared(account);
        ts::end(scenario);
    }

    /// Two setups give the OU two independent custodies and accounts.
    #[test]
    fun setup_twice_gives_two_accounts() {
        let mut scenario = ts::begin(OFFICER);
        let ou_id = utils::make_ou(&mut scenario, OFFICER, vector[OFFICER]);
        let (custody_a, account_a) = utils::setup(&mut scenario, OFFICER, ou_id);
        let account_a_id = object::id(&account_a);
        ts::return_shared(custody_a);
        ts::return_shared(account_a);

        let (custody_b, account_b) = utils::setup(&mut scenario, OFFICER, ou_id);
        assert!(object::id(&account_b) != account_a_id);
        assert!(custody_b.trading_account_id() == object::id(&account_b));

        ts::return_shared(custody_b);
        ts::return_shared(account_b);
        ts::end(scenario);
    }
}
