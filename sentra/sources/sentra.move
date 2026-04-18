/// # Sentra Token Locking Protocol - Audited by Syntrei
///
/// ## Overview
/// This module implements a token locking protocol with two strategies:
/// 1. Simple Lock (STRATEGY_NO_YIELD): Direct token locking without yield generation
/// 2. Yield Lock (STRATEGY_YIELD): Token locking with yield generation via Scallop Protocol
///
/// ## Key Features
/// - Multi-token support with configurable fee structures
/// - Early withdrawal penalties (2% of locked amount)
/// - Platform yield fees (30% of generated yield)
/// - Deposit fees (configurable per token, default 0.1%)
/// - Admin controls for pausing deposits/withdrawals
///
/// ## Security Considerations
/// - Admin privileges are protected by AdminCap ownership verification
/// - All financial operations include balance validation checks
/// - Early withdrawal penalties discourage manipulation
/// - Fee calculations use safe math to prevent overflows
module sentra::sentra;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::event;
use sui::vec_map::{Self, VecMap};
use sui::bag::{Self, Bag};
use sui::table::{Self, Table};
use std::type_name::{Self, TypeName};
use std::string::{Self, String};


const EInvalidDuration: u64 = 0;
const EUnauthorized: u64 = 1;
const EPlatformNotFound: u64 = 2;
const EInvalidAmount: u64 = 5;
const EPaused: u64 = 6;
const EInvalidCapId: u64 = 7;
const EInsufficientForFee: u64 = 8;
const ETokenFeeNotConfigured: u64 = 9;
const EAlreadyUnlocked: u64 = 10;
const ESCoinNotUnlocked: u64 = 11;
const ESCoinTypeMismatch: u64 = 12;
const EInvalidFeeRate: u64 = 13;


const BPS_DENOM: u64 = 10_000;
const STRATEGY_YIELD: u8 = 1;

const DEFAULT_PENALTY_BPS: u64 = 200;
const DEFAULT_YIELD_FEE_BPS: u64 = 3000;
const DEFAULT_DEPOSIT_FEE_BPS: u64 = 10;



public struct Lock<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    owner: address,
    start_time: u64,
    duration_ms: u64,
}

/// Yield-generating lock using Scallop Protocol sCoin.
///
/// H-03: `store` ability removed.
/// C-01: `s_coin_unlocked` flag — set to true by unlock_yield_lock_s_coin.
///       complete_yield_withdrawal aborts unless this is true.
/// H-01: `expected_s_coin_type` — enforced on every add_to_yield_lock call.
/// H-02: `principal_base_amount` — principal in BASE TOKEN units (not sCoin).
public struct YieldLock<phantom SCoin> has key {
    id: UID,
    owner: address,
    start_time: u64,
    duration_ms: u64,
    principal_base_amount: u64,
    principal_s_coin_amount: u64,
    coin_type: TypeName,
    expected_s_coin_type: TypeName,
    s_coin_balance: Balance<SCoin>,
    description: String,
    s_coin_unlocked: bool,
}

public struct TokenFeeConfig has store, copy, drop {
    deposit_fee_bps: u64,
    min_deposit_fee: u64,
    max_deposit_fee: u64,
}



public struct Platform has key, store {
    id: UID,
    admin: address,
    admin_cap_id: ID,
    fees: Bag,
    yield_fees: Bag,
    deposit_fees: Bag,
    token_fee_configs: VecMap<TypeName, TokenFeeConfig>,
    supported_tokens: vector<TypeName>,
    paused_deposits: bool,
    paused_withdrawals: bool,
    tvl_by_token: VecMap<TypeName, u64>,
    yield_tvl_by_token: VecMap<TypeName, u64>,
    global_lock_list: Table<ID, bool>,
    global_yield_lock_list: Table<ID, bool>,
    locks_by_token_count: VecMap<TypeName, u64>,
    yield_locks_by_token_count: VecMap<TypeName, u64>,
    penalty_bps: u64,
    yield_fee_bps: u64,
    default_deposit_fee_bps: u64,
}


public struct UserRegistry has key, store {
    id: UID,
    locks: Table<address, Table<ID, bool>>,
    yield_locks: Table<address, Table<ID, bool>>,
    lock_user_count: u64,
    yield_lock_user_count: u64,
}


public struct AdminCap has key, store {
    id: UID,
    platform_id: ID,
}

public struct PendingAdminTransfer has key {
    id: UID,
    cap: AdminCap,
    current_admin: address,
    new_admin: address,
}


public struct LockCreated<phantom CoinType> has copy, drop, store {
    owner: address,
    amount: u64,
    deposit_fee_paid: u64,
    start_time: u64,
    duration_ms: u64,
}

public struct LockExtended<phantom CoinType> has copy, drop, store {
    owner: address,
    added_amount: u64,
    deposit_fee_paid: u64,
    new_total: u64,
}

public struct LockWithdrawn<phantom CoinType> has copy, drop, store {
    owner: address,
    amount_withdrawn: u64,
    withdrawn_time: u64,
}

