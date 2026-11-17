// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingVault} from "../src/VestingVault.sol";

/// @dev Plain mintable token.
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IReceiver {
    function onTokensReceived() external;
}

/// @dev ERC-777-like token: calls back the recipient contract during transfers.
contract CallbackToken is ERC20 {
    constructor() ERC20("Callback", "CBK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to.code.length > 0) {
            try IReceiver(to).onTokensReceived() {} catch {}
        }
    }
}

/// @dev Beneficiary that tries to call release() again while receiving tokens.
contract ReentrantBeneficiary is IReceiver {
    VestingVault public vault;
    uint256 public id;
    uint256 public reentryAttempts;

    constructor(VestingVault v) {
        vault = v;
    }

    function setId(uint256 id_) external {
        id = id_;
    }

    function attack() external {
        vault.release(id);
    }

    function onTokensReceived() external {
        reentryAttempts++;
        try vault.release(id) {} catch {}
    }
}

contract VestingVaultTest is Test {
    MockToken token;
    VestingVault vault;

    address owner = address(this); // the test contract deploys the vault, so it is the owner
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant TOTAL = 1_000_000;
    uint64 constant CLIFF = 200;
    uint64 constant DURATION = 1000;

    uint64 start;
    uint256 id;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    function setUp() public {
        vm.warp(10_000);
        token = new MockToken();
        vault = new VestingVault(IERC20(address(token)));
        token.mint(address(vault), TOTAL);

        start = uint64(block.timestamp);
        id = vault.createSchedule(alice, TOTAL, start, CLIFF, DURATION, true);
    }

    // ---------------- createSchedule ----------------

    function test_create_storesScheduleAndEmitsEvent() public {
        token.mint(address(vault), 500);

        vm.expectEmit(true, true, false, true);
        emit ScheduleCreated(2, bob, 500, start, 0, 100, false);
        uint256 id2 = vault.createSchedule(bob, 500, start, 0, 100, false);

        assertEq(id2, 2);
        assertEq(vault.scheduleCount(), 2);
        assertEq(vault.totalAllocated(), TOTAL + 500);
        (address ben, uint256 total, uint256 released,,,,, bool revocable, bool revoked) = vault.schedules(id2);
        assertEq(ben, bob);
        assertEq(total, 500);
        assertEq(released, 0);
        assertTrue(!revocable);
        assertTrue(!revoked);
        assertEq(vault.schedulesOf(bob).length, 1);
        assertEq(vault.schedulesOf(bob)[0], 2);
    }

    function test_create_revertsOnInvalidParams() public {
        token.mint(address(vault), 1000);

        vm.expectRevert();
        vault.createSchedule(address(0), 100, start, 0, 100, true); // zero beneficiary

        vm.expectRevert();
        vault.createSchedule(bob, 0, start, 0, 100, true); // zero amount

        vm.expectRevert();
        vault.createSchedule(bob, 100, start, 0, 0, true); // zero duration

        vm.expectRevert();
        vault.createSchedule(bob, 100, start, 101, 100, true); // cliff > duration

        // cliff == duration is allowed
        vault.createSchedule(bob, 100, start, 100, 100, true);
    }

    function test_create_cannotPromiseMoreThanVaultHolds() public {
        // vault holds TOTAL and all of it is already promised to alice
        vm.expectRevert();
        vault.createSchedule(bob, 1, start, 0, 100, true);

        token.mint(address(vault), 100);
        vm.expectRevert();
        vault.createSchedule(bob, 101, start, 0, 100, true);
        vault.createSchedule(bob, 100, start, 0, 100, true); // exactly what is free is OK
    }

    function test_create_startMayBeInThePast() public {
        token.mint(address(vault), 1000);
        uint256 id2 = vault.createSchedule(bob, 1000, start - 500, 0, 1000, true);
        assertEq(vault.vestedAmount(id2), 500);
    }

    // ---------------- vestedAmount: formula ----------------

    function test_vested_beforeStartAndInsideCliff() public {
        vm.warp(start - 10);
        assertEq(vault.vestedAmount(id), 0);

        vm.warp(start + 199);
        assertEq(vault.vestedAmount(id), 0);
    }

    function test_vested_exactlyAtCliffJumpsToAccruedPart() public {
        vm.warp(start + 200);
        assertEq(vault.vestedAmount(id), 200_000);
    }

    function test_vested_linearMiddleEndAndAfterEnd() public {
        vm.warp(start + 500);
        assertEq(vault.vestedAmount(id), 500_000);

        vm.warp(start + 777);
        assertEq(vault.vestedAmount(id), 777_000);

        vm.warp(start + 1000);
        assertEq(vault.vestedAmount(id), 1_000_000);

        vm.warp(start + 5000);
        assertEq(vault.vestedAmount(id), 1_000_000);
    }

    function test_vested_roundsDown() public {
        token.mint(address(vault), 1000);
        uint256 id2 = vault.createSchedule(bob, 1000, start, 0, 3, true);

        vm.warp(start + 1);
        assertEq(vault.vestedAmount(id2), 333);
        vm.warp(start + 2);
        assertEq(vault.vestedAmount(id2), 666);
        vm.warp(start + 3);
        assertEq(vault.vestedAmount(id2), 1000);
    }

    function test_vested_unknownIdReverts() public {
        vm.expectRevert();
        vault.vestedAmount(0);
        vm.expectRevert();
        vault.vestedAmount(999);
        vm.expectRevert();
        vault.releasable(999);
    }

    // ---------------- release ----------------

    function test_release_multipleTimesSumsExactlyToTotal() public {
        uint256 paid;
        uint256[4] memory times = [uint256(250), 333, 777, 1000];
        for (uint256 i = 0; i < times.length; i++) {
            vm.warp(start + times[i]);
            uint256 r = vault.releasable(id);
            vault.release(id);
            paid += r;
            assertEq(token.balanceOf(alice), paid);
        }
        assertEq(paid, TOTAL);
        assertEq(token.balanceOf(alice), TOTAL);
        assertEq(vault.totalAllocated(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_release_anyoneCanCall_tokensGoToBeneficiary() public {
        vm.warp(start + 500);

        vm.expectEmit(true, true, false, true);
        emit Released(id, alice, 500_000);
        vm.prank(mallory);
        vault.release(id);

        assertEq(token.balanceOf(alice), 500_000);
        assertEq(token.balanceOf(mallory), 0); // caller gets nothing
        assertEq(vault.totalAllocated(), 500_000);
    }

    function test_release_revertsWhenNothingToReleaseOrUnknownId() public {
        vm.warp(start + 100); // inside cliff
        vm.expectRevert();
        vault.release(id);

        vm.warp(start + 500);
        vault.release(id);
        vm.expectRevert(); // already paid, nothing new
        vault.release(id);

        vm.expectRevert();
        vault.release(42);
    }

    // ---------------- revoke ----------------

    function test_revoke_beforeCliff_returnsEverything() public {
        vm.warp(start + 100);

        vm.expectEmit(true, false, false, true);
        emit Revoked(id, TOTAL);
        vault.revoke(id);

        assertEq(token.balanceOf(owner), TOTAL);
        assertEq(vault.totalAllocated(), 0);
        vm.warp(start + 5000);
        assertEq(vault.vestedAmount(id), 0); // frozen
        vm.expectRevert();
        vault.release(id);
    }

    function test_revoke_inTheMiddle_splitsAndFreezes() public {
        vm.warp(start + 400);
        vault.revoke(id);

        assertEq(token.balanceOf(owner), 600_000); // unvested part goes back
        assertEq(vault.totalAllocated(), 400_000); // vested part is still promised

        // even 10 years later beneficiary gets only what was vested at revocation
        vm.warp(start + 10 * 365 days);
        assertEq(vault.vestedAmount(id), 400_000);
        vault.release(id);
        assertEq(token.balanceOf(alice), 400_000);
        assertEq(vault.totalAllocated(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_revoke_afterEnd_returnsZero() public {
        vm.warp(start + 2000);
        vault.revoke(id);
        assertEq(token.balanceOf(owner), 0);
        assertEq(vault.totalAllocated(), TOTAL);

        vault.release(id);
        assertEq(token.balanceOf(alice), TOTAL);
    }

    function test_revoke_notRevocableOrTwiceReverts() public {
        token.mint(address(vault), 100);
        uint256 id2 = vault.createSchedule(bob, 100, start, 0, 100, false);
        vm.expectRevert();
        vault.revoke(id2); // not revocable

        vault.revoke(id);
        vm.expectRevert();
        vault.revoke(id); // already revoked
    }

    // ---------------- access control ----------------

    function test_access_onlyOwnerCanCreateRevokeWithdraw() public {
        token.mint(address(vault), 100);

        vm.startPrank(mallory);
        vm.expectRevert();
        vault.createSchedule(mallory, 100, start, 0, 100, true);
        vm.expectRevert();
        vault.revoke(id);
        vm.expectRevert();
        vault.withdrawUnallocated(mallory);
        vm.stopPrank();
    }

    function test_withdrawUnallocated_onlyTouchesFreeTokens() public {
        vm.expectRevert(); // everything is promised
        vault.withdrawUnallocated(owner);

        token.mint(address(vault), 123); // sent by mistake
        uint256 got = vault.withdrawUnallocated(bob);
        assertEq(got, 123);
        assertEq(token.balanceOf(bob), 123);
        assertEq(token.balanceOf(address(vault)), TOTAL);
        assertEq(vault.totalAllocated(), TOTAL);
    }

    // ---------------- bonus: transferSchedule ----------------

    function test_transferSchedule_movesOwnershipAndKeepsReleased() public {
        vm.warp(start + 500);
        vault.release(id); // alice gets 500_000

        vm.expectEmit(true, true, true, false);
        emit ScheduleTransferred(id, alice, bob);
        vm.prank(alice);
        vault.transferSchedule(id, bob);

        assertEq(vault.schedulesOf(alice).length, 0);
        assertEq(vault.schedulesOf(bob).length, 1);

        vm.warp(start + 1000);
        vault.release(id);
        assertEq(token.balanceOf(bob), 500_000); // only the remainder
        assertEq(token.balanceOf(alice), 500_000);
    }

    function test_transferSchedule_accessAndZeroAddress() public {
        vm.prank(mallory);
        vm.expectRevert();
        vault.transferSchedule(id, mallory);

        vm.prank(alice);
        vm.expectRevert();
        vault.transferSchedule(id, address(0));
    }

    // ---------------- reentrancy ----------------

    function test_reentrancy_cannotDrainMoreThanVested() public {
        CallbackToken cbt = new CallbackToken();
        VestingVault v = new VestingVault(IERC20(address(cbt)));
        ReentrantBeneficiary attacker = new ReentrantBeneficiary(v);

        cbt.mint(address(v), 2000); // 1000 for attacker + 1000 for an innocent user
        uint256 aid = v.createSchedule(address(attacker), 1000, start, 0, 1000, false);
        v.createSchedule(bob, 1000, start, 0, 1000, false);
        attacker.setId(aid);

        vm.warp(start + 500);
        attacker.attack();

        assertGt(attacker.reentryAttempts(), 0); // the callback really happened
        assertEq(cbt.balanceOf(address(attacker)), 500); // ...but paid out exactly once
        assertEq(cbt.balanceOf(address(v)), 1500);
        assertEq(v.totalAllocated(), 1500);
    }

    // ---------------- fuzz ----------------

    function testFuzz_vestedNeverExceedsTotalAndNeverDecreases(
        uint256 total,
        uint256 cliff,
        uint256 duration,
        uint256 t1,
        uint256 t2
    ) public {
        total = bound(total, 1, 1e30);
        duration = bound(duration, 1, 20 * 365 days);
        cliff = bound(cliff, 0, duration);
        t1 = bound(t1, 0, 30 * 365 days);
        t2 = bound(t2, t1, 30 * 365 days);

        token.mint(address(vault), total);
        uint256 fid = vault.createSchedule(bob, total, start, uint64(cliff), uint64(duration), true);

        vm.warp(start + t1);
        uint256 v1 = vault.vestedAmount(fid);
        vm.warp(start + t2);
        uint256 v2 = vault.vestedAmount(fid);

        assertLe(v1, total);
        assertLe(v2, total);
        assertLe(v1, v2);
    }
}
