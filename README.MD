# Sentra

A token locking protocol built on Sui. Sentra allows users to lock tokens for a fixed duration, generating yield through Scallop Protocol integration, with a configurable fee structure and admin governance controls.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Modules](#modules)
  - [sentra::sentra](#sentrassentra)
  - [sentra::analytics](#sentraanalytics)
  - [sentra::fee_router](#sentrafee_router)
- [Lock Strategies](#lock-strategies)
- [Fee Structure](#fee-structure)
- [Protocol Flow](#protocol-flow)
  - [Standard Lock](#standard-lock)
  - [Yield Lock](#yield-lock)
- [Admin Controls](#admin-controls)
- [Constants](#constants)
- [Error Codes](#error-codes)
- [Development](#development)
  - [Prerequisites](#prerequisites)
  - [Build](#build)
  - [Test](#test)
- [Security Considerations](#security-considerations)

---

## Overview

Sentra is a non-custodial token locking protocol that supports two strategies:

- **No-Yield Lock** — Tokens are locked directly in the contract for a user-defined duration. Early withdrawal incurs a 2% penalty redistributed to the platform.
- **Yield Lock** — Tokens are deposited into Scallop Protocol to accrue yield. The underlying sCoin is held in the lock. On withdrawal, the platform takes 30% of any generated yield.

The protocol supports multiple tokens simultaneously, with per-token fee configuration, TVL tracking, and a two-step admin transfer mechanism.

---

## Architecture

```
sentra/
├── sources/
│   ├── sentra.move        # Core locking protocol
│   ├── analytics.move     # Read-only view functions and aggregations
│   └── fee_router.move    # Standalone swap fee collection utility
├── tests/
│   └── sentra_tests.move  # Unit tests
└── Move.toml
```

---

## Modules

### sentra::sentra

The core protocol module. Manages the `Platform` shared object, `UserRegistry`, lock lifecycle, fee collection, and admin governance.

**Shared objects created on deployment:**

- `Platform` — holds all fee bags, TVL maps, supported token list, and admin state
- `UserRegistry` — maps user addresses to their lock and yield lock IDs

**Owned objects:**

- `AdminCap` — capability object transferred to the deployer; required for all privileged operations

### sentra::analytics

A read-only module providing aggregated views over platform and registry state. No writes occur in this module.

Key views include:

- Lock and yield lock details (`LockInfo`, `YieldLockInfo`)
- Per-token TVL statistics (`TVLStats`)
- Fee accumulation by type (`TokenFeeStats`)
- User lock summaries and counts
- Platform-wide lock statistics

### sentra::fee_router

A standalone fee collection utility for swap routing. Creates a `FeeTreasury` shared object per coin type. Takes a configurable fee (capped at 500 bps) from inbound coins before returning the remainder to the caller.

---

## Lock Strategies

| Strategy | Constant                | Description                         |
| -------- | ----------------------- | ----------------------------------- |
| No-Yield | `STRATEGY_NO_YIELD` (0) | Tokens locked directly in contract  |
| Yield    | `STRATEGY_YIELD` (1)    | sCoin from Scallop held in contract |

---

## Fee Structure

| Fee                      | Rate                                           | Trigger                            | Destination           |
| ------------------------ | ---------------------------------------------- | ---------------------------------- | --------------------- |
| Deposit fee              | 10 bps (0.10%) default, configurable per token | On lock creation or top-up         | `deposit_fees` bag    |
| Early withdrawal penalty | 200 bps (2.00%) of locked balance              | Withdraw before unlock time        | `fees` bag            |
| Yield platform fee       | 3000 bps (30.00%) of generated yield           | On yield lock completion           | `yield_fees` bag      |
| Swap fee (fee_router)    | Configurable, max 500 bps                      | On each `take_fee_and_return` call | `FeeTreasury` balance |

Deposit fee calculation uses ceiling division. Min and max fee bounds are configurable per token via `configure_token_fee`.

---

## Protocol Flow

### Standard Lock

```
1. Admin calls add_token_support<CoinType>
2. User calls create_lock<CoinType>(coin, duration_ms, strategy=0)
   - Deposit fee deducted upfront
   - Lock object transferred to user
3. (Optional) User calls add_to_lock to increase balance
4. User calls withdraw when ready
   - If clock >= unlock_time: full balance returned
   - If clock < unlock_time: 2% penalty deducted, remainder returned
```

### Yield Lock

```
1. Admin calls add_token_support<CoinType> and add_s_coin_support<SCoin>
2. User deposits CoinType into Scallop (off-chain via SDK), receives SCoin
3. User calls create_yield_lock<CoinType, SCoin>(s_coin, duration_ms)
   - Deposit fee deducted from sCoin upfront
   - YieldLock object transferred to user
4. (Optional) User calls add_to_yield_lock to increase principal
5. Withdrawal is a two-step process:
   a. User calls unlock_yield_lock_s_coin — returns sCoin from contract
   b. User redeems sCoin via Scallop SDK (off-chain) — receives base token
   c. User calls complete_yield_withdrawal_with_redeemed_coin with redeemed amount
      - Platform takes 30% of yield
      - Early withdrawal penalty applies if before unlock_time
      - Remainder returned to user
      - YieldLock object destroyed
```

---

## Admin Controls

All privileged functions require both the correct `AdminCap` object and matching sender address.

| Function                  | Description                                     |
| ------------------------- | ----------------------------------------------- |
| `add_token_support<T>`    | Register a new base token                       |
| `add_s_coin_support<S>`   | Register an sCoin for yield locks               |
| `configure_token_fee<T>`  | Set deposit fee bps, min, and max for a token   |
| `set_pause_status`        | Pause or unpause deposits and/or withdrawals    |
| `collect_fees<T>`         | Withdraw accumulated early-withdrawal penalties |
| `collect_yield_fees<T>`   | Withdraw accumulated platform yield fees        |
| `collect_deposit_fees<T>` | Withdraw accumulated deposit fees               |
| `request_admin_transfer`  | Initiate a two-step admin handover              |
| `accept_admin_transfer`   | New admin accepts the pending transfer          |
| `cancel_admin_transfer`   | Current admin cancels the pending transfer      |

Admin transfer is a two-step commit-accept pattern. The `AdminCap` is held in a `PendingAdminTransfer` shared object until the new admin accepts or the current admin cancels. This prevents accidental or irreversible transfers.

---

## Constants

| Constant                   | Value  | Description                       |
| -------------------------- | ------ | --------------------------------- |
| `PENALTY_BPS`              | 200    | Early withdrawal penalty (2%)     |
| `YIELD_FEE_BPS`            | 3000   | Platform yield fee (30%)          |
| `DEFAULT_DEPOSIT_FEE_BPS`  | 10     | Default deposit fee (0.10%)       |
| `BPS_DENOM`                | 10,000 | Basis point denominator           |
| `STRATEGY_NO_YIELD`        | 0      | Standard lock strategy identifier |
| `STRATEGY_YIELD`           | 1      | Yield lock strategy identifier    |
| `MAX_FEE_BPS` (fee_router) | 500    | Maximum swap fee (5%)             |

---

## Error Codes

| Code | Constant                 | Trigger                           |
| ---- | ------------------------ | --------------------------------- |
| 0    | `EInvalidDuration`       | Lock duration is zero             |
| 1    | `EUnauthorized`          | Caller is not the owner or admin  |
| 2    | `EPlatformNotFound`      | Token not registered on platform  |
| 3    | `EInvalidStrategy`       | Strategy mismatch for operation   |
| 5    | `EInvalidAmount`         | Amount is zero or below minimum   |
| 6    | `EPaused`                | Operation blocked by pause flag   |
| 7    | `EInvalidCapId`          | AdminCap does not match platform  |
| 8    | `EInsufficientForFee`    | Amount does not cover deposit fee |
| 9    | `ETokenFeeNotConfigured` | No fee config found for token     |

---

## Development

### Prerequisites

- [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install)
- Git

### Build

```bash
sui move build
```

### Test

```bash
sui move test
```

All 34 unit tests should pass. Tests cover:

- Initialization and shared object creation
- Token support registration (including idempotency)
- Fee configuration and calculation
- Pause and unpause guards
- Standard lock creation, top-up, on-time withdrawal, and early withdrawal with penalty
- Yield lock creation, top-up, on-time withdrawal with yield fee split, and early withdrawal with penalty
- Admin fee collection for all three fee types
- Admin transfer accept, cancel, and wrong-acceptor rejection
- TVL tracking across lock and withdrawal
- Registry lock counting and user lock lookups
- `analytics` module view helpers

---

## Security Considerations

**AdminCap verification** — Every privileged entry function checks both `tx_context::sender(ctx) == platform.admin` and `object::id(cap) == platform.admin_cap_id`. Possession of the cap object alone is insufficient without also being the registered admin address.

**Overflow-safe math** — All fee and penalty calculations use `u128` intermediate arithmetic (`safe_mul_div`, `safe_mul_div_ceil`) before casting back to `u64`.

**Early withdrawal penalty** — The 2% penalty discourages short-term manipulation of the TVL and rewards longer-term participants via platform fee accrual.

**Yield lock two-step withdrawal** — The separation between `unlock_yield_lock_s_coin` and `complete_yield_withdrawal_with_redeemed_coin` is intentional. It allows the user to redeem sCoin through Scallop externally before final settlement. The `YieldLock` object is not destroyed until step three, ensuring the protocol retains state through the off-chain redemption window.

**Deposit fee ceiling division** — `safe_mul_div_ceil` ensures fees are never rounded down to zero for small amounts, preventing dust deposits that would bypass fee collection.

**Pause mechanism** — Deposits and withdrawals can be paused independently. This allows the admin to halt new inflows while still permitting existing users to exit, or vice versa.
