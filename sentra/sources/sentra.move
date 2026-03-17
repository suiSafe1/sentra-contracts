/// # Sentra Token Locking Protocol
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
use std::type_name::{Self, TypeName};
use std::string::{Self, String};



const EInvalidDuration: u64 = 0;
const EUnauthorized: u64 = 1;
const EPlatformNotFound: u64 = 2;
const EInvalidStrategy: u64 = 3;
const EInvalidAmount: u64 = 5;
const EPaused: u64 = 6;
const EInvalidCapId: u64 = 7;
const EInsufficientForFee: u64 = 8;
const ETokenFeeNotConfigured: u64 = 9;



const PENALTY_BPS: u64 = 200;
const BPS_DENOM: u64 = 10_000;
const YIELD_FEE_BPS: u64 = 3000;
const DEFAULT_DEPOSIT_FEE_BPS: u64 = 10;
const STRATEGY_NO_YIELD: u8 = 0;
const STRATEGY_YIELD: u8 = 1;


/// Standard lock for direct token locking (no yield generation)
///  
/// # Lifecycle
/// 1. Created via create_lock()
/// 2. Can be extended via add_to_lock()
/// 3. Withdrawn via withdraw()
public struct Lock<phantom CoinType> has key, store {
    id: UID,
    balance: Balance<CoinType>,
    owner: address,
    start_time: u64,
    duration_ms: u64,
    strategy: u8,
}

/// Yield-generating lock using Scallop Protocol sCoin
/// 
/// # Important Notes
/// - The actual yield accrues in the sCoin balance
/// - Withdrawal requires redemption of sCoin back to base token
/// - Platform takes 30% of generated yield as fee
public struct YieldLock<phantom SCoin> has key, store {
    id: UID,
    owner: address,
    start_time: u64,
    duration_ms: u64,
    principal_amount: u64,
    coin_type: TypeName,
    strategy: u8,
    s_coin_balance: Balance<SCoin>,
    description: String,
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
    global_lock_list: vector<ID>,
    global_yield_lock_list: vector<ID>,
    locks_by_token: VecMap<TypeName, vector<ID>>,
}


public struct UserRegistry has key, store {
    id: UID,
    locks: VecMap<address, vector<ID>>,
    yield_locks: VecMap<address, vector<ID>>,
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
    strategy: u8,
}

public struct LockExtended<phantom CoinType> has copy, drop, store {
    owner: address,
    added_amount: u64,
    deposit_fee_paid: u64,
    new_total: u64,
    strategy: u8,
}

public struct LockWithdrawn<phantom CoinType> has copy, drop, store {
    owner: address,
    amount_withdrawn: u64,
    withdrawn_time: u64,
    strategy: u8,
}

public struct YieldLockCreated has copy, drop, store {
    owner: address,
    principal_amount: u64,
    deposit_fee_paid: u64,
    coin_type: TypeName,
    start_time: u64,
    duration_ms: u64,
    market_coin_id: ID,
    description: String,
}

public struct YieldLockExtended has copy, drop, store {
    owner: address,
    added_amount: u64,
    deposit_fee_paid: u64,
    new_s_coin_balance: u64,
    new_principal_amount: u64,
    coin_type: TypeName,
}


public struct YieldLockWithdrawn has copy, drop, store {
    owner: address,
    principal_withdrawn: u64,
    yield_earned: u64,
    platform_yield_fee: u64,
    user_yield_amount: u64,
    withdrawn_time: u64,
    coin_type: TypeName,
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
        locks: vec_map::empty(),
        yield_locks: vec_map::empty(),
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
        global_lock_list: vector::empty(),
        global_yield_lock_list: vector::empty(),
        locks_by_token: vec_map::empty(),
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
        
        let token_fees = balance::zero<CoinType>();
        bag::add(&mut platform.fees, token_type, token_fees);
        
        let yield_token_fees = balance::zero<CoinType>();
        bag::add(&mut platform.yield_fees, token_type, yield_token_fees);

