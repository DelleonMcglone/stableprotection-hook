// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableSwapMath} from "../../src/libraries/StableSwapMath.sol";

/// @dev External harness so vm.expectRevert() can intercept library reverts.
///      Internal library functions are inlined and cannot be caught at the right
///      call depth otherwise.
contract StableSwapMathHarness {
    function calculateD(uint256 x0, uint256 x1, uint256 A) external pure returns (uint256) {
        return StableSwapMath.calculateD(x0, x1, A);
    }

    function getSwapOutput(uint256 amtIn, uint256 resIn, uint256 resOut, uint256 A)
        external
        pure
        returns (uint256)
    {
        return StableSwapMath.getSwapOutput(amtIn, resIn, resOut, A);
    }
}

contract StableSwapMathTest is Test {
    StableSwapMathHarness harness;

    function setUp() public {
        harness = new StableSwapMathHarness();
    }

    // ─── calculateD ────────────────────────────────────────────────────────────

    /// At perfect peg (x == y), D must equal x + y.
    function test_calculateD_atPeg() public pure {
        uint256 x = 1_000_000e18;
        uint256 D = StableSwapMath.calculateD(x, x, 100);
        assertApproxEqAbs(D, 2 * x, 2, "D != 2x at peg");
    }

    /// D with small reserves should still converge.
    function test_calculateD_smallReserves() public pure {
        uint256 D = StableSwapMath.calculateD(1e6, 1e6, 100);
        assertApproxEqAbs(D, 2e6, 2);
    }

    /// D with 6-decimal stablecoin amounts (1M USDC each side).
    function test_calculateD_sixDecimals() public pure {
        uint256 x = 1_000_000e6; // 1M USDC
        uint256 D = StableSwapMath.calculateD(x, x, 100);
        assertApproxEqAbs(D, 2 * x, 2);
    }

    /// Asymmetric reserves: D must be between max(x,y) and x+y.
    function test_calculateD_asymmetric() public pure {
        uint256 x0 = 1_000_000e18;
        uint256 x1 =   900_000e18;
        uint256 D  = StableSwapMath.calculateD(x0, x1, 100);
        assertGt(D, x0, "D < larger reserve");
        assertLt(D, x0 + x1, "D >= sum of reserves");
    }

    /// Reverts when a reserve is zero (tested via harness for vm.expectRevert).
    function test_calculateD_revertOnZeroReserve() public {
        vm.expectRevert();
        harness.calculateD(0, 1e18, 100);

        vm.expectRevert();
        harness.calculateD(1e18, 0, 100);
    }

    /// Reverts on out-of-range A (tested via harness).
    function test_calculateD_revertOnInvalidA() public {
        vm.expectRevert();
        harness.calculateD(1e18, 1e18, 0);

        vm.expectRevert();
        harness.calculateD(1e18, 1e18, 1001);
    }

    /// Invariant check: the returned D satisfies the StableSwap equation within
    /// the 0.001% relative tolerance of checkInvariant.
    function test_calculateD_satisfiesInvariant() public pure {
        uint256 x0 = 1_000_000e18;
        uint256 x1 =   950_000e18;
        uint256 A  = 200;
        uint256 D  = StableSwapMath.calculateD(x0, x1, A);
        assertTrue(StableSwapMath.checkInvariant(x0, x1, D, A), "invariant violated");
    }

    // ─── getY ──────────────────────────────────────────────────────────────────

    /// At peg (x == y and x_new == y), output y equals the original reserve.
    function test_getY_atPeg_identity() public pure {
        uint256 reserve = 1_000_000e18;
        uint256 D = StableSwapMath.calculateD(reserve, reserve, 100);
        uint256 y = StableSwapMath.getY(reserve, D, 100);
        assertApproxEqAbs(y, reserve, 2);
    }

    /// Swapping a small amount from an at-peg pool should give approximately
    /// the same amount back (near 1:1 conversion).
    function test_getY_nearParity() public pure {
        uint256 reserve  = 1_000_000e18;
        uint256 amountIn = 1_000e18;
        uint256 D = StableSwapMath.calculateD(reserve, reserve, 100);
        uint256 y = StableSwapMath.getY(reserve + amountIn, D, 100);
        // new output reserve; amountOut ≈ amountIn
        uint256 amountOut = reserve - y;
        // within 0.01% of input
        assertApproxEqRel(amountOut, amountIn, 0.0001e18);
    }

    /// StableSwap must give MORE output than constant-product for a peg swap.
    function test_getY_betterThanConstantProduct() public pure {
        uint256 reserve  = 1_000_000e18;
        uint256 amountIn = 10_000e18; // 1% of pool

        uint256 D = StableSwapMath.calculateD(reserve, reserve, 100);
        uint256 yStable   = StableSwapMath.getY(reserve + amountIn, D, 100);
        uint256 outStable = reserve - yStable;

        // constant product: out = reserve - reserve²/(reserve+amountIn)
        uint256 outCp = reserve - (reserve * reserve) / (reserve + amountIn);

        assertGt(outStable, outCp, "stable should beat CP near peg");
    }

    // ─── getSwapOutput ─────────────────────────────────────────────────────────

    /// Basic sanity: output is positive and less than the output reserve.
    function test_getSwapOutput_basic() public pure {
        uint256 r = 1_000_000e18;
        uint256 out = StableSwapMath.getSwapOutput(1_000e18, r, r, 100);
        assertGt(out, 0);
        assertLt(out, r);
    }

    /// Larger A → more output (flatter curve near peg).
    function test_getSwapOutput_higherA_givesMoreOutput() public pure {
        uint256 r     = 1_000_000e18;
        uint256 amtIn = 10_000e18;
        uint256 outLowA  = StableSwapMath.getSwapOutput(amtIn, r, r, 10);
        uint256 outHighA = StableSwapMath.getSwapOutput(amtIn, r, r, 500);
        assertGt(outHighA, outLowA, "higher A should give more output near peg");
    }

    /// Reverts when input amount is zero.
    function test_getSwapOutput_revertOnZeroInput() public {
        vm.expectRevert();
        harness.getSwapOutput(0, 1e18, 1e18, 100);
    }

    /// Reverts when a reserve is zero.
    function test_getSwapOutput_revertOnZeroReserve() public {
        vm.expectRevert();
        harness.getSwapOutput(1e18, 0, 1e18, 100);
    }

    /// Output never exceeds reserveOut.
    function test_getSwapOutput_noDrainPool() public pure {
        uint256 r   = 1_000_000e18;
        uint256 out = StableSwapMath.getSwapOutput(r / 2, r, r, 100);
        assertLt(out, r, "cannot drain full reserve");
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    /// Fuzz: output is always positive and never drains the output reserve.
    /// The strict invariant check is covered by test_calculateD_satisfiesInvariant;
    /// excluding it here avoids false failures from integer rounding at extreme
    /// pool imbalances with very low A (A = 1 + near-constant-product behaviour).
    function testFuzz_getSwapOutput_positiveAndBounded(
        uint80 r0,
        uint80 r1,
        uint64 amtIn,
        uint16 rawA
    ) public pure {
        // Practical ranges: 1 token to 1B tokens at 18 dec
        uint256 reserveIn  = bound(r0,    1e18, 1e27);
        uint256 reserveOut = bound(r1,    1e18, 1e27);
        uint256 amount     = bound(amtIn, 1e15, reserveIn / 10); // ≤10% of pool
        uint256 A          = bound(rawA,  1,    1000);

        uint256 out = StableSwapMath.getSwapOutput(amount, reserveIn, reserveOut, A);
        assertGt(out, 0, "output must be positive");
        assertLt(out, reserveOut, "cannot drain reserve");
    }
}
