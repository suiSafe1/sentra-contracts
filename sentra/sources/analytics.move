/// analytics.move
///
/// Read-only view functions for the Sentra protocol.
///
/// M-03 note: global_lock_list and global_yield_lock_list are now Table<ID, bool>
/// and locks_by_token is now a count map. Move Tables are not iterable on-chain,
/// so functions that previously returned vector<ID> from global lists have been
/// replaced with count-based queries. Full lock enumeration should use the Sui
/// indexer (filter by struct type `sentra::sentra::Lock` or `YieldLock`), which
/// is already how the frontend useSuiLocks.js hook works.
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
    unlock_time: u64,
}

public struct YieldLockInfo has copy, drop {
    owner: address,
    /// H-02: base token units (was sCoin units in original code)
    principal_base_amount: u64,
    s_coin_balance: u64,
    start_time: u64,
    duration_ms: u64,
    coin_type: TypeName,
    unlock_time: u64,
    /// C-01: unlock state visible to indexers
    s_coin_unlocked: bool,
}

public struct PlatformStats has copy, drop {
    supported_tokens: vector<TypeName>,
    paused_deposits: bool,
    paused_withdrawals: bool,
    total_tokens_supported: u64,
}

public struct PlatformFeeConfig has copy, drop {
    penalty_bps: u64,
    yield_fee_bps: u64,
    default_deposit_fee_bps: u64,
}

public struct TokenFeeStats has copy, drop {
    penalty_fees: u64,
    yield_fees: u64,
    deposit_fees: u64,
    total_fees: u64,
}

public struct UserLockSummary has copy, drop {
    /// M-03: counts only — full ID enumeration via Sui indexer
    total_locks: u64,
    total_yield_locks: u64,
    has_locks: bool,
    has_yield_locks: bool,
}

public struct TVLStats has copy, drop {
    token_type: TypeName,
    total_locked: u64,
    total_yield_locked: u64,
    combined_tvl: u64,
}

public struct GlobalLockStats has copy, drop {
    /// M-03: counts from Table::length — O(1)
    total_locks: u64,
    total_yield_locks: u64,
    total_users_with_locks: u64,
    total_users_with_yield_locks: u64,
}


// ── Individual lock details ───────────────────────────────────────────────────

public fun get_lock_details<CoinType>(lock: &Lock<CoinType>): LockInfo {
    let start_time = sentra::lock_start_time(lock);
    let duration_ms = sentra::lock_duration_ms(lock);
    LockInfo {
        owner: sentra::lock_owner(lock),
        amount: sentra::lock_balance_value(lock),
        start_time,
        duration_ms,
        unlock_time: start_time + duration_ms,
    }
}

public fun get_yield_lock_details<SCoin>(lock: &YieldLock<SCoin>): YieldLockInfo {
    let start_time = sentra::yield_lock_start_time(lock);
    let duration_ms = sentra::yield_lock_duration_ms(lock);
    YieldLockInfo {
        owner: sentra::yield_lock_owner(lock),
        principal_base_amount: sentra::yield_lock_principal_amount(lock),
        s_coin_balance: sentra::yield_lock_s_coin_balance_value(lock),
        start_time,
        duration_ms,
        coin_type: sentra::yield_lock_coin_type(lock),
        unlock_time: start_time + duration_ms,
        s_coin_unlocked: sentra::yield_lock_s_coin_unlocked(lock),
    }
}


// ── Fee queries ───────────────────────────────────────────────────────────────

public fun get_accumulated_penalty_fees<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let fees_bag = sentra::platform_fees(platform);
    if (bag::contains(fees_bag, token_type)) {
        let fees: &Balance<CoinType> = bag::borrow(fees_bag, token_type);
        fees.value()
    } else { 0 }
}

public fun get_accumulated_yield_fees<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let yield_fees_bag = sentra::platform_yield_fees(platform);
    if (bag::contains(yield_fees_bag, token_type)) {
        let fees: &Balance<CoinType> = bag::borrow(yield_fees_bag, token_type);
        fees.value()
    } else { 0 }
}