        let deposit_token_fees = balance::zero<CoinType>();
        bag::add(&mut platform.deposit_fees, token_type, deposit_token_fees);
        
        let default_config = TokenFeeConfig {
            deposit_fee_bps: DEFAULT_DEPOSIT_FEE_BPS,
            min_deposit_fee: 0,
            max_deposit_fee: 0,
        };
        vec_map::insert(&mut platform.token_fee_configs, token_type, default_config);
        
        vec_map::insert(&mut platform.tvl_by_token, token_type, 0);
        vec_map::insert(&mut platform.yield_tvl_by_token, token_type, 0);
        vec_map::insert(&mut platform.locks_by_token, token_type, vector::empty());
        
        event::emit(TokenAdded {
            token_type,
            admin: sender,
        });
    }
}

/// Add support for Scallop sCoin type for yield locks
/// 
/// # Purpose
/// - sCoin deposit fees are collected separately from base token fees
/// - Required before users can create yield locks with this sCoin
/// 
/// # Example
/// - Base token: SUI -> must call add_token_support<SUI>
/// - sCoin: sSUI -> must call add_s_coin_support<sSUI>
/// 
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
        let deposit_s_coin_fees = balance::zero<SCoin>();
        bag::add(&mut platform.deposit_fees, s_coin_type, deposit_s_coin_fees);
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
    
    let fee_config = TokenFeeConfig {
        deposit_fee_bps,
        min_deposit_fee,
        max_deposit_fee,
    };
    
    if (vec_map::contains(&platform.token_fee_configs, &token_type)) {
        let existing_config = vec_map::get_mut(&mut platform.token_fee_configs, &token_type);
        *existing_config = fee_config;
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


public entry fun request_admin_transfer(
    cap: AdminCap,
    platform: &mut Platform,
    new_admin: address,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(&cap) == platform.admin_cap_id, EInvalidCapId);

    let pending = PendingAdminTransfer {
        id: object::new(ctx),
        cap,
        current_admin: sender,
        new_admin,
    };

    transfer::share_object(pending);
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
    let result = ((amount as u128) * (numerator as u128)) / (denominator as u128);
    (result as u64)
}

fun safe_mul_div_ceil(amount: u64, numerator: u64, denominator: u64): u64 {
    let result = (
        (amount as u128) * (numerator as u128) + (denominator as u128) - 1
    ) / (denominator as u128);
    (result as u64)
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
    
    if (final_fee >= amount) {
        amount - 1
    } else {
        final_fee
    }
}


fun remove_lock_id(locks: &mut vector<ID>, target_id: ID) {
    let len = vector::length(locks);
    let mut i = 0;
    while (i < len) {
        if (*vector::borrow(locks, i) == target_id) {
            vector::swap_remove(locks, i);
            return
        };
        i = i + 1;
    }
}


fun update_tvl<CoinType>(platform: &mut Platform, amount_delta: u64, is_addition: bool) {
    let token_type = type_name::with_original_ids<CoinType>();
    if (vec_map::contains(&platform.tvl_by_token, &token_type)) {
        let current_tvl = vec_map::get_mut(&mut platform.tvl_by_token, &token_type);
        if (is_addition) {
            *current_tvl = *current_tvl + amount_delta;
        } else {
            *current_tvl = *current_tvl - amount_delta;
        }
    }
}


fun update_yield_tvl<CoinType>(platform: &mut Platform, amount_delta: u64, is_addition: bool) {
    let token_type = type_name::with_original_ids<CoinType>();
    if (vec_map::contains(&platform.yield_tvl_by_token, &token_type)) {
        let current_tvl = vec_map::get_mut(&mut platform.yield_tvl_by_token, &token_type);
        if (is_addition) {
            *current_tvl = *current_tvl + amount_delta;
        } else {
            *current_tvl = *current_tvl - amount_delta;
        }
    }
}



