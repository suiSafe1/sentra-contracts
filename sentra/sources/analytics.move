module sentra::analytics;

use sui::balance::Balance;
use sui::bag;
use sui::vec_map;
use std::type_name::{Self, TypeName};
use sentra::sentra::{Self, Platform, UserRegistry, Lock, YieldLock};


public struct LockInfo has copy, drop {
    owner: address,
    amount: u64,
    start_time: u64,
    duration_ms: u64,
    strategy: u8,
    unlock_time: u64,
}

public struct YieldLockInfo has copy, drop {
    owner: address,
    principal_amount: u64,
    s_coin_balance: u64,
    start_time: u64,
    duration_ms: u64,
    coin_type: TypeName,
    strategy: u8,
    unlock_time: u64,
}

public struct PlatformStats has copy, drop {
    supported_tokens: vector<TypeName>,
    paused_deposits: bool,
    paused_withdrawals: bool,
    total_tokens_supported: u64,
}

public struct TokenFeeStats has copy, drop {
    penalty_fees: u64,
    yield_fees: u64,
    deposit_fees: u64,
    total_fees: u64,
}

public struct UserLockSummary has copy, drop {
    total_locks: u64,
    total_yield_locks: u64,
    lock_ids: vector<ID>,
    yield_lock_ids: vector<ID>,
}

public struct TVLStats has copy, drop {
    token_type: TypeName,
    total_locked: u64,
    total_yield_locked: u64,
    combined_tvl: u64,
}

public struct GlobalLockStats has copy, drop {
    total_locks: u64,
    total_yield_locks: u64,
    total_users_with_locks: u64,
    total_users_with_yield_locks: u64,
}


public fun get_lock_details<CoinType>(lock: &Lock<CoinType>): LockInfo {
    let start_time = sentra::lock_start_time(lock);
    let duration_ms = sentra::lock_duration_ms(lock);
    
    LockInfo {
        owner: sentra::lock_owner(lock),
        amount: sentra::lock_balance_value(lock),
        start_time,
        duration_ms,
        strategy: sentra::lock_strategy(lock),
        unlock_time: start_time + duration_ms,
    }
}

public fun get_yield_lock_details<MarketCoin>(lock: &YieldLock<MarketCoin>): YieldLockInfo {
    let start_time = sentra::yield_lock_start_time(lock);
    let duration_ms = sentra::yield_lock_duration_ms(lock);
    
    YieldLockInfo {
        owner: sentra::yield_lock_owner(lock),
        principal_amount: sentra::yield_lock_principal_amount(lock),
        s_coin_balance: sentra::yield_lock_s_coin_balance_value(lock),
        start_time,
        duration_ms,
        coin_type: sentra::yield_lock_coin_type(lock),
        strategy: sentra::yield_lock_strategy(lock),
        unlock_time: start_time + duration_ms,
    }
}


public fun get_accumulated_penalty_fees<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let fees_bag = sentra::platform_fees(platform);
    
    if (bag::contains(fees_bag, token_type)) {
        let fees: &Balance<CoinType> = bag::borrow(fees_bag, token_type);
        fees.value()
    } else {
        0
    }
}

public fun get_accumulated_yield_fees<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let yield_fees_bag = sentra::platform_yield_fees(platform);
    
    if (bag::contains(yield_fees_bag, token_type)) {
        let fees: &Balance<CoinType> = bag::borrow(yield_fees_bag, token_type);
        fees.value()
    } else {
        0
    }
}

public fun get_accumulated_deposit_fees<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let deposit_fees_bag = sentra::platform_deposit_fees(platform);
    
    if (bag::contains(deposit_fees_bag, token_type)) {
        let fees: &Balance<CoinType> = bag::borrow(deposit_fees_bag, token_type);
        fees.value()
    } else {
        0
    }
}

public fun get_fee_totals<CoinType>(platform: &Platform): TokenFeeStats {
    let penalty = get_accumulated_penalty_fees<CoinType>(platform);
    let yield_fee = get_accumulated_yield_fees<CoinType>(platform);
    let deposit = get_accumulated_deposit_fees<CoinType>(platform);
    
    TokenFeeStats {
        penalty_fees: penalty,
        yield_fees: yield_fee,
        deposit_fees: deposit,
        total_fees: penalty + yield_fee + deposit,
    }
}


public fun get_tvl<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let tvl_map = sentra::platform_tvl_by_token(platform);
    
    if (vec_map::contains(tvl_map, &token_type)) {
        *vec_map::get(tvl_map, &token_type)
    } else {
        0
    }
}

public fun get_total_yield_locked<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let yield_tvl_map = sentra::platform_yield_tvl_by_token(platform);
    
    if (vec_map::contains(yield_tvl_map, &token_type)) {
        *vec_map::get(yield_tvl_map, &token_type)
    } else {
        0
    }
}

public fun get_tvl_stats<CoinType>(platform: &Platform): TVLStats {
    let token_type = type_name::with_original_ids<CoinType>();
    let regular = get_tvl<CoinType>(platform);
    let yield_locked = get_total_yield_locked<CoinType>(platform);
    
    TVLStats {
        token_type,
        total_locked: regular,
        total_yield_locked: yield_locked,
        combined_tvl: regular + yield_locked,
    }
}

