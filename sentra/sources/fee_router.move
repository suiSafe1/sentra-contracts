module sentra::fee_router;

use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::event;


const ENotAdmin: u64 = 1;
const EFeeTooHigh: u64 = 2;

const MAX_FEE_BPS: u64 = 500;
const BPS_DENOMINATOR: u64 = 10000;


public struct FeeTreasury<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    admin: address,
    fee_bps: u64,
}

public struct SwapEvent has copy, drop {
    user: address,
    coin_in_type: vector<u8>,
    coin_out_type: vector<u8>,
    amount_in: u64,
    amount_out: u64,
    fee_amount: u64,
    timestamp: u64,
}


public entry fun init_treasury<CoinType>(
    fee_bps: u64,
    ctx: &mut TxContext
) {
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    
    let treasury = FeeTreasury<CoinType> {
        id: object::new(ctx),
        balance: balance::zero<CoinType>(),
        admin: tx_context::sender(ctx),
        fee_bps,
    };
    
    transfer::share_object(treasury);
}

public fun take_fee_and_return<CoinIn>(
    treasury: &mut FeeTreasury<CoinIn>,
    mut coin_in: Coin<CoinIn>,
    ctx: &mut TxContext
): Coin<CoinIn> {
    let amount = coin::value(&coin_in);
    
   
    let fee_amount = (amount * treasury.fee_bps) / BPS_DENOMINATOR;

    let fee_coin = coin::split(&mut coin_in, fee_amount, ctx);
    
    balance::join(&mut treasury.balance, coin::into_balance(fee_coin));

    event::emit(SwapEvent {
        user: tx_context::sender(ctx),
        coin_in_type: b"CoinIn",     
        coin_out_type: b"CoinOut",    
        amount_in: amount,
        amount_out: 0,             
        fee_amount,
        timestamp: tx_context::epoch(ctx),
    });

    coin_in
}

public entry fun update_fee<CoinType>(
    treasury: &mut FeeTreasury<CoinType>,
    new_fee_bps: u64,
    ctx: &mut TxContext
) {
    assert!(tx_context::sender(ctx) == treasury.admin, ENotAdmin);
    
    assert!(new_fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    
    treasury.fee_bps = new_fee_bps;
}

public entry fun withdraw_fees<CoinType>(
    treasury: &mut FeeTreasury<CoinType>,
    amount: u64,
    ctx: &mut TxContext
) {
    assert!(tx_context::sender(ctx) == treasury.admin, ENotAdmin);
    
    let withdrawn = coin::take(&mut treasury.balance, amount, ctx);
    
    transfer::public_transfer(withdrawn, treasury.admin);
}


public fun get_fee_bps<CoinType>(treasury: &FeeTreasury<CoinType>): u64 {
    treasury.fee_bps
}

public fun get_collected_fees<CoinType>(treasury: &FeeTreasury<CoinType>): u64 {
    balance::value(&treasury.balance)
}