/// Create a standard lock (no yield generation)
/// 
/// # Flow
/// 1. Verify deposits are not paused
/// 2. Verify token is supported and configured
/// 3. Calculate and deduct deposit fee
/// 4. Create Lock object with remaining balance
/// 5. Update registry and TVL tracking
/// 6. Transfer Lock to user
/// 
/// # Fee Handling
/// Deposit fee is taken upfront and stored separately from penalties
/// 
public entry fun create_lock<CoinType>(
    platform: &mut Platform,
    registry: &mut UserRegistry,
    mut coin: Coin<CoinType>,
    duration_ms: u64,
    strategy: u8,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!platform.paused_deposits, EPaused);
    assert!(duration_ms > 0, EInvalidDuration);
    assert!(strategy == STRATEGY_NO_YIELD, EInvalidStrategy);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);

    let total_amount = coin.value();
    assert!(total_amount > 1, EInvalidAmount); 

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_coin = coin::split(&mut coin, deposit_fee, ctx);
    let deposit_fee_balance = coin::into_balance(deposit_fee_coin);
    
    let deposit_token_fees: &mut Balance<CoinType> = 
        bag::borrow_mut(&mut platform.deposit_fees, token_type);
    balance::join(deposit_token_fees, deposit_fee_balance);

    let amount = coin.value();
    assert!(amount > 0, EInvalidAmount);

    let now = clock.timestamp_ms();
    let owner = tx_context::sender(ctx);
    let balance = coin::into_balance(coin);

    let lock = Lock {
        id: object::new(ctx),
        balance,
        owner,
        start_time: now,
        duration_ms,
        strategy,
    };

    let lock_id = object::id(&lock);
    
    if (vec_map::contains(&registry.locks, &owner)) {
        let user_locks = vec_map::get_mut(&mut registry.locks, &owner);
        vector::push_back(user_locks, lock_id);
    } else {
        let mut new_locks = vector::empty();
        vector::push_back(&mut new_locks, lock_id);
        vec_map::insert(&mut registry.locks, owner, new_locks);
    };

    update_tvl<CoinType>(platform, amount, true);
    vector::push_back(&mut platform.global_lock_list, lock_id);
    
    if (vec_map::contains(&platform.locks_by_token, &token_type)) {
        let token_locks = vec_map::get_mut(&mut platform.locks_by_token, &token_type);
        vector::push_back(token_locks, lock_id);
    };

    transfer::public_transfer(lock, owner);

    event::emit(LockCreated<CoinType> {
        owner,
        amount,
        deposit_fee_paid: deposit_fee,
        start_time: now,
        duration_ms,
        strategy,
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
    assert!(lock.strategy == STRATEGY_NO_YIELD, EInvalidStrategy);

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);
    
    let total_amount = coin.value();
    assert!(total_amount > 1, EInvalidAmount);

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_coin = coin::split(&mut coin, deposit_fee, ctx);
    let deposit_fee_balance = coin::into_balance(deposit_fee_coin);
    
    let deposit_token_fees: &mut Balance<CoinType> = 
        bag::borrow_mut(&mut platform.deposit_fees, token_type);
    balance::join(deposit_token_fees, deposit_fee_balance);

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
        strategy: lock.strategy,
    });
}