public struct YieldLockCreated has copy, drop, store {
    owner: address,
    principal_s_coin_amount: u64,
    principal_base_amount: u64,
    deposit_fee_paid: u64,
    coin_type: TypeName,
    s_coin_type: TypeName,
    start_time: u64,
    duration_ms: u64,
    yield_lock_id: ID,
    description: String,
}

public struct YieldLockExtended has copy, drop, store {
    owner: address,
    added_s_coin_amount: u64,
    deposit_fee_paid: u64,
    new_s_coin_balance: u64,
    new_principal_base_amount: u64,
    new_principal_s_coin_amount: u64,
    coin_type: TypeName,
}

public struct YieldLockWithdrawn has copy, drop, store {
    owner: address,
    yield_lock_id: ID,
    principal_withdrawn: u64,
    yield_earned: u64,
    platform_yield_fee: u64,
    user_yield_amount: u64,
    withdrawn_time: u64,
    coin_type: TypeName,
}

public struct PlatformFeesUpdated has copy, drop, store {
    admin: address,
    penalty_bps: u64,
    yield_fee_bps: u64,
    default_deposit_fee_bps: u64,
}

public struct TokenAdded has copy, drop, store {
    token_type: TypeName,
    admin: address,
}

public struct TokenFeeConfigUpdated has copy, drop, store {
    token_type: TypeName,
    admin: address,
    deposit_fee_bps: u64,
    min_deposit_fee: u64,
    max_deposit_fee: u64,
}

public struct FeesCollected<phantom CoinType> has copy, drop, store {
    admin: address,
    amount: u64,
    fee_type: u8,
}

public struct PauseStatusChanged has copy, drop, store {
    admin: address,
    deposits_paused: bool,
    withdrawals_paused: bool,
}

public struct AdminTransferred has copy, drop, store {
    old_admin: address,
    new_admin: address,
    timestamp: u64,
}


fun init(ctx: &mut TxContext) {
    let platform_id = object::new(ctx);
    let platform_uid = object::uid_to_inner(&platform_id);

    let cap = AdminCap {
        id: object::new(ctx),
        platform_id: platform_uid,
    };
    let cap_id = object::id(&cap);

    transfer::transfer(cap, tx_context::sender(ctx));

    let registry = UserRegistry {
        id: object::new(ctx),
        locks: table::new(ctx),
        yield_locks: table::new(ctx),
        lock_user_count: 0,
        yield_lock_user_count: 0,
    };
    transfer::share_object(registry);

    let platform = Platform {
        id: platform_id,
        admin: tx_context::sender(ctx),
        admin_cap_id: cap_id,
        fees: bag::new(ctx),
        yield_fees: bag::new(ctx),
        deposit_fees: bag::new(ctx),
        token_fee_configs: vec_map::empty(),
        supported_tokens: vector::empty(),
        paused_deposits: false,
        paused_withdrawals: false,
        tvl_by_token: vec_map::empty(),
        yield_tvl_by_token: vec_map::empty(),
        global_lock_list: table::new(ctx),
        global_yield_lock_list: table::new(ctx),
        locks_by_token_count: vec_map::empty(),
        yield_locks_by_token_count: vec_map::empty(),
        penalty_bps: DEFAULT_PENALTY_BPS,
        yield_fee_bps: DEFAULT_YIELD_FEE_BPS,
        default_deposit_fee_bps: DEFAULT_DEPOSIT_FEE_BPS,
    };
    transfer::share_object(platform);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }


public entry fun set_pause_status(
    cap: &AdminCap,
    platform: &mut Platform,
    pause_deposits: bool,
    pause_withdrawals: bool,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    platform.paused_deposits = pause_deposits;
    platform.paused_withdrawals = pause_withdrawals;

    event::emit(PauseStatusChanged {
        admin: sender,
        deposits_paused: pause_deposits,
        withdrawals_paused: pause_withdrawals,
    });
}


public entry fun add_token_support<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    let token_type = type_name::with_original_ids<CoinType>();

    if (!vector::contains(&platform.supported_tokens, &token_type)) {
        vector::push_back(&mut platform.supported_tokens, token_type);

        bag::add(&mut platform.fees, token_type, balance::zero<CoinType>());
        bag::add(&mut platform.yield_fees, token_type, balance::zero<CoinType>());
        bag::add(&mut platform.deposit_fees, token_type, balance::zero<CoinType>());

        vec_map::insert(&mut platform.token_fee_configs, token_type, TokenFeeConfig {
            deposit_fee_bps: platform.default_deposit_fee_bps,
            min_deposit_fee: 0,
            max_deposit_fee: 0,
        });

        vec_map::insert(&mut platform.tvl_by_token, token_type, 0);
        vec_map::insert(&mut platform.yield_tvl_by_token, token_type, 0);
        vec_map::insert(&mut platform.locks_by_token_count, token_type, 0);
        vec_map::insert(&mut platform.yield_locks_by_token_count, token_type, 0);

        event::emit(TokenAdded { token_type, admin: sender });
    }
}