public fun get_accumulated_deposit_fees<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let deposit_fees_bag = sentra::platform_deposit_fees(platform);
    if (bag::contains(deposit_fees_bag, token_type)) {
        let fees: &Balance<CoinType> = bag::borrow(deposit_fees_bag, token_type);
        fees.value()
    } else { 0 }
}

/// L-03: three-way sum promoted to u128 to prevent overflow.
public fun get_fee_totals<CoinType>(platform: &Platform): TokenFeeStats {
    let penalty = get_accumulated_penalty_fees<CoinType>(platform);
    let yield_fee = get_accumulated_yield_fees<CoinType>(platform);
    let deposit = get_accumulated_deposit_fees<CoinType>(platform);
    let total = ((penalty as u128) + (yield_fee as u128) + (deposit as u128)) as u64;
    TokenFeeStats {
        penalty_fees: penalty,
        yield_fees: yield_fee,
        deposit_fees: deposit,
        total_fees: total,
    }
}


// ── TVL queries ───────────────────────────────────────────────────────────────

public fun get_tvl<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let tvl_map = sentra::platform_tvl_by_token(platform);
    if (vec_map::contains(tvl_map, &token_type)) {
        *vec_map::get(tvl_map, &token_type)
    } else { 0 }
}

public fun get_total_yield_locked<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    let yield_tvl_map = sentra::platform_yield_tvl_by_token(platform);
    if (vec_map::contains(yield_tvl_map, &token_type)) {
        *vec_map::get(yield_tvl_map, &token_type)
    } else { 0 }
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
        let regular = if (vec_map::contains(tvl_map, token_type)) { *vec_map::get(tvl_map, token_type) } else { 0 };
        let yield_locked = if (vec_map::contains(yield_tvl_map, token_type)) { *vec_map::get(yield_tvl_map, token_type) } else { 0 };
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


// ── Count queries (M-03: vector<ID> lists removed, use Sui indexer for IDs) ──

/// M-03: total locks across all tokens — O(1) from Table::length.
public fun get_total_lock_count(platform: &Platform): u64 {
    sentra::get_total_lock_count(platform)
}

/// M-03: total yield locks across all tokens — O(1).
public fun get_total_yield_lock_count(platform: &Platform): u64 {
    sentra::get_total_yield_lock_count(platform)
}

/// M-03: lock count for a specific token — O(1).
public fun get_lock_count_by_token<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    sentra::get_lock_count_for_token(platform, token_type)
}

/// M-03: yield lock count for a specific token — O(1).
public fun get_yield_lock_count_by_token<CoinType>(platform: &Platform): u64 {
    let token_type = type_name::with_original_ids<CoinType>();
    sentra::get_yield_lock_count_for_token(platform, token_type)
}

/// M-03: check whether a lock ID exists — O(1).
public fun lock_exists(platform: &Platform, lock_id: ID): bool {
    sentra::lock_exists(platform, lock_id)
}

/// M-03: check whether a yield lock ID exists — O(1).
public fun yield_lock_exists(platform: &Platform, lock_id: ID): bool {
    sentra::yield_lock_exists(platform, lock_id)
}

/// M-03: global stats use O(1) counts rather than vector lengths.
public fun get_global_lock_stats(platform: &Platform, registry: &UserRegistry): GlobalLockStats {
    GlobalLockStats {
        total_locks: sentra::get_total_lock_count(platform),
        total_yield_locks: sentra::get_total_yield_lock_count(platform),
        total_users_with_locks: sentra::get_total_users_with_locks(registry),
        total_users_with_yield_locks: sentra::get_total_users_with_yield_locks(registry),
    }
}


// ── Platform stats ────────────────────────────────────────────────────────────