/// Withdraw from a standard lock
/// 
/// # Penalty Logic
/// - If withdrawn before unlock_time: 2% penalty applied
/// - If withdrawn after unlock_time: No penalty
/// 
/// # Process
/// 1. Verify withdrawals not paused
/// 2. Verify caller is lock owner
/// 3. Calculate penalty if early
/// 4. Transfer user amount to user
/// 5. Transfer penalty to platform fee collection
/// 6. Update registry and TVL
/// 7. Destroy lock object
/// 
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

    let Lock { id, mut balance, owner: _, start_time, duration_ms, strategy } = lock;
    assert!(strategy == STRATEGY_NO_YIELD, EInvalidStrategy);
    
    let lock_id = object::uid_to_inner(&id);

    let unlock_time = start_time + duration_ms;
    let total_amount = balance.value();
    let now = clock.timestamp_ms();

    let (user_amount, penalty) = if (now >= unlock_time) {
        (total_amount, 0)
    } else {
        let pen = safe_mul_div(total_amount, PENALTY_BPS, BPS_DENOM);
        (total_amount - pen, pen)
    };

    if (user_amount > 0) {
        let coin_user = coin::take(&mut balance, user_amount, ctx);
        transfer::public_transfer(coin_user, sender);
    };

    if (penalty > 0) {
        let coin_penalty = coin::take(&mut balance, penalty, ctx);
        let penalty_balance = coin::into_balance(coin_penalty);

        let token_fees: &mut Balance<CoinType> = 
            bag::borrow_mut(&mut platform.fees, token_type);
        balance::join(token_fees, penalty_balance);
    };

    if (vec_map::contains(&registry.locks, &sender)) {
        let user_locks = vec_map::get_mut(&mut registry.locks, &sender);
        remove_lock_id(user_locks, lock_id);
        if (vector::is_empty(user_locks)) {
            vec_map::remove(&mut registry.locks, &sender);
        }
    };

    update_tvl<CoinType>(platform, total_amount, false);
    remove_lock_id(&mut platform.global_lock_list, lock_id);
    
    if (vec_map::contains(&platform.locks_by_token, &token_type)) {
        let token_locks = vec_map::get_mut(&mut platform.locks_by_token, &token_type);
        remove_lock_id(token_locks, lock_id);
    };

    event::emit(LockWithdrawn<CoinType> {
        owner: sender,
        amount_withdrawn: user_amount,
        withdrawn_time: now,
        strategy,
    });

    balance::destroy_zero(balance);
    object::delete(id);
}


/// Create a yield lock using Scallop sCoin
/// 
/// # Integration with Scallop
/// 1. User deposits CoinType to Scallop (done on frontend via SDK)
/// 2. Scallop mints SCoin to user
/// 3. User calls this function with SCoin
/// 4. SCoin is locked and accrues yield from Scallop
/// 
/// # Important Notes
/// - `principal_amount`: The amount of SCoin deposited (for penalty calculations)
/// - `coin_type`: The underlying token type (e.g., SUI), not SCoin type
/// - Yield accrues in the s_coin_balance automatically via Scallop
/// 
public entry fun create_yield_lock<CoinType, SCoin>(
    platform: &mut Platform,
    registry: &mut UserRegistry,
    mut s_coin: Coin<SCoin>,
    duration_ms: u64,
    description: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(!platform.paused_deposits, EPaused);
    assert!(duration_ms > 0, EInvalidDuration);

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

    let deposit_fee_coin = coin::split(&mut s_coin, deposit_fee, ctx);
    let deposit_fee_balance = coin::into_balance(deposit_fee_coin);
    
    let deposit_token_fees: &mut Balance<SCoin> = 
        bag::borrow_mut(&mut platform.deposit_fees, s_coin_type);
    balance::join(deposit_token_fees, deposit_fee_balance);

    let principal_amount = coin::value(&s_coin);
    assert!(principal_amount > 0, EInvalidAmount);

    let now = clock.timestamp_ms();
    let owner = tx_context::sender(ctx);
    let s_coin_balance = coin::into_balance(s_coin);
    let description_str = string::utf8(description);

    let yield_lock = YieldLock<SCoin> {
        id: object::new(ctx),
        owner,
        start_time: now,
        duration_ms,
        principal_amount,
        coin_type: token_type,
        strategy: STRATEGY_YIELD,
        s_coin_balance,
        description: description_str,
    };

    let lock_id = object::id(&yield_lock);
    
    if (vec_map::contains(&registry.yield_locks, &owner)) {
        let user_yield_locks = vec_map::get_mut(&mut registry.yield_locks, &owner);
        vector::push_back(user_yield_locks, lock_id);
    } else {
        let mut new_yield_locks = vector::empty();
        vector::push_back(&mut new_yield_locks, lock_id);
        vec_map::insert(&mut registry.yield_locks, owner, new_yield_locks);
    };

    update_yield_tvl<CoinType>(platform, principal_amount, true);
    vector::push_back(&mut platform.global_yield_lock_list, lock_id);

    transfer::public_transfer(yield_lock, owner);

    event::emit(YieldLockCreated {
        owner,
        principal_amount,
        deposit_fee_paid: deposit_fee,
        coin_type: token_type,
        start_time: now,
        duration_ms,
        market_coin_id: lock_id,
        description: description_str,
    });
}

