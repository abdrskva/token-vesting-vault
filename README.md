# Token Vesting Vault

A single Solidity contract that lets a token project lock ERC-20 tokens for many beneficiaries (team, investors, advisors) and release them over time with a **cliff**, **linear unlock**, and optional **revocation** by the owner.

Built on OpenZeppelin (`Ownable`, `SafeERC20`, `ReentrancyGuard`) and tested with Foundry.

## How vesting works

For a schedule with `total`, `start`, `cliff`, `duration` and current time `t` (frozen at `revokedAt` if revoked):

```
t <  start + cliff      -> vested = 0
t >= start + duration   -> vested = total
otherwise               -> vested = total * (t - start) / duration   (rounds down)
```

Note that the linear part counts from `start`, not from `start + cliff`. When the cliff ends, the part accrued so far unlocks at once.

Example: `total = 1,000,000`, `cliff = 200s`, `duration = 1000s`

| Time `t`        | Vested    | Why                          |
|-----------------|-----------|------------------------------|
| `start - 10`    | 0         | not started                  |
| `start + 199`   | 0         | inside cliff                 |
| `start + 200`   | 200,000   | cliff ends, accrued part opens |
| `start + 500`   | 500,000   | linear                       |
| `start + 1000`  | 1,000,000 | fully vested                 |
| `start + 5000`  | 1,000,000 | capped at `total`            |

Typical real-world setup: **12-month cliff + 48 months total** (`cliff = 365 days`, `duration = 4 * 365 days`). Nothing unlocks in year 1; at month 12, 25% unlocks at once; the rest unlocks linearly until month 48.

## Functions

| Function | Who | What |
|---|---|---|
| `createSchedule(...)` | owner | Create a schedule; vault must hold enough *unpromised* tokens |
| `vestedAmount(id)` / `releasable(id)` | anyone (view) | Vested so far / claimable now |
| `release(id)` | anyone | Pays releasable tokens **to the beneficiary** |
| `revoke(id)` | owner | Returns the unvested part to the owner, freezes vesting |
| `withdrawUnallocated(to)` | owner | Rescues tokens that are not promised to anyone |
| `schedulesOf(addr)` | anyone (view) | Ids of the schedules owned by `addr` |
| `transferSchedule(id, to)` | beneficiary | Hands the schedule to another address |

## Run the tests

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std --no-commit
forge test -vvv
forge coverage
```

The suite covers the formula (before start, in cliff, at the cliff boundary, middle, end, after end), rounding, repeated releases summing exactly to `total`, revoke before cliff / mid-vesting / after the end, the over-promising check, access control, `transferSchedule`, a re-entrancy attack with an ERC-777-style callback token, and a fuzz test (`vested <= total` and monotonic in time).

Coverage result: _fill in after running `forge coverage`._

## Security model

**Roles**
- **Owner** can create schedules, revoke *revocable* schedules, and withdraw tokens that are **not** promised (`balance - totalAllocated`).
- **Beneficiary** can transfer their schedule to another address. Anyone can trigger `release`, but tokens always go to the beneficiary.

**What a malicious or compromised owner can do**
- Revoke any schedule marked `revocable`: the unvested part returns to the owner. Already vested tokens stay with the beneficiary.
- Create schedules with `revocable = true` for anyone, so beneficiaries must check this flag before trusting a schedule.
- The owner **cannot** take vested tokens, tokens of non-revocable schedules, or promised tokens via `withdrawUnallocated`.
- A stolen owner key has the same powers as above. Use a multisig as owner in production.

**Risks addressed**
- **Re-entrancy:** `release`, `revoke` and `withdrawUnallocated` use `nonReentrant`, and `release` follows Checks-Effects-Interactions (state is updated before `safeTransfer`).
- **Overflow / precision:** Solidity 0.8 checked math; multiplication is done before division; `uint64` values are widened to `uint256` before adding.
- **Over-promising:** `createSchedule` requires `balance - totalAllocated >= amount`.
- **Revoke freeze:** after revoke, time is pinned to `revokedAt`, so nothing extra vests later.
- **Unsafe transfers:** `SafeERC20` is used for all token transfers.

**Risks NOT addressed**
- Owner key compromise or malicious owner (see above); no timelock or multisig is built in.
- No ownership renouncement safeguards beyond OpenZeppelin defaults.
- The contract trusts the token contract; a malicious or upgradeable token could misbehave.

## Known limitations

- **Fee-on-transfer / rebasing tokens are not supported**: balances may differ from recorded amounts.
- One token per vault.
- `start` may be in the past (retroactive vesting) by design.
- `transferSchedule` loops over the sender's schedule list, so an address with a huge number of schedules pays more gas.

## License

MIT