public entry fun add_s_coin_support<SCoin>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    let s_coin_type = type_name::with_original_ids<SCoin>();

    if (!bag::contains(&platform.deposit_fees, s_coin_type)) {
        bag::add(&mut platform.deposit_fees, s_coin_type, balance::zero<SCoin>());
    }
}


public entry fun configure_token_fee<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    deposit_fee_bps: u64,
    min_deposit_fee: u64,
    max_deposit_fee: u64,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);
    assert!(deposit_fee_bps <= BPS_DENOM, EInvalidAmount);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);

    let fee_config = TokenFeeConfig { deposit_fee_bps, min_deposit_fee, max_deposit_fee };

    if (vec_map::contains(&platform.token_fee_configs, &token_type)) {
        *vec_map::get_mut(&mut platform.token_fee_configs, &token_type) = fee_config;
    } else {
        vec_map::insert(&mut platform.token_fee_configs, token_type, fee_config);
    };

    event::emit(TokenFeeConfigUpdated {
        token_type,
        admin: sender,
        deposit_fee_bps,
        min_deposit_fee,
        max_deposit_fee,
    });
}



public entry fun configure_platform_fees(
    cap: &AdminCap,
    platform: &mut Platform,
    penalty_bps: u64,
    yield_fee_bps: u64,
    default_deposit_fee_bps: u64,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    assert!(penalty_bps <= BPS_DENOM, EInvalidFeeRate);
    assert!(yield_fee_bps <= BPS_DENOM, EInvalidFeeRate);
    assert!(default_deposit_fee_bps <= BPS_DENOM, EInvalidFeeRate);
    assert!(penalty_bps + yield_fee_bps <= BPS_DENOM, EInvalidFeeRate);

    platform.penalty_bps = penalty_bps;
    platform.yield_fee_bps = yield_fee_bps;
    platform.default_deposit_fee_bps = default_deposit_fee_bps;

    event::emit(PlatformFeesUpdated {
        admin: sender,
        penalty_bps,
        yield_fee_bps,
        default_deposit_fee_bps,
    });
}


public entry fun request_admin_transfer(
    cap: AdminCap,
    platform: &mut Platform,
    new_admin: address,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(&cap) == platform.admin_cap_id, EInvalidCapId);

    transfer::share_object(PendingAdminTransfer {
        id: object::new(ctx),
        cap,
        current_admin: sender,
        new_admin,
    });
}


public entry fun accept_admin_transfer(
    pending: PendingAdminTransfer,
    platform: &mut Platform,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == pending.new_admin, EUnauthorized);

    let PendingAdminTransfer { id, cap, current_admin, new_admin } = pending;
    assert!(object::id(&cap) == platform.admin_cap_id, EInvalidCapId);

    platform.admin = new_admin;
    platform.admin_cap_id = object::id(&cap);
    transfer::transfer(cap, new_admin);
    object::delete(id);

    event::emit(AdminTransferred {
        old_admin: current_admin,
        new_admin,
        timestamp: clock.timestamp_ms(),
    });
}

public entry fun cancel_admin_transfer(
    pending: PendingAdminTransfer,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == pending.current_admin, EUnauthorized);

    let PendingAdminTransfer { id, cap, current_admin, new_admin: _ } = pending;
    transfer::transfer(cap, current_admin);
    object::delete(id);
}


fun safe_mul_div(amount: u64, numerator: u64, denominator: u64): u64 {
    (((amount as u128) * (numerator as u128)) / (denominator as u128)) as u64
}

fun safe_mul_div_ceil(amount: u64, numerator: u64, denominator: u64): u64 {
    (((amount as u128) * (numerator as u128) + (denominator as u128) - 1) / (denominator as u128)) as u64
}



fun calculate_deposit_fee(amount: u64, fee_config: &TokenFeeConfig): u64 {
    let percentage_fee = safe_mul_div_ceil(amount, fee_config.deposit_fee_bps, BPS_DENOM);

    let fee_after_min = if (percentage_fee < fee_config.min_deposit_fee) {
        fee_config.min_deposit_fee
    } else {
        percentage_fee
    };

    let final_fee = if (fee_config.max_deposit_fee > 0 && fee_after_min > fee_config.max_deposit_fee) {
        fee_config.max_deposit_fee
    } else {
        fee_after_min
    };

    assert!(final_fee < amount, EInsufficientForFee);
    final_fee
}


fun registry_add_lock(registry: &mut UserRegistry, owner: address, lock_id: ID, ctx: &mut TxContext) {
    if (!table::contains(&registry.locks, owner)) {
        table::add(&mut registry.locks, owner, table::new<ID, bool>(ctx));
        registry.lock_user_count = registry.lock_user_count + 1;
    };
    table::add(table::borrow_mut(&mut registry.locks, owner), lock_id, true);
}

fun registry_remove_lock(registry: &mut UserRegistry, owner: address, lock_id: ID) {
    if (table::contains(&registry.locks, owner)) {
        let user_table = table::borrow_mut(&mut registry.locks, owner);
        if (table::contains(user_table, lock_id)) {
            table::remove(user_table, lock_id);
        };

    };
}