/// Add SCoin to an existing yield lock
/// 
/// # Similar to add_to_lock but for yield locks
/// - Deposit fee is charged on added SCoin amount
/// - principal_amount is increased for penalty calculations
/// - Lock duration is NOT extended
public entry fun add_to_yield_lock<CoinType, SCoin>(
    yield_lock: &mut YieldLock<SCoin>,
    platform: &mut Platform,
    mut s_coin: Coin<SCoin>,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == yield_lock.owner, EUnauthorized);
    assert!(yield_lock.strategy == STRATEGY_YIELD, EInvalidStrategy);

    let token_type = type_name::with_original_ids<CoinType>();
    let s_coin_type = type_name::with_original_ids<SCoin>();
    
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(vec_map::contains(&platform.token_fee_configs, &token_type), ETokenFeeNotConfigured);
    assert!(yield_lock.coin_type == token_type, EPlatformNotFound);
    
    let total_amount = coin::value(&s_coin);
    assert!(total_amount > 1, EInvalidAmount);

    let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
    let deposit_fee = calculate_deposit_fee(total_amount, fee_config);
    
    assert!(total_amount > deposit_fee, EInsufficientForFee);

    let deposit_fee_coin = coin::split(&mut s_coin, deposit_fee, ctx);
    let deposit_fee_balance = coin::into_balance(deposit_fee_coin);
    
    let deposit_token_fees: &mut Balance<SCoin> = 
        bag::borrow_mut(&mut platform.deposit_fees, s_coin_type);
    balance::join(deposit_token_fees, deposit_fee_balance);

    let added_balance = coin::into_balance(s_coin);
    let added_amount = added_balance.value();
    balance::join(&mut yield_lock.s_coin_balance, added_balance);
    
    yield_lock.principal_amount = yield_lock.principal_amount + added_amount;

    update_yield_tvl<CoinType>(platform, added_amount, true);

    event::emit(YieldLockExtended {
        owner: sender,
        added_amount,
        deposit_fee_paid: deposit_fee,
        new_s_coin_balance: yield_lock.s_coin_balance.value(),
        new_principal_amount: yield_lock.principal_amount,
        coin_type: token_type,
    });
}

/// Step 1 of yield lock withdrawal: Unlock SCoin from contract
/// 
/// # Two-Step Withdrawal Process
/// 1. unlock_yield_lock_s_coin: Returns SCoin to user
/// 2. User redeems SCoin to base token via Scallop SDK (frontend)
/// 3. complete_yield_withdrawal_with_redeemed_coin: Final settlement
/// 
/// # Returns
/// The SCoin which must be redeemed via Scallop before final completion
/// 
/// # Important
/// - This does NOT complete the withdrawal
/// - YieldLock object remains until step 3
/// - User must call complete_yield_withdrawal_with_redeemed_coin next
public fun unlock_yield_lock_s_coin<SCoin>(
    yield_lock: &mut YieldLock<SCoin>,
    platform: &Platform,
    ctx: &mut TxContext
) : Coin<SCoin> {
    assert!(!platform.paused_withdrawals, EPaused);

    let sender = tx_context::sender(ctx);
    assert!(sender == yield_lock.owner, EUnauthorized);

    let amount = yield_lock.s_coin_balance.value();
    let s_coin = coin::take(&mut yield_lock.s_coin_balance, amount, ctx);

    s_coin
}

