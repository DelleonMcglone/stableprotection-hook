// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PegZone} from "../types/SPTypes.sol";

/// @title  PegMonitor
/// @notice Pure library for peg zone classification and derived fee/A calculations.
///
///         Zone thresholds (deviation = |r0 − r1| · 10000 / avg):
///           HEALTHY  ≤   10 bps (0.10%)   →  1 bps base fee
///           MINOR    ≤   50 bps (0.50%)   →  5 bps base fee
///           MODERATE ≤  200 bps (2.00%)   → 15 bps base fee
///           SEVERE   ≤  500 bps (5.00%)   → 50 bps base fee
///           CRITICAL >  500 bps (5.00%)   → circuit breaker
///
///         All fee values are expressed in ppm (hundredths of a basis point).
///         1 bps = 100 ppm.  Fee cap is enforced by the caller via maxFee.
///
///         Directional multipliers (applied to the zone base fee):
///           Toward-peg  swap:  × 0.5  (discounted, incentivises restoration)
///           Away-from-peg swap:× 3.0  (premium,    disincentivises depeg)
library PegMonitor {
    // ─── Zone thresholds (bps) ─────────────────────────────────────────────────
    uint256 internal constant HEALTHY_BPS  =  10;
    uint256 internal constant MINOR_BPS    =  50;
    uint256 internal constant MODERATE_BPS = 200;
    uint256 internal constant SEVERE_BPS   = 500;

    // ─── Zone base fees (ppm; 100 ppm = 1 bps) ─────────────────────────────────
    uint24 internal constant FEE_HEALTHY  =  100; //  1 bps
    uint24 internal constant FEE_MINOR    =  500; //  5 bps
    uint24 internal constant FEE_MODERATE = 1500; // 15 bps
    uint24 internal constant FEE_SEVERE   = 5000; // 50 bps

    // ─── Directional fee multipliers (scaled by BPS_DENOM) ────────────────────
    // toward-peg:  base × 5000/10000 = 0.5×
    uint256 internal constant TOWARD_MULT  = 5000;
    // away-from-peg: base × 30000/10000 = 3.0×
    uint256 internal constant AWAY_MULT    = 30000;

    // ─── Dynamic A multipliers per zone (scaled by BPS_DENOM) ─────────────────
    uint256 internal constant A_MULT_HEALTHY  = 10000; // 100% of base A
    uint256 internal constant A_MULT_MINOR    =  8000; //  80%
    uint256 internal constant A_MULT_MODERATE =  5000; //  50%
    uint256 internal constant A_MULT_SEVERE   =  2500; //  25%
    uint256 internal constant A_MULT_CRITICAL =  1000; //  10%

    uint256 private constant BPS_DENOM = 10000;

    // ─── Core functions ────────────────────────────────────────────────────────

    /// @notice Classify the peg zone from normalized reserves.
    ///
    ///         Deviation = |r0 − r1| × 10000 / ((r0 + r1) / 2)  (in bps).
    ///         Zero reserves → CRITICAL immediately (pool is unusable).
    ///
    /// @param r0norm Reserve of token0 normalized to 18 decimal precision.
    /// @param r1norm Reserve of token1 normalized to 18 decimal precision.
    /// @return zone         Classified PegZone.
    /// @return deviationBps Deviation magnitude in basis points.
    function classifyZone(uint256 r0norm, uint256 r1norm)
        internal
        pure
        returns (PegZone zone, uint256 deviationBps)
    {
        if (r0norm == 0 || r1norm == 0) {
            return (PegZone.CRITICAL, type(uint256).max);
        }

        uint256 diff = r0norm > r1norm ? r0norm - r1norm : r1norm - r0norm;
        // avg = (r0 + r1) / 2  (integer division rounds down — acceptable)
        uint256 avg  = (r0norm + r1norm) / 2;
        deviationBps = diff * BPS_DENOM / avg;

        if      (deviationBps <= HEALTHY_BPS)  zone = PegZone.HEALTHY;
        else if (deviationBps <= MINOR_BPS)    zone = PegZone.MINOR;
        else if (deviationBps <= MODERATE_BPS) zone = PegZone.MODERATE;
        else if (deviationBps <= SEVERE_BPS)   zone = PegZone.SEVERE;
        else                                   zone = PegZone.CRITICAL;
    }

    /// @notice Compute the directional fee for a swap.
    ///
    ///         Uses the zone's base fee scaled by the directional multiplier,
    ///         then clamps to maxFee.
    ///
    /// @param zone      Current peg zone.
    /// @param towardPeg True if this swap moves reserves toward parity.
    /// @param maxFee    Hard cap on the fee, in ppm.
    /// @return fee      Effective fee in ppm, capped at maxFee.
    function calculateFee(PegZone zone, bool towardPeg, uint24 maxFee)
        internal
        pure
        returns (uint24 fee)
    {
        uint256 base = _zoneFee(zone);
        uint256 mult = towardPeg ? TOWARD_MULT : AWAY_MULT;
        uint256 raw  = base * mult / BPS_DENOM;
        fee = raw > maxFee ? maxFee : uint24(raw);
    }

    /// @notice Compute the effective amplification coefficient for a zone.
    ///
    ///         A is reduced as deviation worsens so the curve becomes more
    ///         like constant-product in crisis (increasing slippage penalty).
    ///
    /// @param baseA Base amplification from pool config.
    /// @param zone  Current peg zone.
    /// @return effA Effective A (minimum 1).
    function calculateDynamicA(uint256 baseA, PegZone zone)
        internal
        pure
        returns (uint256 effA)
    {
        effA = baseA * _zoneAMult(zone) / BPS_DENOM;
        if (effA < 1) effA = 1;
    }

    /// @notice Determine whether a swap direction moves reserves toward parity.
    ///
    ///         For a 1:1-pegged pair:
    ///           • If r0 > r1 (excess token0), restoring means reducing r0
    ///             → user takes token0 out → zeroForOne = false.
    ///           • If r1 > r0 (excess token1), restoring means reducing r1
    ///             → user takes token1 out → zeroForOne = true.
    ///
    /// @param r0norm     Normalized reserve of token0.
    /// @param r1norm     Normalized reserve of token1.
    /// @param zeroForOne True = selling token0 for token1.
    /// @return           True if this swap direction moves closer to peg.
    function isTowardPeg(uint256 r0norm, uint256 r1norm, bool zeroForOne)
        internal
        pure
        returns (bool)
    {
        if (r0norm == r1norm) return false; // already at peg; any swap diverges
        bool r0excess = r0norm > r1norm;
        // r0 excess → reduce r0 → user takes token0 → zeroForOne=false → !zeroForOne
        // r1 excess → reduce r1 → user takes token1 → zeroForOne=true  →  zeroForOne
        // toward-peg iff zeroForOne == !r0excess  ↔  zeroForOne != r0excess
        return zeroForOne != r0excess;
    }

    /// @notice Normalize a raw reserve to 18-decimal precision.
    ///
    /// @param rawReserve  Raw reserve amount from the pool.
    /// @param decimals    Decimal precision of the token (1–18).
    /// @return            Reserve scaled to 1e18.
    function normalize(uint256 rawReserve, uint8 decimals)
        internal
        pure
        returns (uint256)
    {
        if (decimals == 18) return rawReserve;
        if (decimals > 18) return rawReserve / (10 ** (decimals - 18));
        return rawReserve * (10 ** (18 - decimals));
    }

    // ─── Internal helpers ───────────────────────────────────────────────────────

    function _zoneFee(PegZone zone) private pure returns (uint24) {
        if (zone == PegZone.HEALTHY)  return FEE_HEALTHY;
        if (zone == PegZone.MINOR)    return FEE_MINOR;
        if (zone == PegZone.MODERATE) return FEE_MODERATE;
        // SEVERE and CRITICAL both use the SEVERE fee; CB prevents CRITICAL swaps
        return FEE_SEVERE;
    }

    function _zoneAMult(PegZone zone) private pure returns (uint256) {
        if (zone == PegZone.HEALTHY)  return A_MULT_HEALTHY;
        if (zone == PegZone.MINOR)    return A_MULT_MINOR;
        if (zone == PegZone.MODERATE) return A_MULT_MODERATE;
        if (zone == PegZone.SEVERE)   return A_MULT_SEVERE;
        return A_MULT_CRITICAL;
    }
}