fun registry_add_yield_lock(registry: &mut UserRegistry, owner: address, lock_id: ID, ctx: &mut TxContext) {
    if (!table::contains(&registry.yield_locks, owner)) {
        table::add(&mut registry.yield_locks, owner, table::new<ID, bool>(ctx));
        registry.yield_lock_user_count = registry.yield_lock_user_count + 1;
    };
    table::add(table::borrow_mut(&mut registry.yield_locks, owner), lock_id, true);
}

fun registry_remove_yield_lock(registry: &mut UserRegistry, owner: address, lock_id: ID) {
    if (table::contains(&registry.yield_locks, owner)) {
        let user_table = table::borrow_mut(&mut registry.yield_locks, owner);
        if (table::contains(user_table, lock_id)) {
            table::remove(user_table, lock_id);
        };
    };
}


fun update_tvl<CoinType>(platform: &mut Platform, amount_delta: u64, is_addition: bool) {
    let token_type = type_name::with_original_ids<CoinType>();
    if (vec_map::contains(&platform.tvl_by_token, &token_type)) {
        let current = vec_map::get_mut(&mut platform.tvl_by_token, &token_type);
        if (is_addition) { *current = *current + amount_delta }
        else { *current = *current - amount_delta };
    }
}

fun update_yield_tvl<CoinType>(platform: &mut Platform, amount_delta: u64, is_addition: bool) {
    let token_type = type_name::with_original_ids<CoinType>();
    if (vec_map::contains(&platform.yield_tvl_by_token, &token_type)) {
        let current = vec_map::get_mut(&mut platform.yield_tvl_by_token, &token_type);
        if (is_addition) { *current = *current + amount_delta }
        else { *current = *current - amount_delta };
    }
}

fun increment_token_lock_count(platform: &mut Platform, token_type: TypeName) {
    if (vec_map::contains(&platform.locks_by_token_count, &token_type)) {
        let c = vec_map::get_mut(&mut platform.locks_by_token_count, &token_type);
        *c = *c + 1;
    }
}

fun decrement_token_lock_count(platform: &mut Platform, token_type: TypeName) {
    if (vec_map::contains(&platform.locks_by_token_count, &token_type)) {
        let c = vec_map::get_mut(&mut platform.locks_by_token_count, &token_type);
        if (*c > 0) { *c = *c - 1 };
    }
}

fun increment_token_yield_lock_count(platform: &mut Platform, token_type: TypeName) {
    if (vec_map::contains(&platform.yield_locks_by_token_count, &token_type)) {
        let c = vec_map::get_mut(&mut platform.yield_locks_by_token_count, &token_type);
        *c = *c + 1;
    }
}

fun decrement_token_yield_lock_count(platform: &mut Platform, token_type: TypeName) {
    if (vec_map::contains(&platform.yield_locks_by_token_count, &token_type)) {
        let c = vec_map::get_mut(&mut platform.yield_locks_by_token_count, &token_type);
        if (*c > 0) { *c = *c - 1 };
    }
}



public entry fun create_lock<CoinType>(
    platform: &mut Platform,
    registry: &mut UserRegistry,
    mut coin: Coin<CoinType>,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!platform.paused_deposits, EPaused);
    assert!(duration_ms > 0, EInvalidDuration);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);

    let total_amount = coin.value();
    assert!(total_amount > 1, EInvalidAmount);

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_balance = coin::into_balance(coin::split(&mut coin, deposit_fee, ctx));
    balance::join(bag::borrow_mut(&mut platform.deposit_fees, token_type), deposit_fee_balance);

    let amount = coin.value();
    assert!(amount > 0, EInvalidAmount);

    let now = clock.timestamp_ms();
    let owner = tx_context::sender(ctx);

    let lock = Lock {
        id: object::new(ctx),
        balance: coin::into_balance(coin),
        owner,
        start_time: now,
        duration_ms,
    };

    let lock_id = object::id(&lock);

    registry_add_lock(registry, owner, lock_id, ctx);

    update_tvl<CoinType>(platform, amount, true);
    table::add(&mut platform.global_lock_list, lock_id, true);
    increment_token_lock_count(platform, token_type);

    transfer::transfer(lock, owner);

    event::emit(LockCreated<CoinType> {
        owner,
        amount,
        deposit_fee_paid: deposit_fee,
        start_time: now,
        duration_ms,
    });
}


public entry fun add_to_lock<CoinType>(
    lock: &mut Lock<CoinType>,
    platform: &mut Platform,
    mut coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == lock.owner, EUnauthorized);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);

    let total_amount = coin.value();
    assert!(total_amount > 1, EInvalidAmount);

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_balance = coin::into_balance(coin::split(&mut coin, deposit_fee, ctx));
    balance::join(bag::borrow_mut(&mut platform.deposit_fees, token_type), deposit_fee_balance);

    let added_balance = coin::into_balance(coin);
    let added_amount = added_balance.value();
    balance::join(&mut lock.balance, added_balance);
    assert!(added_amount > 0, EInvalidAmount);

    update_tvl<CoinType>(platform, added_amount, true);

    event::emit(LockExtended<CoinType> {
        owner: sender,
        added_amount,
        deposit_fee_paid: deposit_fee,
        new_total: lock.balance.value(),
    });
}


