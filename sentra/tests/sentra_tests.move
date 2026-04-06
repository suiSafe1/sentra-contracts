/// # Sentra Protocol Tests
///
/// Comprehensive unit tests covering:
/// - Initialization
/// - Token support management
/// - Standard lock: create, add, withdraw (on-time & early)
/// - Yield lock: create, add, unlock s_coin, complete withdrawal (on-time & early, with yield)
/// - Admin fee collection
/// - Pause / unpause guards
/// - Admin transfer flow
/// - All expected-failure (abort) cases
#[test_only]
module sentra::sentra_tests;

use sentra::sentra::{
    Self,
    Platform,
    UserRegistry,
    AdminCap,
    Lock,
    YieldLock,
    PendingAdminTransfer,
};
use sui::test_scenario::{Self, Scenario};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};

public struct USDC has drop {}
public struct SCOIN has drop {}

const ADMIN: address = @0xAD;
const USER:  address = @0xBE;
const USER2: address = @0xCA;


fun setup(): Scenario {
    let mut scenario = test_scenario::begin(ADMIN);
    {
        sentra::init_for_testing(scenario.ctx());
    };
    scenario
}


fun setup_with_token(scenario: &mut Scenario) {
    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::add_token_support<USDC>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };
}

fun setup_with_s_coin(scenario: &mut Scenario) {
    setup_with_token(scenario);
    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::add_s_coin_support<SCOIN>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };
}

fun make_clock(ts_ms: u64, ctx: &mut sui::tx_context::TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(ts_ms);
    clock
}


/// M-04: strategy parameter removed from create_lock — Lock type encodes strategy.
fun create_user_lock(
    scenario: &mut Scenario,
    amount: u64,
    duration_ms: u64,
) {
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let coin         = coin::mint_for_testing<USDC>(amount, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_lock<USDC>(
            &mut platform,
            &mut registry,
            coin,
            duration_ms,
            &clock,
            scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };
}


#[test]
fun test_init_creates_shared_objects() {
    let mut scenario = setup();

    scenario.next_tx(ADMIN);
    {
        let platform = scenario.take_shared<Platform>();
        let registry = scenario.take_shared<UserRegistry>();
        let cap      = scenario.take_from_sender<AdminCap>();

        assert!(sentra::get_admin(&platform) == ADMIN, 0);
        let (dep_paused, wit_paused) = sentra::get_pause_status(&platform);
        assert!(!dep_paused && !wit_paused, 1);

        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}


#[test]
fun test_add_token_support() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let platform = scenario.take_shared<Platform>();
        assert!(sentra::is_token_supported<USDC>(&platform), 0);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EUnauthorized)]
fun test_add_token_support_non_admin_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = test_scenario::take_from_address<AdminCap>(&scenario, ADMIN);
        sentra::add_token_support<SCOIN>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_to_address(ADMIN, cap);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}

#[test]
fun test_add_token_support_idempotent() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::add_token_support<USDC>(&cap, &mut platform, scenario.ctx());
        let tokens = sentra::get_supported_tokens(&platform);
        assert!(vector::length(&tokens) == 1, 0);
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}



#[test]
fun test_configure_token_fee() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::configure_token_fee<USDC>(&cap, &mut platform, 50, 5, 100, scenario.ctx());
        let fee = sentra::calculate_fee_for_amount<USDC>(&platform, 1000);
        assert!(fee == 5, 0);
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EPlatformNotFound)]
fun test_configure_fee_unsupported_token_fails() {
    let mut scenario = setup();

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::configure_token_fee<SCOIN>(&cap, &mut platform, 10, 0, 0, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}



#[test]
fun test_set_pause_status() {
    let mut scenario = setup();

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::set_pause_status(&cap, &mut platform, true, true, scenario.ctx());
        let (dep, wit) = sentra::get_pause_status(&platform);
        assert!(dep && wit, 0);
        sentra::set_pause_status(&cap, &mut platform, false, false, scenario.ctx());
        let (dep2, wit2) = sentra::get_pause_status(&platform);
        assert!(!dep2 && !wit2, 1);
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EPaused)]
fun test_create_lock_when_deposits_paused_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::set_pause_status(&cap, &mut platform, true, false, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    // M-04: no strategy arg
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let coin         = coin::mint_for_testing<USDC>(10_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_lock<USDC>(&mut platform, &mut registry, coin, 1000, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EPaused)]
fun test_withdraw_when_paused_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 1_000);

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::set_pause_status(&cap, &mut platform, false, true, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = scenario.take_from_sender<Lock<USDC>>();
        let clock        = make_clock(5_000, scenario.ctx());
        sentra::withdraw<USDC>(lock, &mut platform, &mut registry, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}


#[test]
fun test_create_lock_success() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 30_000);

    scenario.next_tx(USER);
    {
        let lock     = scenario.take_from_sender<Lock<USDC>>();
        let platform = scenario.take_shared<Platform>();
        let registry = scenario.take_shared<UserRegistry>();

        assert!(sentra::lock_owner(&lock) == USER, 0);
        assert!(sentra::lock_duration_ms(&lock) == 30_000, 1);
        // M-04: lock_strategy removed — Lock type itself encodes the strategy

        // Default deposit fee: ceil(10_000 * 10 / 10_000) = 10
        let bal = sentra::lock_balance_value(&lock);
        assert!(bal == 9_990, 2);

        let tvl_map    = sentra::platform_tvl_by_token(&platform);
        let token_type = std::type_name::with_original_ids<USDC>();
        assert!(*sui::vec_map::get(tvl_map, &token_type) == 9_990, 3);

        // M-03: get_user_locks (vector) removed — use user_has_locks O(1) check
        assert!(sentra::user_has_locks(&registry, USER), 4);

        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
        scenario.return_to_sender(lock);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EInvalidDuration)]