/// Step 3: Complete yield lock withdrawal with redeemed base tokens
/// 
/// # Called After
/// 1. unlock_yield_lock_s_coin (returns SCoin)
/// 2. Frontend redeems SCoin → base token via Scallop SDK
/// 3. This function completes withdrawal with base tokens
/// 
/// # Fee & Penalty Distribution
/// 1. Calculate yield: redeemed_amount - principal_amount
/// 2. If early: Apply 2% penalty on principal
/// 3. Platform takes 30% of yield
/// 4. User receives: (principal - penalty) + (yield * 70%)
/// 
/// # Important
/// - `redeemed_coin` must contain at least enough to cover penalties and fees
/// - Excess is returned to user
/// - YieldLock object is consumed (destroyed)
/// 
/// # Example
/// Principal: 1000, Redeemed: 1100 (100 yield), Early withdrawal
/// - Penalty: 1000 * 2% = 20
/// - Platform yield fee: 100 * 30% = 30
/// - User gets: (1000 - 20) + (100 - 30) = 980 + 70 = 1050
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

    let YieldLock {
        id,
        owner: _owner_unused,
        start_time,
        duration_ms,
        principal_amount,
        coin_type: stored_token_type,
        strategy: _,
        s_coin_balance,
        description: _,
    } = yield_lock;

    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);
    assert!(stored_token_type == token_type, EPlatformNotFound);

    let lock_id = object::uid_to_inner(&id);
    let now = clock.timestamp_ms();
    let unlock_time = start_time + duration_ms;

    let maybe_s_coin = coin::from_balance(s_coin_balance, ctx);
    coin::destroy_zero(maybe_s_coin);

    let total_redeemed_amount = redeemed_coin.value();

    let available_principal = if (total_redeemed_amount >= principal_amount) {
        principal_amount
    } else {
        total_redeemed_amount
    };

    let total_yield = if (total_redeemed_amount > principal_amount) {
        total_redeemed_amount - principal_amount
    } else {
        0
    };

    let (user_principal, penalty) = if (now >= unlock_time) {
        (available_principal, 0)
    } else {
        let pen = safe_mul_div(principal_amount, PENALTY_BPS, BPS_DENOM);
        let actual_penalty = if (pen > total_redeemed_amount) { 
            total_redeemed_amount 
        } else { 
            pen 
        };
        let user_gets = if (available_principal > actual_penalty) { 
            available_principal - actual_penalty 
        } else { 
            0 
        };
        (user_gets, actual_penalty)
    };

    let (platform_yield_fee, user_yield_amount) = if (total_yield > 0) {
        let fee = safe_mul_div(total_yield, YIELD_FEE_BPS, BPS_DENOM);
        (fee, total_yield - fee)
    } else {
        (0, 0)
    };

    let user_total_amount = user_principal + user_yield_amount;
    let platform_total_fees = penalty + platform_yield_fee;
    let total_needed = user_total_amount + platform_total_fees;

    assert!(total_needed <= redeemed_coin.value(), EInvalidAmount);

    if (user_total_amount > 0) {
        let user_coin = coin::split(&mut redeemed_coin, user_total_amount, ctx);
        transfer::public_transfer(user_coin, sender);
    };

    if (platform_total_fees > 0) {
        let platform_fees_coin = coin::split(&mut redeemed_coin, platform_total_fees, ctx);
        let mut platform_balance = coin::into_balance(platform_fees_coin);

        if (penalty > 0) {
            let penalty_balance = balance::split(&mut platform_balance, penalty);
            let token_fees: &mut Balance<CoinType> = bag::borrow_mut(&mut platform.fees, token_type);
            balance::join(token_fees, penalty_balance);
        };

        if (platform_yield_fee > 0) {
            let yield_token_fees: &mut Balance<CoinType> = bag::borrow_mut(&mut platform.yield_fees, token_type);
            balance::join(yield_token_fees, platform_balance);
        } else {
            balance::destroy_zero(platform_balance);
        };
    };

    if (coin::value(&redeemed_coin) > 0) {
        transfer::public_transfer(redeemed_coin, sender);
    } else {
        coin::destroy_zero(redeemed_coin);
    };

    if (vec_map::contains(&registry.yield_locks, &sender)) {
        let user_yield_locks = vec_map::get_mut(&mut registry.yield_locks, &sender);
        remove_lock_id(user_yield_locks, lock_id);
        if (vector::is_empty(user_yield_locks)) {
            vec_map::remove(&mut registry.yield_locks, &sender);
        }
    };

    update_yield_tvl<CoinType>(platform, principal_amount, false);
    remove_lock_id(&mut platform.global_yield_lock_list, lock_id);

    event::emit(YieldLockWithdrawn {
        owner: sender,
        principal_withdrawn: user_principal,
        yield_earned: total_yield,
        platform_yield_fee,
        user_yield_amount,
        withdrawn_time: now,
        coin_type: token_type,
    });

    object::delete(id);
}