public fun get_all_tvl(platform: &Platform): vector<TVLStats> {
    let mut stats = vector::empty<TVLStats>();
    let tokens = sentra::get_supported_tokens(platform);
    let tvl_map = sentra::platform_tvl_by_token(platform);
    let yield_tvl_map = sentra::platform_yield_tvl_by_token(platform);
    
    let len = vector::length(&tokens);
    let mut i = 0;
    
    while (i < len) {
        let token_type = vector::borrow(&tokens, i);
        let regular = if (vec_map::contains(tvl_map, token_type)) {
            *vec_map::get(tvl_map, token_type)
        } else {
            0
        };
        let yield_locked = if (vec_map::contains(yield_tvl_map, token_type)) {
            *vec_map::get(yield_tvl_map, token_type)
        } else {
            0
        };
        
        vector::push_back(&mut stats, TVLStats {
            token_type: *token_type,
            total_locked: regular,
            total_yield_locked: yield_locked,
            combined_tvl: regular + yield_locked,
        });
        
        i = i + 1;
    };
    
    stats
}


public fun get_all_lock_ids(platform: &Platform): vector<ID> {
    sentra::platform_global_lock_list(platform)
}

public fun get_all_yield_lock_ids(platform: &Platform): vector<ID> {
    sentra::platform_global_yield_lock_list(platform)
}

public fun get_locks_by_token<CoinType>(platform: &Platform): vector<ID> {
    let token_type = type_name::with_original_ids<CoinType>();
    let locks_map = sentra::platform_locks_by_token(platform);
    
    if (vec_map::contains(locks_map, &token_type)) {
        *vec_map::get(locks_map, &token_type)
    } else {
        vector::empty()
    }
}

public fun get_lock_count_by_token<CoinType>(platform: &Platform): u64 {
    let locks = get_locks_by_token<CoinType>(platform);
    vector::length(&locks)
}

public fun get_global_lock_stats(platform: &Platform, registry: &UserRegistry): GlobalLockStats {
    let locks_map = sentra::registry_locks(registry);
    let yield_locks_map = sentra::registry_yield_locks(registry);
    
    GlobalLockStats {
        total_locks: vector::length(&sentra::platform_global_lock_list(platform)),
        total_yield_locks: vector::length(&sentra::platform_global_yield_lock_list(platform)),
        total_users_with_locks: vec_map::length(locks_map),
        total_users_with_yield_locks: vec_map::length(yield_locks_map),
    }
}


public fun get_platform_stats(platform: &Platform): PlatformStats {
    let tokens = sentra::get_supported_tokens(platform);
    let (paused_deposits, paused_withdrawals) = sentra::get_pause_status(platform);
    
    PlatformStats {
        supported_tokens: tokens,
        paused_deposits,
        paused_withdrawals,
        total_tokens_supported: vector::length(&tokens),
    }
}


public fun get_user_lock_summary(registry: &UserRegistry, user: address): UserLockSummary {
    let lock_ids = sentra::get_user_locks(registry, user);
    let yield_lock_ids = sentra::get_user_yield_locks(registry, user);
    
    UserLockSummary {
        total_locks: vector::length(&lock_ids),
        total_yield_locks: vector::length(&yield_lock_ids),
        lock_ids,
        yield_lock_ids,
    }
}

public fun get_total_users_with_locks(registry: &UserRegistry): u64 {
    let locks_map = sentra::registry_locks(registry);
    vec_map::length(locks_map)
}

public fun get_total_users_with_yield_locks(registry: &UserRegistry): u64 {
    let yield_locks_map = sentra::registry_yield_locks(registry);
    vec_map::length(yield_locks_map)
}


public fun get_user_lock_count(registry: &UserRegistry, user: address): u64 {
    let locks = sentra::get_user_locks(registry, user);
    vector::length(&locks)
}

public fun get_user_yield_lock_count(registry: &UserRegistry, user: address): u64 {
    let locks = sentra::get_user_yield_locks(registry, user);
    vector::length(&locks)
}


public fun user_has_locks(registry: &UserRegistry, user: address): bool {
    get_user_lock_count(registry, user) > 0
}

public fun user_has_yield_locks(registry: &UserRegistry, user: address): bool {
    get_user_yield_lock_count(registry, user) > 0
}

public fun user_has_any_locks(registry: &UserRegistry, user: address): bool {
    user_has_locks(registry, user) || user_has_yield_locks(registry, user)
}


public fun is_lock_unlocked(lock_info: &LockInfo, current_time_ms: u64): bool {
    current_time_ms >= lock_info.unlock_time
}

public fun is_yield_lock_unlocked(lock_info: &YieldLockInfo, current_time_ms: u64): bool {
    current_time_ms >= lock_info.unlock_time
}

public fun get_time_until_unlock(unlock_time: u64, current_time_ms: u64): u64 {
    if (current_time_ms >= unlock_time) {
        0
    } else {
        unlock_time - current_time_ms
    }
}


public fun get_multiple_lock_details<CoinType>(locks: &vector<Lock<CoinType>>): vector<LockInfo> {
    let mut details = vector::empty<LockInfo>();
    let len = vector::length(locks);
    let mut i = 0;
    
    while (i < len) {
        let lock = vector::borrow(locks, i);
        vector::push_back(&mut details, get_lock_details(lock));
        i = i + 1;
    };
    
    details
}

public fun get_multiple_yield_lock_details<MarketCoin>(
    locks: &vector<YieldLock<MarketCoin>>
): vector<YieldLockInfo> {
    let mut details = vector::empty<YieldLockInfo>();
    let len = vector::length(locks);
    let mut i = 0;
    
    while (i < len) {
        let lock = vector::borrow(locks, i);
        vector::push_back(&mut details, get_yield_lock_details(lock));
        i = i + 1;
    };
    
    details
}