public entry fun withdraw<CoinType>(
    lock: Lock<CoinType>,
    platform: &mut Platform,
    registry: &mut UserRegistry,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!platform.paused_withdrawals, EPaused);

    let sender = tx_context::sender(ctx);
    assert!(sender == lock.owner, EUnauthorized);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);

    let Lock { id, mut balance, owner: _, start_time, duration_ms } = lock;
    let lock_id = object::uid_to_inner(&id);

    let unlock_time = start_time + duration_ms;
    let total_amount = balance.value();
    let now = clock.timestamp_ms();

    let (user_amount, penalty) = if (now >= unlock_time) {
        (total_amount, 0)
    } else {
        let pen = safe_mul_div(total_amount, platform.penalty_bps, BPS_DENOM);
        (total_amount - pen, pen)
    };

    if (user_amount > 0) {
        transfer::public_transfer(coin::take(&mut balance, user_amount, ctx), sender);
    };

    if (penalty > 0) {
        let penalty_balance = coin::into_balance(coin::take(&mut balance, penalty, ctx));
        balance::join(bag::borrow_mut(&mut platform.fees, token_type), penalty_balance);
    };

    registry_remove_lock(registry, sender, lock_id);

    update_tvl<CoinType>(platform, user_amount, false);

    if (table::contains(&platform.global_lock_list, lock_id)) {
        table::remove(&mut platform.global_lock_list, lock_id);
    };
    decrement_token_lock_count(platform, token_type);

    event::emit(LockWithdrawn<CoinType> {
        owner: sender,
        amount_withdrawn: user_amount,
        withdrawn_time: now,
    });

    balance::destroy_zero(balance);
    object::delete(id);
}



public entry fun create_yield_lock<CoinType, SCoin>(
    platform: &mut Platform,
    registry: &mut UserRegistry,
    mut s_coin: Coin<SCoin>,
    duration_ms: u64,
    principal_base_amount: u64,
    description: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!platform.paused_deposits, EPaused);
    assert!(duration_ms > 0, EInvalidDuration);
    assert!(principal_base_amount > 0, EInvalidAmount);

    let token_type = type_name::with_original_ids<CoinType>();
    let s_coin_type = type_name::with_original_ids<SCoin>();

    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);
    assert!(bag::contains(&platform.deposit_fees, s_coin_type), EPlatformNotFound);

    let total_amount = coin::value(&s_coin);
    assert!(total_amount > 1, EInvalidAmount);

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_balance = coin::into_balance(coin::split(&mut s_coin, deposit_fee, ctx));
    balance::join(bag::borrow_mut(&mut platform.deposit_fees, s_coin_type), deposit_fee_balance);

    let principal_s_coin_amount = coin::value(&s_coin);
    assert!(principal_s_coin_amount > 0, EInvalidAmount);

    let adjusted_principal_base_amount = safe_mul_div(principal_base_amount, principal_s_coin_amount, total_amount);

    let now = clock.timestamp_ms();
    let owner = tx_context::sender(ctx);
    let description_str = string::utf8(description);

    let yield_lock = YieldLock<SCoin> {
        id: object::new(ctx),
        owner,
        start_time: now,
        duration_ms,
        principal_base_amount: adjusted_principal_base_amount,
        principal_s_coin_amount,
        coin_type: token_type,
        expected_s_coin_type: s_coin_type,
        s_coin_balance: coin::into_balance(s_coin),
        description: description_str,
        s_coin_unlocked: false,
    };

    let lock_id = object::id(&yield_lock);

    registry_add_yield_lock(registry, owner, lock_id, ctx);

    update_yield_tvl<CoinType>(platform, principal_s_coin_amount, true);
    table::add(&mut platform.global_yield_lock_list, lock_id, true);
    increment_token_yield_lock_count(platform, token_type);

    transfer::transfer(yield_lock, owner);

    event::emit(YieldLockCreated {
        owner,
        principal_s_coin_amount,
        principal_base_amount: adjusted_principal_base_amount,
        deposit_fee_paid: deposit_fee,
        coin_type: token_type,
        s_coin_type,
        start_time: now,
        duration_ms,
        yield_lock_id: lock_id,
        description: description_str,
    });
}