public entry fun collect_fees<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);
    
    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);

    let token_fees: &mut Balance<CoinType> = 
        bag::borrow_mut(&mut platform.fees, token_type);
    
    let amount = balance::value(token_fees);
    
    if (amount > 0) {
        let all_fees = balance::withdraw_all(token_fees);
        let fee_coin = coin::from_balance(all_fees, ctx);
        transfer::public_transfer(fee_coin, sender);
        
        event::emit(FeesCollected<CoinType> {
            admin: sender,
            amount,
            fee_type: 0,
        });
    }
}


public entry fun collect_yield_fees<CoinType>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);
    
    let token_type = type_name::with_original_ids<CoinType>();
    assert!(vector::contains(&platform.supported_tokens, &token_type), EPlatformNotFound);

    let yield_token_fees: &mut Balance<CoinType> = 
        bag::borrow_mut(&mut platform.yield_fees, token_type);
    
    let amount = balance::value(yield_token_fees);
    
    if (amount > 0) {
        let all_yield_fees = balance::withdraw_all(yield_token_fees);
        let yield_fee_coin = coin::from_balance(all_yield_fees, ctx);
        transfer::public_transfer(yield_fee_coin, sender);
        
        event::emit(FeesCollected<CoinType> {
            admin: sender,
            amount,
            fee_type: 1,
        });
    }
}


public entry fun collect_deposit_fees<SCoin>(
    cap: &AdminCap,
    platform: &mut Platform,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == platform.admin, EUnauthorized);
    assert!(object::id(cap) == platform.admin_cap_id, EInvalidCapId);
    
    let s_coin_type = type_name::with_original_ids<SCoin>();
    assert!(bag::contains(&platform.deposit_fees, s_coin_type), EPlatformNotFound);

    let deposit_token_fees: &mut Balance<SCoin> = 
        bag::borrow_mut(&mut platform.deposit_fees, s_coin_type);
    
    let amount = balance::value(deposit_token_fees);
    
    if (amount > 0) {
        let all_deposit_fees = balance::withdraw_all(deposit_token_fees);
        let deposit_fee_coin = coin::from_balance(all_deposit_fees, ctx);
        transfer::public_transfer(deposit_fee_coin, sender);
        
        event::emit(FeesCollected<SCoin> {
            admin: sender,
            amount,
            fee_type: 2,
        });
    }
}


public fun get_supported_tokens(platform: &Platform): vector<TypeName> {
    platform.supported_tokens
}

public fun is_token_supported<CoinType>(platform: &Platform): bool {
    let token_type = type_name::with_original_ids<CoinType>();
    vector::contains(&platform.supported_tokens, &token_type)
}

public fun get_pause_status(platform: &Platform): (bool, bool) {
    (platform.paused_deposits, platform.paused_withdrawals)
}

public fun get_user_locks(registry: &UserRegistry, user: address): vector<ID> {
    if (vec_map::contains(&registry.locks, &user)) {
        *vec_map::get(&registry.locks, &user)
    } else {
        vector::empty()
    }
}

