// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault — token vesting with cliff, linear unlock and revocation
/// @notice One vault holds tokens for many beneficiaries. The owner (e.g. the project team)
///         creates schedules; beneficiaries (team, investors, advisors) receive tokens over time.
contract VestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //  PROVIDED PART (identical to the student starter file)
    // ============================================================
    struct Schedule {
        address beneficiary;
        uint256 total;      // total tokens promised
        uint256 released;   // tokens already paid out
        uint64 start;       // unix time when vesting starts
        uint64 cliff;       // seconds after `start` before ANY token vests
        uint64 duration;    // seconds after `start` when 100% is vested
        uint64 revokedAt;   // 0 while not revoked
        bool revocable;
        bool revoked;
    }

    IERC20 public immutable token;
    uint256 public scheduleCount;                       // ids start from 1
    uint256 public totalAllocated;                      // tokens promised to beneficiaries and not yet paid out
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) private _schedulesOf;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    constructor(IERC20 token_) Ownable(msg.sender) {
        require(address(token_) != address(0), "zero token");
        token = token_;
    }

    // ============================================================
    //  YOUR CODE STARTS HERE
    // ============================================================

    // ------------------------------------------------------------
    // STEP 1 — create a schedule (owner only)
    // ------------------------------------------------------------

    /// @notice Create a vesting schedule for `beneficiary` (owner only).
    /// @dev The vault must already hold enough tokens that are not promised to anyone else.
    ///      `start` may be in the past (retroactive vesting).
    /// @param beneficiary Address that will receive the tokens.
    /// @param amount Total number of tokens promised by this schedule.
    /// @param start Unix time (seconds) at which vesting starts.
    /// @param cliff Seconds after `start` during which nothing is vested.
    /// @param duration Seconds after `start` at which 100% is vested (cliff is included).
    /// @param revocable Whether the owner may later revoke the unvested part.
    /// @return id The id of the new schedule (ids start from 1).
    function createSchedule(
        address beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner returns (uint256 id) {
        // --- Checks ---
        require(beneficiary != address(0), "zero beneficiary");
        require(amount > 0, "zero amount");
        require(duration > 0, "zero duration");
        require(cliff <= duration, "cliff > duration");

        uint256 balance = token.balanceOf(address(this));
        // Written so it can never underflow, even if balance < totalAllocated (e.g. fee-on-transfer token).
        require(balance >= totalAllocated && balance - totalAllocated >= amount, "insufficient unallocated");

        // --- Effects ---
        id = ++scheduleCount;
        schedules[id] = Schedule({
            beneficiary: beneficiary,
            total: amount,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revokedAt: 0,
            revocable: revocable,
            revoked: false
        });
        _schedulesOf[beneficiary].push(id);
        totalAllocated += amount;

        emit ScheduleCreated(id, beneficiary, amount, start, cliff, duration, revocable);
    }

    // ------------------------------------------------------------
    // STEP 2 — the vesting formula
    // ------------------------------------------------------------

    /// @notice Amount vested (earned) so far by schedule `id`, including what was already released.
    /// @dev Reverts for an unknown id. For a revoked schedule, time is frozen at `revokedAt`.
    /// @param id Schedule id.
    /// @return The vested amount.
    function vestedAmount(uint256 id) public view returns (uint256) {
        return _vested(_getExisting(id));
    }

    /// @notice Amount that can be released to the beneficiary right now.
    /// @dev `vested - released`. Reverts for an unknown id.
    /// @param id Schedule id.
    /// @return The releasable amount.
    function releasable(uint256 id) public view returns (uint256) {
        Schedule storage s = _getExisting(id);
        return _vested(s) - s.released;
    }

    /// @dev Pure vesting formula. Multiplication happens BEFORE division to keep precision.
    function _vested(Schedule storage s) internal view returns (uint256) {
        // Frozen at the moment of revocation, otherwise "now".
        uint256 t = s.revoked ? s.revokedAt : block.timestamp;

        // uint256 casts avoid any uint64 overflow when adding start + cliff / duration.
        uint256 start = s.start;
        if (t < start + s.cliff) return 0;
        if (t >= start + s.duration) return s.total;
        // Here t >= start + cliff >= start, so (t - start) cannot underflow.
        return (s.total * (t - start)) / s.duration;
    }

    /// @dev Returns the schedule or reverts if the id was never created.
    function _getExisting(uint256 id) internal view returns (Schedule storage s) {
        s = schedules[id];
        require(s.beneficiary != address(0), "unknown schedule");
    }

    // ------------------------------------------------------------
    // STEP 3 — release
    // ------------------------------------------------------------

    /// @notice Send all currently releasable tokens of schedule `id` to its beneficiary.
    /// @dev Anyone may call; tokens ALWAYS go to the beneficiary, never to `msg.sender`.
    ///      Follows Checks-Effects-Interactions and is also protected by `nonReentrant`.
    /// @param id Schedule id.
    function release(uint256 id) external nonReentrant {
        // --- Checks ---
        Schedule storage s = _getExisting(id);
        uint256 amount = _vested(s) - s.released;
        require(amount > 0, "nothing to release");

        // --- Effects (state first!) ---
        s.released += amount;
        totalAllocated -= amount;

        // --- Interactions (tokens last) ---
        address to = s.beneficiary;
        token.safeTransfer(to, amount);

        emit Released(id, to, amount);
    }

    // ------------------------------------------------------------
    // STEP 4 — revoke
    // ------------------------------------------------------------

    /// @notice Revoke the unvested part of a schedule and return it to the owner (owner only).
    /// @dev The vested part stays claimable by the beneficiary through {release}.
    ///      Vesting is frozen at the current time. Revoking a fully vested schedule returns 0.
    /// @param id Schedule id.
    function revoke(uint256 id) external onlyOwner nonReentrant {
        // --- Checks ---
        Schedule storage s = _getExisting(id);
        require(s.revocable, "not revocable");
        require(!s.revoked, "already revoked");

        // Computed BEFORE freezing, using the current time.
        uint256 unvested = s.total - _vested(s);

        // --- Effects ---
        s.revoked = true;
        s.revokedAt = uint64(block.timestamp);
        totalAllocated -= unvested;

        // --- Interactions ---
        if (unvested > 0) {
            token.safeTransfer(owner(), unvested);
        }

        emit Revoked(id, unvested);
    }

    // ------------------------------------------------------------
    // STEP 5 — housekeeping
    // ------------------------------------------------------------

    /// @notice Withdraw tokens that are not promised to any schedule (owner only).
    /// @dev Sends `balance - totalAllocated`. Never touches promised tokens.
    /// @param to Recipient of the rescued tokens.
    /// @return amount The amount sent.
    function withdrawUnallocated(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        require(to != address(0), "zero address");

        uint256 balance = token.balanceOf(address(this));
        require(balance > totalAllocated, "nothing to withdraw");
        amount = balance - totalAllocated;

        token.safeTransfer(to, amount);
    }

    /// @notice Ids of the schedules currently owned by `beneficiary`.
    /// @param beneficiary The address to look up.
    /// @return Array of schedule ids.
    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _schedulesOf[beneficiary];
    }

    // ------------------------------------------------------------
    // BONUS — transferSchedule
    // ------------------------------------------------------------

    /// @notice Hand your schedule to another address (current beneficiary only).
    /// @dev `released` is preserved. `schedulesOf` is updated for both addresses.
    /// @param id Schedule id.
    /// @param newBeneficiary The new owner of the schedule (must not be zero).
    function transferSchedule(uint256 id, address newBeneficiary) external {
        Schedule storage s = _getExisting(id);
        require(msg.sender == s.beneficiary, "not beneficiary");
        require(newBeneficiary != address(0), "zero beneficiary");

        address old = s.beneficiary;

        // Remove id from the old owner's list (swap with last element, then pop).
        uint256[] storage list = _schedulesOf[old];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == id) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
        }

        s.beneficiary = newBeneficiary;
        _schedulesOf[newBeneficiary].push(id);

        emit ScheduleTransferred(id, old, newBeneficiary);
    }
}
