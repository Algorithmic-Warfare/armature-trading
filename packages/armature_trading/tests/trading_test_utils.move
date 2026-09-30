/// Shared fixtures for armature_trading tests. The governance vote is skipped:
/// tickets are minted with `proposal::new_standalone_ticket_for_testing`, which
/// carries every permission bit.
#[test_only]
module armature_trading::trading_test_utils {
    use armature::{governance, ou, proposal::{Self, ExecutionTicket}};
    use armature_trading::{setup_trading_account, trading_custody::TradingCustody, trading_ops};
    use multicoin::multicoin;
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use triex::trading_account::TradingAccount;

    /// Create and share an OU whose board is `members`. Returns its id.
    public fun make_ou(scenario: &mut Scenario, creator: address, members: vector<address>): ID {
        ts::next_tx(scenario, creator);
        ou::create(
            &governance::init_board(members),
            string::utf8(b"OU"),
            string::utf8(b"https://example.com/i.png"),
            scenario.ctx(),
        )
    }

    /// Share a multicoin Collection; its CollectionCap goes to `owner`.
    public fun make_collection(scenario: &mut Scenario, owner: address): ID {
        ts::next_tx(scenario, owner);
        let (collection, cap) = multicoin::new_collection(scenario.ctx());
        let collection_id = object::id(&collection);
        transfer::public_share_object(collection);
        transfer::public_transfer(cap, owner);
        collection_id
    }

    public fun ticket<P: store>(ou_id: ID, payload: P): ExecutionTicket<P> {
        proposal::new_standalone_ticket_for_testing(
            ou_id,
            object::id_from_address(@0xBEEF),
            payload,
            1,
            1,
        )
    }

    /// Run SetupTradingAccount for `ou_id`, then start a new transaction as
    /// `sender` and take the new custody and account.
    public fun setup(
        scenario: &mut Scenario,
        sender: address,
        ou_id: ID,
    ): (TradingCustody, TradingAccount) {
        ts::next_tx(scenario, sender);
        trading_ops::execute_setup_trading_account(
            ticket(ou_id, setup_trading_account::new()),
            scenario.ctx(),
        );
        ts::next_tx(scenario, sender);
        let custody = ts::take_shared<TradingCustody>(scenario);
        let trading_account = ts::take_shared_by_id<TradingAccount>(
            scenario,
            custody.trading_account_id(),
        );
        (custody, trading_account)
    }
}