fun test_create_lock_zero_duration_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    // M-04: no strategy arg
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let coin         = coin::mint_for_testing<USDC>(10_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_lock<USDC>(&mut platform, &mut registry, coin, 0, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EInvalidAmount)]
fun test_create_lock_amount_too_small_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    // M-04: no strategy arg
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let coin         = coin::mint_for_testing<USDC>(1, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_lock<USDC>(&mut platform, &mut registry, coin, 1000, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
#[expected_failure(abort_code = sentra::EPlatformNotFound)]
fun test_create_lock_unsupported_token_fails() {
    let mut scenario = setup();

    // M-04: no strategy arg
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let coin         = coin::mint_for_testing<USDC>(10_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_lock<USDC>(&mut platform, &mut registry, coin, 1000, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
fun test_add_to_lock_success() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 30_000);

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut lock     = scenario.take_from_sender<Lock<USDC>>();
        let extra_coin   = coin::mint_for_testing<USDC>(5_000, scenario.ctx());
        sentra::add_to_lock<USDC>(&mut lock, &mut platform, extra_coin, scenario.ctx());

        // Initial balance 9_990 + extra after fee: ceil(5_000 * 10 / 10_000) = 5 → 4_995
        assert!(sentra::lock_balance_value(&lock) == 14_985, 0);

        test_scenario::return_shared(platform);
        scenario.return_to_sender(lock);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EUnauthorized)]
fun test_add_to_lock_wrong_owner_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 30_000);

    scenario.next_tx(USER2);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut lock     = test_scenario::take_from_address<Lock<USDC>>(&scenario, USER);
        let extra        = coin::mint_for_testing<USDC>(5_000, scenario.ctx());
        sentra::add_to_lock<USDC>(&mut lock, &mut platform, extra, scenario.ctx());
        test_scenario::return_to_address(USER, lock);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}



#[test]
fun test_withdraw_on_time_no_penalty() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 1_000);

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = scenario.take_from_sender<Lock<USDC>>();
        let clock        = make_clock(2_000, scenario.ctx());
        sentra::withdraw<USDC>(lock, &mut platform, &mut registry, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let received = scenario.take_from_sender<Coin<USDC>>();
        // Locked amount after deposit fee: 10_000 - 10 = 9_990, no penalty
        assert!(coin::value(&received) == 9_990, 0);
        scenario.return_to_sender(received);
    };

    scenario.end();
}



#[test]
fun test_withdraw_early_penalty_applied() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 10_000);

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = scenario.take_from_sender<Lock<USDC>>();
        let clock        = make_clock(0, scenario.ctx());
        sentra::withdraw<USDC>(lock, &mut platform, &mut registry, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let received = scenario.take_from_sender<Coin<USDC>>();
        // Locked: 9_990. Penalty: floor(9_990 * 200 / 10_000) = 199. User gets 9_791.
        assert!(coin::value(&received) == 9_791, 0);
        scenario.return_to_sender(received);
    };

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::collect_fees<USDC>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.next_tx(ADMIN);
    {
        let fee_coin = scenario.take_from_sender<Coin<USDC>>();
        assert!(coin::value(&fee_coin) == 199, 0);
        scenario.return_to_sender(fee_coin);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EUnauthorized)]