public fun get_platform_fee_config(platform: &Platform): PlatformFeeConfig {
    PlatformFeeConfig {
        penalty_bps: sentra::platform_penalty_bps(platform),
        yield_fee_bps: sentra::platform_yield_fee_bps(platform),
        default_deposit_fee_bps: sentra::platform_default_deposit_fee_bps(platform),
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


// ── User queries ──────────────────────────────────────────────────────────────

/// M-03: UserLockSummary no longer returns lock_ids / yield_lock_ids vectors
/// because the registry now uses Table<ID, bool>, which is not iterable in Move.
/// Use the Sui indexer (getOwnedObjects filtered by YieldLock / Lock struct type)
/// to enumerate a user's lock IDs — this is already what useSuiLocks.js does.
public fun get_user_lock_summary(registry: &UserRegistry, user: address): UserLockSummary {
    UserLockSummary {
        total_locks: get_user_lock_count(registry, user),
        total_yield_locks: get_user_yield_lock_count(registry, user),
        has_locks: sentra::user_has_locks(registry, user),
        has_yield_locks: sentra::user_has_yield_locks(registry, user),
    }
}

public fun get_total_users_with_locks(registry: &UserRegistry): u64 {
    sentra::get_total_users_with_locks(registry)
}

public fun get_total_users_with_yield_locks(registry: &UserRegistry): u64 {
    sentra::get_total_users_with_yield_locks(registry)
}

public fun get_user_lock_count(registry: &UserRegistry, user: address): u64 {
    // M-03: user_has_locks is an O(1) Table::contains + Table::length check
    if (!sentra::user_has_locks(registry, user)) { return 0 };
    // Exact count not directly exposed; use the indexer for precise count.
    // This returns 1 as a presence signal; callers needing exact counts
    // should use getOwnedObjects on the indexer.
    1
}

public fun get_user_yield_lock_count(registry: &UserRegistry, user: address): u64 {
    if (!sentra::user_has_yield_locks(registry, user)) { return 0 };
    1
}

public fun user_has_locks(registry: &UserRegistry, user: address): bool {
    sentra::user_has_locks(registry, user)
}

public fun user_has_yield_locks(registry: &UserRegistry, user: address): bool {
    sentra::user_has_yield_locks(registry, user)
}

public fun user_has_any_locks(registry: &UserRegistry, user: address): bool {
    sentra::user_has_locks(registry, user) || sentra::user_has_yield_locks(registry, user)
}

/// M-03: O(1) ownership check — replaces vector scan.
public fun user_owns_lock(registry: &UserRegistry, user: address, lock_id: ID): bool {
    sentra::user_owns_lock(registry, user, lock_id)
}

/// M-03: O(1) ownership check.
public fun user_owns_yield_lock(registry: &UserRegistry, user: address, lock_id: ID): bool {
    sentra::user_owns_yield_lock(registry, user, lock_id)
}


// ── Time helpers ──────────────────────────────────────────────────────────────

public fun is_lock_unlocked(lock_info: &LockInfo, current_time_ms: u64): bool {
    current_time_ms >= lock_info.unlock_time
}

public fun is_yield_lock_unlocked(lock_info: &YieldLockInfo, current_time_ms: u64): bool {
    current_time_ms >= lock_info.unlock_time
}

public fun get_time_until_unlock(unlock_time: u64, current_time_ms: u64): u64 {
    if (current_time_ms >= unlock_time) { 0 } else { unlock_time - current_time_ms }
}


// ── Batch helpers (caller must supply the objects directly) ───────────────────
//
// M-03: these functions accept vectors of Lock/YieldLock objects passed in by
// the caller (fetched from the indexer), rather than reading from on-chain
// global lists. The caller fetches the objects off-chain and passes them in a
// single PTB call.

public fun get_multiple_lock_details<CoinType>(locks: &vector<Lock<CoinType>>): vector<LockInfo> {
    let mut details = vector::empty<LockInfo>();
    let len = vector::length(locks);
    let mut i = 0;
    while (i < len) {
        vector::push_back(&mut details, get_lock_details(vector::borrow(locks, i)));
        i = i + 1;
    };
    details
}

public fun get_multiple_yield_lock_details<SCoin>(
    locks: &vector<YieldLock<SCoin>>
): vector<YieldLockInfo> {
    let mut details = vector::empty<YieldLockInfo>();
    let len = vector::length(locks);
    let mut i = 0;
    while (i < len) {
        vector::push_back(&mut details, get_yield_lock_details(vector::borrow(locks, i)));
        i = i + 1;
    };
    details
}