public entry fun add_to_yield_lock<CoinType, SCoin>(
    yield_lock: &mut YieldLock<SCoin>,
    platform: &mut Platform,
    mut s_coin: Coin<SCoin>,
    added_base_amount: u64,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == yield_lock.owner, EUnauthorized);

    let token_type = type_name::with_original_ids<CoinType>();
    let s_coin_type = type_name::with_original_ids<SCoin>();

    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);
    assert!(yield_lock.coin_type == token_type, EPlatformNotFound);
    // H-01: enforce SCoin type
    assert!(yield_lock.expected_s_coin_type == s_coin_type, ESCoinTypeMismatch);
    assert!(added_base_amount > 0, EInvalidAmount);

    let total_amount = coin::value(&s_coin);
    assert!(total_amount > 1, EInvalidAmount);

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_balance = coin::into_balance(coin::split(&mut s_coin, deposit_fee, ctx));
    balance::join(bag::borrow_mut(&mut platform.deposit_fees, s_coin_type), deposit_fee_balance);

    let added_balance = coin::into_balance(s_coin);
    let added_s_coin_amount = added_balance.value();
    balance::join(&mut yield_lock.s_coin_balance, added_balance);


    let adjusted_added_base_amount = safe_mul_div(added_base_amount, added_s_coin_amount, total_amount);
    yield_lock.principal_base_amount = yield_lock.principal_base_amount + adjusted_added_base_amount;
    yield_lock.principal_s_coin_amount = yield_lock.principal_s_coin_amount + added_s_coin_amount;

    update_yield_tvl<CoinType>(platform, added_s_coin_amount, true);

    event::emit(YieldLockExtended {
        owner: sender,
        added_s_coin_amount,
        deposit_fee_paid: deposit_fee,
        new_s_coin_balance: yield_lock.s_coin_balance.value(),
        new_principal_base_amount: yield_lock.principal_base_amount,
        new_principal_s_coin_amount: yield_lock.principal_s_coin_amount,
        coin_type: token_type,
    });
}


/// Step 1 of yield lock withdrawal: extract SCoin from the contract.
///
/// C-01: sets s_coin_unlocked = true; aborts on double-call (EAlreadyUnlocked).
/// Returns the SCoin so it can be piped directly into burn_s_coin in a PTB.
/// Security is enforced by the owner assertion — tx_context::sender cannot be
/// spoofed by a calling module, so no additional `entry` guard is needed.
public fun unlock_yield_lock_s_coin<SCoin>(
    yield_lock: &mut YieldLock<SCoin>,
    platform: &Platform,
    ctx: &mut TxContext
): coin::Coin<SCoin> {
    assert!(!platform.paused_withdrawals, EPaused);

    let sender = tx_context::sender(ctx);
    assert!(sender == yield_lock.owner, EUnauthorized);

    assert!(!yield_lock.s_coin_unlocked, EAlreadyUnlocked);

    let amount = yield_lock.s_coin_balance.value();
    assert!(amount > 0, EInvalidAmount);

    let s_coin = coin::take(&mut yield_lock.s_coin_balance, amount, ctx);
    yield_lock.s_coin_unlocked = true;

    s_coin
}


/// Step 2 (final): complete yield lock withdrawal with redeemed base tokens.
///
/// C-01: asserts s_coin_unlocked == true.
/// C-03: TVL decremented by principal_s_coin_amount (original bookkeeping amount).
/// H-02: yield computed entirely in base token units.
/// M-03: O(1) registry and global list removal.
public entry fun complete_yield_withdrawal_with_redeemed_coin<CoinType, SCoin>(
    yield_lock: YieldLock<SCoin>,
    mut redeemed_coin: Coin<CoinType>,
    platform: &mut Platform,
    registry: &mut UserRegistry,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!platform.paused_withdrawals, EPaused);
    let sender = tx_context::sender(ctx);
    assert!(sender == yield_lock.owner, EUnauthorized);

    // C-01: unlock must have happened first
    assert!(yield_lock.s_coin_unlocked, ESCoinNotUnlocked);

    let YieldLock {
        id,
        owner: _,
        start_time,
        duration_ms,
        principal_base_amount,
        principal_s_coin_amount,
        coin_type: stored_token_type,
        expected_s_coin_type: _,
        s_coin_balance,
        description: _,
        s_coin_unlocked: _,
    } = yield_lock;

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(stored_token_type == token_type, EPlatformNotFound);

    let lock_id = object::uid_to_inner(&id);
    let now = clock.timestamp_ms();
    let unlock_time = start_time + duration_ms;

    // s_coin_balance is zero after unlock step
    coin::destroy_zero(coin::from_balance(s_coin_balance, ctx));

    let total_redeemed_amount = redeemed_coin.value();

    // H-02 + C-01: hard assertion — redeemed must cover at least principal
    assert!(total_redeemed_amount >= principal_base_amount, EInvalidAmount);

    // H-02: both sides are base token units
    let total_yield = total_redeemed_amount - principal_base_amount;

    let (user_principal, penalty) = if (now >= unlock_time) {
        (principal_base_amount, 0)
    } else {
        let pen = safe_mul_div(principal_base_amount, platform.penalty_bps, BPS_DENOM);
        let user_gets = if (principal_base_amount > pen) { principal_base_amount - pen } else { 0 };
        (user_gets, pen)
    };

    let (platform_yield_fee, user_yield_amount) = if (total_yield > 0) {
        let fee = safe_mul_div(total_yield, platform.yield_fee_bps, BPS_DENOM);
        (fee, total_yield - fee)
    } else {
        (0, 0)
    };

    let user_total_amount = user_principal + user_yield_amount;
    let platform_total_fees = penalty + platform_yield_fee;
    assert!(user_total_amount + platform_total_fees <= redeemed_coin.value(), EInvalidAmount);

    if (user_total_amount > 0) {
        transfer::public_transfer(coin::split(&mut redeemed_coin, user_total_amount, ctx), sender);
    };

    if (platform_total_fees > 0) {
        let mut platform_balance = coin::into_balance(coin::split(&mut redeemed_coin, platform_total_fees, ctx));

        if (penalty > 0) {
            balance::join(
                bag::borrow_mut(&mut platform.fees, token_type),
                balance::split(&mut platform_balance, penalty),
            );
        };

        if (platform_yield_fee > 0) {
            balance::join(bag::borrow_mut(&mut platform.yield_fees, token_type), platform_balance);
        } else {
            balance::destroy_zero(platform_balance);
        };
    };

    if (coin::value(&redeemed_coin) > 0) {
        transfer::public_transfer(redeemed_coin, sender);
    } else {
        coin::destroy_zero(redeemed_coin);
    };

    // M-03: O(1) registry removal
    registry_remove_yield_lock(registry, sender, lock_id);

    // C-03: decrement by the original SCoin-unit TVL amount
    update_yield_tvl<CoinType>(platform, principal_s_coin_amount, false);

    // M-03: O(1) Table removal
    if (table::contains(&platform.global_yield_lock_list, lock_id)) {
        table::remove(&mut platform.global_yield_lock_list, lock_id);
    };
    decrement_token_yield_lock_count(platform, token_type);

    event::emit(YieldLockWithdrawn {
        owner: sender,
        yield_lock_id: lock_id,
        principal_withdrawn: user_principal,
        yield_earned: total_yield,
        platform_yield_fee,
        user_yield_amount,
        withdrawn_time: now,
        coin_type: token_type,
    });

    object::delete(id);
}


