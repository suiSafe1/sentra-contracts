module sentra::fee_router;

use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::event;
use std::type_name;
use sentra::sentra::{AdminCap, Platform};


const ENotAdmin: u64 = 1;
const EFeeTooHigh: u64 = 2;
const EZeroFee: u64 = 3;          // L-07: disallow zero fee_bps
const EPaused: u64 = 4;           // L-08: pause support
const EZeroAmount: u64 = 5;       // H-05: guard zero-amount withdrawals
const EInsufficientBalance: u64 = 6;

const MAX_FEE_BPS: u64 = 500;
const BPS_DENOMINATOR: u64 = 10000;


public struct FeeTreasury<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    admin: address,
    fee_bps: u64,
    paused: bool,   // L-08
}

// H-05: proper withdrawal event
public struct FeesWithdrawn<phantom CoinType> has copy, drop {
    admin: address,
    amount: u64,
    treasury_id: ID,
}

// M-05: renamed and corrected event
public struct FeeCollectedEvent<phantom CoinIn> has copy, drop {
    user: address,
    coin_in_type: std::ascii::String,
    amount_in: u64,
    fee_amount: u64,
}

public struct FeeUpdated<phantom CoinType> has copy, drop {
    admin: address,
    old_fee_bps: u64,
    new_fee_bps: u64,
}

public struct AdminTransferred<phantom CoinType> has copy, drop {
    old_admin: address,
    new_admin: address,
}

public struct TreasuryPauseChanged<phantom CoinType> has copy, drop {
    admin: address,
    paused: bool,
}


// H-04: gated behind AdminCap from sentra.move — only one authorised deployer
// can create a FeeTreasury, tying it to the same admin model as the main module.
// L-07: fee_bps must be > 0 (a zero-fee treasury is a passthrough with no purpose).
public entry fun init_treasury<CoinType>(
    cap: &AdminCap,
    platform: &Platform,
    fee_bps: u64,
    ctx: &mut TxContext
) {
    // Verify the cap belongs to this platform (same check pattern as sentra.move)
    assert!(object::id(cap) == sentra::sentra::platform_admin_cap_id(platform), ENotAdmin);
    assert!(tx_context::sender(ctx) == sentra::sentra::get_admin(platform), ENotAdmin);
    assert!(fee_bps > 0, EZeroFee);          // L-07
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);

    let treasury = FeeTreasury<CoinType> {
        id: object::new(ctx),
        balance: balance::zero<CoinType>(),
        admin: tx_context::sender(ctx),
        fee_bps,
        paused: false,
    };

    transfer::share_object(treasury);
}

// C-04: use u128 intermediate to prevent overflow on large amounts.
// M-05: emit FeeCollectedEvent with real type name, not hardcoded literals.
// L-08: respect paused flag.
public fun take_fee_and_return<CoinIn>(
    treasury: &mut FeeTreasury<CoinIn>,
    mut coin_in: Coin<CoinIn>,
    ctx: &mut TxContext
): Coin<CoinIn> {
    assert!(!treasury.paused, EPaused); // L-08

    let amount = coin::value(&coin_in);

    // C-04: safe u128 multiply to avoid overflow for large deposits
    let fee_amount = (
        ((amount as u128) * (treasury.fee_bps as u128)) / (BPS_DENOMINATOR as u128)
    ) as u64;

    let fee_coin = coin::split(&mut coin_in, fee_amount, ctx);
    balance::join(&mut treasury.balance, coin::into_balance(fee_coin));

    // M-05: real type name, no placeholder literals, no fake amount_out
    event::emit(FeeCollectedEvent<CoinIn> {
        user: tx_context::sender(ctx),
        coin_in_type: type_name::into_string(type_name::with_original_ids<CoinIn>()),
        amount_in: amount,
        fee_amount,
    });

    coin_in
}

public entry fun update_fee<CoinType>(
    treasury: &mut FeeTreasury<CoinType>,
    new_fee_bps: u64,
    ctx: &mut TxContext
) {
    assert!(tx_context::sender(ctx) == treasury.admin, ENotAdmin);
    assert!(new_fee_bps > 0, EZeroFee);         // L-07
    assert!(new_fee_bps <= MAX_FEE_BPS, EFeeTooHigh);

    let old = treasury.fee_bps;
    treasury.fee_bps = new_fee_bps;

    event::emit(FeeUpdated<CoinType> {
        admin: treasury.admin,
        old_fee_bps: old,
        new_fee_bps,
    });
}

// H-05: emit FeesWithdrawn event; also guard amount > 0 and <= balance.
public entry fun withdraw_fees<CoinType>(
    treasury: &mut FeeTreasury<CoinType>,
    amount: u64,
    ctx: &mut TxContext
) {
    assert!(tx_context::sender(ctx) == treasury.admin, ENotAdmin);
    assert!(amount > 0, EZeroAmount);                                      // H-05
    assert!(amount <= balance::value(&treasury.balance), EInsufficientBalance); // H-05

    let withdrawn = coin::take(&mut treasury.balance, amount, ctx);
    transfer::public_transfer(withdrawn, treasury.admin);

    // H-05: on-chain audit trail for every withdrawal
    event::emit(FeesWithdrawn<CoinType> {
        admin: treasury.admin,
        amount,
        treasury_id: object::id(treasury),
    });
}

// M-06: admin transfer — mirrors the pattern in sentra.move
public entry fun transfer_admin<CoinType>(
    treasury: &mut FeeTreasury<CoinType>,
    new_admin: address,
    ctx: &mut TxContext
) {
    assert!(tx_context::sender(ctx) == treasury.admin, ENotAdmin);

    let old_admin = treasury.admin;
    treasury.admin = new_admin;

    event::emit(AdminTransferred<CoinType> {
        old_admin,
        new_admin,
    });
}

// L-08: pause / unpause fee collection
public entry fun set_paused<CoinType>(
    treasury: &mut FeeTreasury<CoinType>,
    paused: bool,
    ctx: &mut TxContext
) {
    assert!(tx_context::sender(ctx) == treasury.admin, ENotAdmin);
    treasury.paused = paused;

    event::emit(TreasuryPauseChanged<CoinType> {
        admin: treasury.admin,
        paused,
    });
}


public fun get_fee_bps<CoinType>(treasury: &FeeTreasury<CoinType>): u64 {
    treasury.fee_bps
}

public fun get_collected_fees<CoinType>(treasury: &FeeTreasury<CoinType>): u64 {
    balance::value(&treasury.balance)
}

public fun is_paused<CoinType>(treasury: &FeeTreasury<CoinType>): bool {
    treasury.paused
}

public fun get_admin<CoinType>(treasury: &FeeTreasury<CoinType>): address {
    treasury.admin
}
