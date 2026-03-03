// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PegMonitor} from "../../src/libraries/PegMonitor.sol";
import {PegZone} from "../../src/types/SPTypes.sol";

contract PegMonitorTest is Test {
    // ─── classifyZone ──────────────────────────────────────────────────────────

    function test_classifyZone_exactPeg() public pure {
        (PegZone zone, uint256 dev) = PegMonitor.classifyZone(1e18, 1e18);
        assertEq(uint8(zone), uint8(PegZone.HEALTHY));
        assertEq(dev, 0);
    }

    function test_classifyZone_healthyBoundary() public pure {
        // 10 bps deviation: |r0 - r1| * 10000 / avg = 10 → HEALTHY
        uint256 base = 1_000_000e18;
        uint256 diff = base * 10 / 10_000; // exactly 10 bps
        (PegZone zone,) = PegMonitor.classifyZone(base + diff, base);
        assertEq(uint8(zone), uint8(PegZone.HEALTHY), "10 bps should be HEALTHY");
    }

    function test_classifyZone_minorLow() public pure {
        // 20 bps deviation: r0=10010, r1=9990 → diff=20, avg=10000 → exactly 20 bps
        // Avoids integer-rounding ambiguity that affects values near 10 bps boundary.
        uint256 r0 = 10_010e18;
        uint256 r1 =  9_990e18;
        (PegZone zone,) = PegMonitor.classifyZone(r0, r1);
        assertEq(uint8(zone), uint8(PegZone.MINOR), "20 bps should be MINOR");
    }

    function test_classifyZone_minorBoundary() public pure {
        // 50 bps → MINOR
        uint256 base = 1_000_000e18;
        uint256 diff = base * 50 / 10_000;
        (PegZone zone,) = PegMonitor.classifyZone(base + diff, base);
        assertEq(uint8(zone), uint8(PegZone.MINOR), "50 bps should be MINOR");
    }

    function test_classifyZone_moderate() public pure {
        // 100 bps → MODERATE
        uint256 base = 1_000_000e18;
        uint256 diff = base * 100 / 10_000;
        (PegZone zone,) = PegMonitor.classifyZone(base + diff, base);
        assertEq(uint8(zone), uint8(PegZone.MODERATE), "100 bps should be MODERATE");
    }

    function test_classifyZone_severe() public pure {
        // 300 bps → SEVERE
        uint256 base = 1_000_000e18;
        uint256 diff = base * 300 / 10_000;
        (PegZone zone,) = PegMonitor.classifyZone(base + diff, base);
        assertEq(uint8(zone), uint8(PegZone.SEVERE), "300 bps should be SEVERE");
    }

    function test_classifyZone_critical() public pure {
        // 600 bps → CRITICAL
        uint256 base = 1_000_000e18;
        uint256 diff = base * 600 / 10_000;
        (PegZone zone, uint256 dev) = PegMonitor.classifyZone(base + diff, base);
        assertEq(uint8(zone), uint8(PegZone.CRITICAL), "600 bps should be CRITICAL");
        assertGt(dev, 500, "deviationBps should exceed SEVERE threshold");
    }

    function test_classifyZone_zeroReserve() public pure {
        (PegZone zone, uint256 dev) = PegMonitor.classifyZone(0, 1e18);
        assertEq(uint8(zone), uint8(PegZone.CRITICAL));
        assertEq(dev, type(uint256).max);

        (zone, dev) = PegMonitor.classifyZone(1e18, 0);
        assertEq(uint8(zone), uint8(PegZone.CRITICAL));
    }

    function test_classifyZone_symmetry() public pure {
        uint256 a = 1_100_000e18;
        uint256 b = 1_000_000e18;
        (PegZone z1, uint256 d1) = PegMonitor.classifyZone(a, b);
        (PegZone z2, uint256 d2) = PegMonitor.classifyZone(b, a);
        assertEq(uint8(z1), uint8(z2), "zone must be symmetric");
        assertEq(d1, d2, "deviation must be symmetric");
    }

    // ─── calculateFee ──────────────────────────────────────────────────────────

    function test_calculateFee_towardPeg_isHalf() public pure {
        uint24 maxFee = 10_000;
        // HEALTHY base = 100 ppm.  toward-peg → 0.5× = 50 ppm
        uint24 fee = PegMonitor.calculateFee(PegZone.HEALTHY, true, maxFee);
        assertEq(fee, 50);
    }

    function test_calculateFee_awayFromPeg_isTriple() public pure {
        uint24 maxFee = 10_000;
        // HEALTHY base = 100 ppm.  away-from-peg → 3× = 300 ppm
        uint24 fee = PegMonitor.calculateFee(PegZone.HEALTHY, false, maxFee);
        assertEq(fee, 300);
    }

    function test_calculateFee_moderate_towardPeg() public pure {
        // MODERATE base = 1500 ppm × 0.5 = 750 ppm
        uint24 fee = PegMonitor.calculateFee(PegZone.MODERATE, true, 10_000);
        assertEq(fee, 750);
    }

    function test_calculateFee_moderate_awayFromPeg() public pure {
        // MODERATE base = 1500 ppm × 3 = 4500 ppm
        uint24 fee = PegMonitor.calculateFee(PegZone.MODERATE, false, 10_000);
        assertEq(fee, 4500);
    }

    function test_calculateFee_severe_awayFromPeg_capped() public pure {
        // SEVERE base = 5000 ppm × 3 = 15000 ppm → capped at maxFee = 10000
        uint24 fee = PegMonitor.calculateFee(PegZone.SEVERE, false, 10_000);
        assertEq(fee, 10_000, "should be capped at maxFee");
    }

    function test_calculateFee_neverExceedsMaxFee(uint8 zoneRaw, bool toward) public pure {
        PegZone zone = PegZone(bound(zoneRaw, 0, 3)); // exclude CRITICAL (CB fires)
        uint24 maxFee = 10_000;
        uint24 fee = PegMonitor.calculateFee(zone, toward, maxFee);
        assertLe(fee, maxFee, "fee exceeded maxFee");
    }

    // ─── calculateDynamicA ─────────────────────────────────────────────────────

    function test_calculateDynamicA_healthy() public pure {
        uint256 effA = PegMonitor.calculateDynamicA(100, PegZone.HEALTHY);
        assertEq(effA, 100); // 100% of base
    }

    function test_calculateDynamicA_minor() public pure {
        uint256 effA = PegMonitor.calculateDynamicA(100, PegZone.MINOR);
        assertEq(effA, 80); // 80%
    }

    function test_calculateDynamicA_moderate() public pure {
        uint256 effA = PegMonitor.calculateDynamicA(100, PegZone.MODERATE);
        assertEq(effA, 50); // 50%
    }

    function test_calculateDynamicA_severe() public pure {
        uint256 effA = PegMonitor.calculateDynamicA(100, PegZone.SEVERE);
        assertEq(effA, 25); // 25%
    }

    function test_calculateDynamicA_critical() public pure {
        uint256 effA = PegMonitor.calculateDynamicA(100, PegZone.CRITICAL);
        assertEq(effA, 10); // 10%
    }

    function test_calculateDynamicA_minimumOne() public pure {
        // baseA = 1, CRITICAL: 10% of 1 → 0.1 → rounds to 0 → clamped to 1
        uint256 effA = PegMonitor.calculateDynamicA(1, PegZone.CRITICAL);
        assertGe(effA, 1, "effA must be at least 1");
    }

    function test_calculateDynamicA_decreasesWithWorseZone() public pure {
        uint256 base = 1000;
        uint256 aHealthy   = PegMonitor.calculateDynamicA(base, PegZone.HEALTHY);
        uint256 aMinor     = PegMonitor.calculateDynamicA(base, PegZone.MINOR);
        uint256 aModerate  = PegMonitor.calculateDynamicA(base, PegZone.MODERATE);
        uint256 aSevere    = PegMonitor.calculateDynamicA(base, PegZone.SEVERE);
        uint256 aCritical  = PegMonitor.calculateDynamicA(base, PegZone.CRITICAL);
        assertTrue(
            aHealthy >= aMinor &&
            aMinor   >= aModerate &&
            aModerate>= aSevere &&
            aSevere  >= aCritical,
            "A must decrease monotonically with zone severity"
        );
    }

    // ─── isTowardPeg ───────────────────────────────────────────────────────────

    function test_isTowardPeg_r0excess_buyingToken0() public pure {
        // r0 > r1 (excess token0) and zeroForOne=false (user gets token0)
        assertTrue(
            PegMonitor.isTowardPeg(1_100e18, 1_000e18, false),
            "removing excess token0 should be toward peg"
        );
    }

    function test_isTowardPeg_r0excess_sellingToken0() public pure {
        // r0 > r1 and zeroForOne=true (user sells token0 → adds to r0) → away
        assertFalse(
            PegMonitor.isTowardPeg(1_100e18, 1_000e18, true),
            "adding to excess token0 should be away from peg"
        );
    }

    function test_isTowardPeg_r1excess_buyingToken1() public pure {
        // r1 > r0 (excess token1) and zeroForOne=true (user gets token1)
        assertTrue(
            PegMonitor.isTowardPeg(1_000e18, 1_100e18, true),
            "removing excess token1 should be toward peg"
        );
    }

    function test_isTowardPeg_r1excess_sellingToken1() public pure {
        assertFalse(
            PegMonitor.isTowardPeg(1_000e18, 1_100e18, false),
            "adding to excess token1 should be away from peg"
        );
    }

    function test_isTowardPeg_atPeg_alwaysFalse() public pure {
        // At peg, any swap is technically away from peg
        assertFalse(PegMonitor.isTowardPeg(1e18, 1e18, true));
        assertFalse(PegMonitor.isTowardPeg(1e18, 1e18, false));
    }

    // ─── normalize ─────────────────────────────────────────────────────────────

    function test_normalize_18dec() public pure {
        assertEq(PegMonitor.normalize(1e18, 18), 1e18);
    }

    function test_normalize_6dec() public pure {
        // 1 USDC (6 dec) → 1e18 in 18-dec precision
        assertEq(PegMonitor.normalize(1e6, 6), 1e18);
    }

    function test_normalize_8dec() public pure {
        assertEq(PegMonitor.normalize(1e8, 8), 1e18);
    }
}