entry fun collect_fees<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);

    let token_fees: &mut Balance<CoinType> = bag::borrow_mut(&mut platform.fees, token_type);
    let amount = balance::value(token_fees);

    if (amount > 0) {
        transfer::public_transfer(coin::from_balance(balance::withdraw_all(token_fees), ctx), sender);
        event::emit(FeesCollected<CoinType> { admin: sender, amount, fee_type: 0 });
    }
}


entry fun collect_yield_fees<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);

    let yield_token_fees: &mut Balance<CoinType> = bag::borrow_mut(&mut platform.yield_fees, token_type);
    let amount = balance::value(yield_token_fees);

    if (amount > 0) {
        transfer::public_transfer(coin::from_balance(balance::withdraw_all(yield_token_fees), ctx), sender);
        event::emit(FeesCollected<CoinType> { admin: sender, amount, fee_type: 1 });
    }
}

/// L-01: renamed generic from SCoin to CoinType for consistency with collect_fees
/// and collect_yield_fees.
entry fun collect_deposit_fees<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);

    let coin_type = type_name::with_original_ids<CoinType>();
    assert!(bag::contains(&platform.deposit_fees, coin_type), EPlatformNotFound);

    let deposit_token_fees: &mut Balance<CoinType> = bag::borrow_mut(&mut platform.deposit_fees, coin_type);
    let amount = balance::value(deposit_token_fees);

    if (amount > 0) {
        transfer::public_transfer(coin::from_balance(balance::withdraw_all(deposit_token_fees), ctx), sender);
        event::emit(FeesCollected<CoinType> { admin: sender, amount, fee_type: 2 });
    }
}


// ── Accessors ────────────────────────────────────────────────────────────────

public fun get_supported_tokens(platform: &Platform): vector<TypeName> {
    platform.supported_tokens
}

public fun is_token_supported<CoinType>(platform: &Platform): bool {
    vector::contains(&platform.supported_tokens, &type_name::with_original_ids<CoinType>())
}

public fun get_pause_status(platform: &Platform): (bool, bool) {
    (platform.paused_deposits, platform.paused_withdrawals)
}

public fun user_has_locks(registry: &UserRegistry, user: address): bool {
    if (!table::contains(&registry.locks, user)) return false;
    table::length(table::borrow(&registry.locks, user)) > 0
}

public fun user_has_yield_locks(registry: &UserRegistry, user: address): bool {
    if (!table::contains(&registry.yield_locks, user)) return false;
    table::length(table::borrow(&registry.yield_locks, user)) > 0
}

public fun user_owns_lock(registry: &UserRegistry, user: address, lock_id: ID): bool {
    if (!table::contains(&registry.locks, user)) return false;
    table::contains(table::borrow(&registry.locks, user), lock_id)
}

public fun user_owns_yield_lock(registry: &UserRegistry, user: address, lock_id: ID): bool {
    if (!table::contains(&registry.yield_locks, user)) return false;
    table::contains(table::borrow(&registry.yield_locks, user), lock_id)
}