fun test_withdraw_wrong_owner_fails() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 1_000);

    scenario.next_tx(USER2);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = test_scenario::take_from_address<Lock<USDC>>(&scenario, USER);
        let clock        = make_clock(5_000, scenario.ctx());
        sentra::withdraw<USDC>(lock, &mut platform, &mut registry, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
fun test_create_yield_lock_success() {
    let mut scenario = setup();
    setup_with_s_coin(&mut scenario);

    // s_coin = 50_000; deposit fee = ceil(50_000 * 10 / 10_000) = 50
    // s_coin_balance after fee = 49_950
    // H-02: caller supplies principal_base_amount in base token units
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let s_coin       = coin::mint_for_testing<SCOIN>(50_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_yield_lock<USDC, SCOIN>(
            &mut platform,
            &mut registry,
            s_coin,
            60_000,
            49_950, // H-02: base token equivalent at current rate (1:1 in tests)
            b"test yield lock",
            &clock,
            scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let lock     = scenario.take_from_sender<YieldLock<SCOIN>>();
        let registry = scenario.take_shared<UserRegistry>();

        assert!(sentra::yield_lock_owner(&lock) == USER, 0);
        assert!(sentra::yield_lock_duration_ms(&lock) == 60_000, 1);
        // H-02: principal_base_amount is the caller-supplied base amount
        assert!(sentra::yield_lock_principal_amount(&lock) == 49_950, 2);
        assert!(sentra::yield_lock_s_coin_balance_value(&lock) == 49_950, 3);

        // M-03: get_user_yield_locks (vector) removed — use user_has_yield_locks
        assert!(sentra::user_has_yield_locks(&registry, USER), 4);

        test_scenario::return_shared(registry);
        scenario.return_to_sender(lock);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EInvalidDuration)]
fun test_create_yield_lock_zero_duration_fails() {
    let mut scenario = setup();
    setup_with_s_coin(&mut scenario);

    // H-02: principal_base_amount added; duration check fires first
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let s_coin       = coin::mint_for_testing<SCOIN>(50_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_yield_lock<USDC, SCOIN>(
            &mut platform, &mut registry, s_coin, 0, 1, b"", &clock, scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
fun test_add_to_yield_lock_success() {
    let mut scenario = setup();
    setup_with_s_coin(&mut scenario);

    // s_coin = 50_000, fee = 50, s_coin_balance = 49_950, base = 49_950
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let s_coin       = coin::mint_for_testing<SCOIN>(50_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_yield_lock<USDC, SCOIN>(
            &mut platform, &mut registry, s_coin, 60_000, 49_950, b"yield", &clock, scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    // extra s_coin = 20_000, fee = ceil(20_000 * 10 / 10_000) = 20
    // added_s_coin_amount = 19_980; added_base_amount = 19_980 (1:1 in tests)
    // new principal = 49_950 + 19_980 = 69_930
    scenario.next_tx(USER);
    {
        let mut platform  = scenario.take_shared<Platform>();
        let mut lock      = scenario.take_from_sender<YieldLock<SCOIN>>();
        let extra_s_coin  = coin::mint_for_testing<SCOIN>(20_000, scenario.ctx());
        // H-02: added_base_amount is required
        sentra::add_to_yield_lock<USDC, SCOIN>(
            &mut lock, &mut platform, extra_s_coin, 19_980, scenario.ctx(),
        );

        assert!(sentra::yield_lock_principal_amount(&lock) == 69_930, 0);

        test_scenario::return_shared(platform);
        scenario.return_to_sender(lock);
    };

    scenario.end();
}



#[test]
fun test_complete_yield_withdrawal_on_time_with_yield() {
    let mut scenario = setup();
    setup_with_s_coin(&mut scenario);

    // s_coin = 50_000, fee = 50, s_coin_balance = 49_950, base = 49_950
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let s_coin       = coin::mint_for_testing<SCOIN>(50_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_yield_lock<USDC, SCOIN>(
            &mut platform, &mut registry, s_coin, 1_000, 49_950, b"y", &clock, scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    // C-02: unlock_yield_lock_s_coin is entry fun — no return value; transfers
    // the s_coin to the sender internally.
    scenario.next_tx(USER);
    {
        let platform  = scenario.take_shared<Platform>();
        let mut lock  = scenario.take_from_sender<YieldLock<SCOIN>>();
        sentra::unlock_yield_lock_s_coin<SCOIN>(&mut lock, &platform, scenario.ctx());
        assert!(sentra::yield_lock_s_coin_balance_value(&lock) == 0, 0);
        test_scenario::return_shared(platform);
        scenario.return_to_sender(lock);
    };

    // redeemed = 52_000 USDC
    // yield = 52_000 - 49_950 = 2_050
    // yield_fee = floor(2_050 * 3_000 / 10_000) = 615
    // user_yield = 2_050 - 615 = 1_435
    // user_total = 49_950 + 1_435 = 51_385 (on time, no penalty)
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = scenario.take_from_sender<YieldLock<SCOIN>>();
        let clock        = make_clock(2_000, scenario.ctx());
        let redeemed     = coin::mint_for_testing<USDC>(52_000, scenario.ctx());
        sentra::complete_yield_withdrawal_with_redeemed_coin<USDC, SCOIN>(
            lock, redeemed, &mut platform, &mut registry, &clock, scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let received = scenario.take_from_sender<Coin<USDC>>();
        assert!(coin::value(&received) == 51_385, 0);
        scenario.return_to_sender(received);
    };

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::collect_yield_fees<USDC>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.next_tx(ADMIN);
    {
        let fee_coin = scenario.take_from_sender<Coin<USDC>>();
        assert!(coin::value(&fee_coin) == 615, 0);
        scenario.return_to_sender(fee_coin);
    };

    scenario.end();
}



#[test]
fun test_complete_yield_withdrawal_early_with_penalty() {
    let mut scenario = setup();
    setup_with_s_coin(&mut scenario);

    // s_coin = 10_000, fee = ceil(10_000 * 10 / 10_000) = 10
    // s_coin_balance = 9_990, base = 9_990
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let s_coin       = coin::mint_for_testing<SCOIN>(10_000, scenario.ctx());
        let clock        = make_clock(0, scenario.ctx());
        sentra::create_yield_lock<USDC, SCOIN>(
            &mut platform, &mut registry, s_coin, 100_000, 9_990, b"e", &clock, scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    // C-02: entry fun, no return value
    scenario.next_tx(USER);
    {
        let platform  = scenario.take_shared<Platform>();
        let mut lock  = scenario.take_from_sender<YieldLock<SCOIN>>();
        sentra::unlock_yield_lock_s_coin<SCOIN>(&mut lock, &platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(lock);
    };

    // redeemed = 9_990 (no yield, early exit)
    // yield = 9_990 - 9_990 = 0
    // penalty = floor(9_990 * 200 / 10_000) = 199
    // user = 9_990 - 199 = 9_791
    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = scenario.take_from_sender<YieldLock<SCOIN>>();
        let clock        = make_clock(0, scenario.ctx());
        let redeemed     = coin::mint_for_testing<USDC>(9_990, scenario.ctx());
        sentra::complete_yield_withdrawal_with_redeemed_coin<USDC, SCOIN>(
            lock, redeemed, &mut platform, &mut registry, &clock, scenario.ctx(),
        );
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.next_tx(USER);
    {
        let received = scenario.take_from_sender<Coin<USDC>>();
        assert!(coin::value(&received) == 9_791, 0);
        scenario.return_to_sender(received);
    };

    scenario.end();
}



#[test]
fun test_collect_deposit_fees() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 1_000);

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::collect_deposit_fees<USDC>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.next_tx(ADMIN);
    {
        let fee_coin = scenario.take_from_sender<Coin<USDC>>();
        // ceil(10_000 * 10 / 10_000) = 10
        assert!(coin::value(&fee_coin) == 10, 0);
        scenario.return_to_sender(fee_coin);
    };

    scenario.end();
}



#[test]
fun test_admin_transfer_accept() {
    let mut scenario = setup();

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::request_admin_transfer(cap, &mut platform, USER2, scenario.ctx());
        test_scenario::return_shared(platform);
    };

    scenario.next_tx(USER2);
    {
        let mut platform = scenario.take_shared<Platform>();
        let pending      = scenario.take_shared<PendingAdminTransfer>();
        let clock        = make_clock(100, scenario.ctx());
        sentra::accept_admin_transfer(pending, &mut platform, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        assert!(sentra::get_admin(&platform) == USER2, 0);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}

#[test]
fun test_admin_transfer_cancel() {
    let mut scenario = setup();

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::request_admin_transfer(cap, &mut platform, USER2, scenario.ctx());
        test_scenario::return_shared(platform);
    };

    scenario.next_tx(ADMIN);
    {
        let pending = scenario.take_shared<PendingAdminTransfer>();
        sentra::cancel_admin_transfer(pending, scenario.ctx());
    };

    scenario.next_tx(ADMIN);
    {
        let platform = scenario.take_shared<Platform>();
        let cap      = scenario.take_from_sender<AdminCap>();
        assert!(sentra::get_admin(&platform) == ADMIN, 0);
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = sentra::EUnauthorized)]
fun test_admin_transfer_wrong_acceptor_fails() {
    let mut scenario = setup();

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::request_admin_transfer(cap, &mut platform, USER2, scenario.ctx());
        test_scenario::return_shared(platform);
    };

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let pending      = scenario.take_shared<PendingAdminTransfer>();
        let clock        = make_clock(100, scenario.ctx());
        sentra::accept_admin_transfer(pending, &mut platform, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}



#[test]
fun test_view_helpers() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let platform = scenario.take_shared<Platform>();
        assert!(sentra::is_token_supported<USDC>(&platform), 0);
        assert!(!sentra::is_token_supported<SCOIN>(&platform), 1);
        let (d, w) = sentra::get_pause_status(&platform);
        assert!(!d && !w, 2);
        let config_opt = sentra::get_token_fee_config<USDC>(&platform);
        assert!(std::option::is_some(&config_opt), 3);
        let fee = sentra::calculate_fee_for_amount<USDC>(&platform, 1_000_000);
        assert!(fee == 1_000, 4);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}

#[test]
fun test_get_user_locks_empty_when_none() {
    let mut scenario = setup();

    // M-03: get_user_locks / get_user_yield_locks (vector) removed —
    // use boolean presence helpers instead.
    scenario.next_tx(ADMIN);
    {
        let registry = scenario.take_shared<UserRegistry>();
        assert!(!sentra::user_has_locks(&registry, USER), 0);
        assert!(!sentra::user_has_yield_locks(&registry, USER), 1);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
fun test_multiple_locks_same_user() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 1_000);
    create_user_lock(&mut scenario, 20_000, 2_000);

    scenario.next_tx(USER);
    {
        let platform = scenario.take_shared<Platform>();
        let registry = scenario.take_shared<UserRegistry>();

        // M-03: vector-based get_user_locks removed — user_has_locks is O(1)
        assert!(sentra::user_has_locks(&registry, USER), 0);

        // M-03: platform_global_lock_list (vector) removed — use O(1) count
        assert!(sentra::get_total_lock_count(&platform) == 2, 1);

        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
fun test_tvl_decreases_after_withdraw() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);
    create_user_lock(&mut scenario, 10_000, 1_000);

    scenario.next_tx(USER);
    {
        let mut platform = scenario.take_shared<Platform>();
        let mut registry = scenario.take_shared<UserRegistry>();
        let lock         = scenario.take_from_sender<Lock<USDC>>();
        let clock        = make_clock(2_000, scenario.ctx());
        sentra::withdraw<USDC>(lock, &mut platform, &mut registry, &clock, scenario.ctx());
        clock::destroy_for_testing(clock);

        let tvl_map    = sentra::platform_tvl_by_token(&platform);
        let token_type = std::type_name::with_original_ids<USDC>();
        assert!(*sui::vec_map::get(tvl_map, &token_type) == 0, 0);

        test_scenario::return_shared(platform);
        test_scenario::return_shared(registry);
    };

    scenario.end();
}



#[test]
fun test_collect_fees_empty_is_noop() {
    let mut scenario = setup();
    setup_with_token(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let mut platform = scenario.take_shared<Platform>();
        let cap          = scenario.take_from_sender<AdminCap>();
        sentra::collect_fees<USDC>(&cap, &mut platform, scenario.ctx());
        sentra::collect_yield_fees<USDC>(&cap, &mut platform, scenario.ctx());
        test_scenario::return_shared(platform);
        scenario.return_to_sender(cap);
    };

    scenario.end();
}



#[test]
fun test_market_coin_deposit_fee_helpers() {
    let mut scenario = setup();
    setup_with_s_coin(&mut scenario);

    scenario.next_tx(ADMIN);
    {
        let platform = scenario.take_shared<Platform>();
        assert!(sentra::has_market_coin_deposit_fees<SCOIN>(&platform), 0);
        assert!(sentra::has_market_coin_deposit_fees<USDC>(&platform), 1);
        assert!(sentra::get_market_coin_deposit_fee_balance<SCOIN>(&platform) == 0, 2);
        test_scenario::return_shared(platform);
    };

    scenario.end();
}