public fun get_user_yield_locks(registry: &UserRegistry, user: address): vector<ID> {
    if (vec_map::contains(&registry.yield_locks, &user)) {
        *vec_map::get(&registry.yield_locks, &user)
    } else {
        vector::empty()
    }
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
        let fee_config = vec_map::get(&platform.token_fee_configs, &token_type);
        calculate_deposit_fee(amount, fee_config)
    } else {
        0
    }
}

public fun has_market_coin_deposit_fees<MarketCoin>(platform: &Platform): bool {
    let market_coin_type = type_name::with_original_ids<MarketCoin>();
    bag::contains(&platform.deposit_fees, market_coin_type)
}

public fun get_market_coin_deposit_fee_balance<MarketCoin>(platform: &Platform): u64 {
    let market_coin_type = type_name::with_original_ids<MarketCoin>();
    if (bag::contains(&platform.deposit_fees, market_coin_type)) {
        let deposit_fees: &Balance<MarketCoin> = bag::borrow(&platform.deposit_fees, market_coin_type);
        balance::value(deposit_fees)
    } else {
        0
    }
}

public fun lock_owner<CoinType>(lock: &Lock<CoinType>): address {
    lock.owner
}

public fun lock_balance_value<CoinType>(lock: &Lock<CoinType>): u64 {
    lock.balance.value()
}

public fun lock_start_time<CoinType>(lock: &Lock<CoinType>): u64 {
    lock.start_time
}

public fun lock_duration_ms<CoinType>(lock: &Lock<CoinType>): u64 {
    lock.duration_ms
}

public fun lock_strategy<CoinType>(lock: &Lock<CoinType>): u8 {
    lock.strategy
}

public fun yield_lock_owner<MarketCoin>(lock: &YieldLock<MarketCoin>): address {
    lock.owner
}

public fun yield_lock_principal_amount<MarketCoin>(lock: &YieldLock<MarketCoin>): u64 {
    lock.principal_amount
}

public fun yield_lock_s_coin_balance_value<SCoin>(lock: &YieldLock<SCoin>): u64 {
    lock.s_coin_balance.value()
}

public fun yield_lock_start_time<MarketCoin>(lock: &YieldLock<MarketCoin>): u64 {
    lock.start_time
}

public fun yield_lock_duration_ms<MarketCoin>(lock: &YieldLock<MarketCoin>): u64 {
    lock.duration_ms
}

public fun yield_lock_coin_type<MarketCoin>(lock: &YieldLock<MarketCoin>): TypeName {
    lock.coin_type
}

public fun yield_lock_strategy<MarketCoin>(lock: &YieldLock<MarketCoin>): u8 {
    lock.strategy
}

public fun platform_tvl_by_token(platform: &Platform): &VecMap<TypeName, u64> {
    &platform.tvl_by_token
}

public fun platform_yield_tvl_by_token(platform: &Platform): &VecMap<TypeName, u64> {
    &platform.yield_tvl_by_token
}

public fun platform_global_lock_list(platform: &Platform): vector<ID> {
    platform.global_lock_list
}

public fun platform_global_yield_lock_list(platform: &Platform): vector<ID> {
    platform.global_yield_lock_list
}

public fun platform_locks_by_token(platform: &Platform): &VecMap<TypeName, vector<ID>> {
    &platform.locks_by_token
}

public fun platform_fees(platform: &Platform): &Bag {
    &platform.fees
}

public fun platform_yield_fees(platform: &Platform): &Bag {
    &platform.yield_fees
}

public fun platform_deposit_fees(platform: &Platform): &Bag {
    &platform.deposit_fees
}

public fun registry_locks(registry: &UserRegistry): &VecMap<address, vector<ID>> {
    &registry.locks
}

public fun registry_yield_locks(registry: &UserRegistry): &VecMap<address, vector<ID>> {
    &registry.yield_locks
}

public fun get_admin(platform: &Platform): address {
    platform.admin
}