public fun lock_exists(platform: &Platform, lock_id: ID): bool {
    table::contains(&platform.global_lock_list, lock_id)
}

public fun yield_lock_exists(platform: &Platform, lock_id: ID): bool {
    table::contains(&platform.global_yield_lock_list, lock_id)
}

public fun get_total_lock_count(platform: &Platform): u64 {
    table::length(&platform.global_lock_list)
}

public fun get_total_yield_lock_count(platform: &Platform): u64 {
    table::length(&platform.global_yield_lock_list)
}

public fun get_lock_count_for_token(platform: &Platform, token_type: TypeName): u64 {
    if (vec_map::contains(&platform.locks_by_token_count, &token_type)) {
        *vec_map::get(&platform.locks_by_token_count, &token_type)
    } else { 0 }
}

public fun get_yield_lock_count_for_token(platform: &Platform, token_type: TypeName): u64 {
    if (vec_map::contains(&platform.yield_locks_by_token_count, &token_type)) {
        *vec_map::get(&platform.yield_locks_by_token_count, &token_type)
    } else { 0 }
}

public fun get_total_users_with_locks(registry: &UserRegistry): u64 {
    registry.lock_user_count
}

public fun get_total_users_with_yield_locks(registry: &UserRegistry): u64 {
    registry.yield_lock_user_count
}

public fun get_token_fee_config<CoinType>(platform: &Platform): Option<TokenFeeConfig> {
    let token_type = type_name::with_original_ids<CoinType>();
    if (vec_map::contains(&platform.token_fee_configs, &token_type)) {
        option::some(*vec_map::get(&platform.token_fee_configs, &token_type))
    } else {
        option::none()
    }
}

public fun calculate_fee_for_amount<CoinType>(platform: &Platform, amount: u64): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    if (vec_map::contains(&platform.token_fee_configs, &token_type)) {
        calculate_deposit_fee(amount, vec_map::get(&platform.token_fee_configs, &token_type))
    } else { 0 }
}

public fun has_market_coin_deposit_fees<MarketCoin>(platform: &Platform): bool {
    bag::contains(&platform.deposit_fees, type_name::with_original_ids<MarketCoin>())
}

public fun get_market_coin_deposit_fee_balance<MarketCoin>(platform: &Platform): u64 {
    let t = type_name::with_original_ids<MarketCoin>();
    if (bag::contains(&platform.deposit_fees, t)) {
        let fees: &Balance<MarketCoin> = bag::borrow(&platform.deposit_fees, t);
        balance::value(fees)
    } else { 0 }
}

public fun lock_owner<CoinType>(lock: &Lock<CoinType>): address { lock.owner }
public fun lock_balance_value<CoinType>(lock: &Lock<CoinType>): u64 { lock.balance.value() }
public fun lock_start_time<CoinType>(lock: &Lock<CoinType>): u64 { lock.start_time }
public fun lock_duration_ms<CoinType>(lock: &Lock<CoinType>): u64 { lock.duration_ms }

public fun yield_lock_owner<SCoin>(lock: &YieldLock<SCoin>): address { lock.owner }
public fun yield_lock_principal_amount<SCoin>(lock: &YieldLock<SCoin>): u64 { lock.principal_base_amount }
public fun yield_lock_s_coin_balance_value<SCoin>(lock: &YieldLock<SCoin>): u64 { lock.s_coin_balance.value() }
public fun yield_lock_start_time<SCoin>(lock: &YieldLock<SCoin>): u64 { lock.start_time }
public fun yield_lock_duration_ms<SCoin>(lock: &YieldLock<SCoin>): u64 { lock.duration_ms }
public fun yield_lock_coin_type<SCoin>(lock: &YieldLock<SCoin>): TypeName { lock.coin_type }
public fun yield_lock_strategy<SCoin>(_lock: &YieldLock<SCoin>): u8 { STRATEGY_YIELD }
public fun yield_lock_s_coin_unlocked<SCoin>(lock: &YieldLock<SCoin>): bool { lock.s_coin_unlocked }

public fun platform_tvl_by_token(platform: &Platform): &VecMap<TypeName, u64> { &platform.tvl_by_token }
public fun platform_yield_tvl_by_token(platform: &Platform): &VecMap<TypeName, u64> { &platform.yield_tvl_by_token }
public fun platform_fees(platform: &Platform): &Bag { &platform.fees }
public fun platform_yield_fees(platform: &Platform): &Bag { &platform.yield_fees }
public fun platform_deposit_fees(platform: &Platform): &Bag { &platform.deposit_fees }
public fun get_admin(platform: &Platform): address { platform.admin }
public fun platform_admin_cap_id(platform: &Platform): ID { platform.admin_cap_id }

public fun platform_penalty_bps(platform: &Platform): u64 { platform.penalty_bps }
public fun platform_yield_fee_bps(platform: &Platform): u64 { platform.yield_fee_bps }
public fun platform_default_deposit_fee_bps(platform: &Platform): u64 { platform.default_deposit_fee_bps }
