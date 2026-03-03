// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  StableSwapMath
/// @notice Pure-math library for the two-asset Curve StableSwap invariant.
///
///         Invariant (n = 2):
///             4·A·(x + y) + D  =  4·A·D + D³ / (4·x·y)
///
///         All functions assume reserves are normalized to the same decimal
///         precision before being passed in. Division-before-multiplication
///         ordering is used throughout to keep intermediate values within
///         uint256 for practical pool sizes (up to ~10⁹ tokens at 18 dec).
library StableSwapMath {
    uint256 private constant MAX_ITERATIONS = 255;
    uint256 private constant N = 2; // number of assets (fixed for this pool)

    // ─── Public interface ───────────────────────────────────────────────────────

    /// @notice Compute the StableSwap invariant D via Newton-Raphson iteration.
    ///
    ///         Starting from D = x0 + x1, the recurrence is:
    ///             D_new = (Ann·S + 2·D_P) · D  /  ((Ann − 1)·D + 3·D_P)
    ///         where D_P = D³ / (4·x0·x1)  and  Ann = A·N = 2·A.
    ///
    /// @param x0 Reserve of token0 (normalized, same precision as x1).
    /// @param x1 Reserve of token1 (normalized, same precision as x0).
    /// @param A  Amplification coefficient (1–1000).
    /// @return D The StableSwap invariant.
    function calculateD(uint256 x0, uint256 x1, uint256 A)
        internal
        pure
        returns (uint256 D)
    {
        if (x0 == 0 || x1 == 0) revert("SSM: zero reserve");
        require(A >= 1 && A <= 1000, "SSM: A out of range");

        uint256 S   = x0 + x1;
        uint256 Ann = A * N; // 2·A

        D = S;
        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            // D_P = D³ / (4·x0·x1)
            // Computed as two sequential divisions to avoid D³ overflow:
            //   step1 = D·D / (2·x0)
            //   D_P   = step1·D / (2·x1)
            uint256 D_P = (D * D / (2 * x0)) * D / (2 * x1);

            uint256 D_prev = D;
            // Newton step:
            // D = (Ann·S + 2·D_P)·D / ((Ann − 1)·D + 3·D_P)
            D = (Ann * S + 2 * D_P) * D / ((Ann - 1) * D + 3 * D_P);

            if (D > D_prev ? D - D_prev <= 1 : D_prev - D <= 1) break;
        }
    }

    /// @notice Compute the new reserve of the output token (y) given the new
    ///         reserve of the input token (x) and the invariant D.
    ///
    ///         Derived from the invariant solved for y:
    ///             y² + b·y = c
    ///         where  c = D³/(8·A·x)  and  b = x + D/(2A) − D.
    ///
    ///         Newton step:  y = (y² + c) / (2·y + b − D)
    ///
    /// @param x New reserve of the input token (after the swap amount is added).
    /// @param D StableSwap invariant obtained from calculateD.
    /// @param A Amplification coefficient (1–1000).
    /// @return y New reserve of the output token.
    function getY(uint256 x, uint256 D, uint256 A)
        internal
        pure
        returns (uint256 y)
    {
        require(x > 0, "SSM: x is zero");
        require(D > 0, "SSM: D is zero");

        uint256 Ann = A * N; // 2·A

        // c = D³ / (8·A·x)
        // Computed as: (D·D / (2·x)) · D / (Ann·2) = D³ / (4·Ann·x) = D³/(8Ax)
        uint256 c = (D * D / (2 * x)) * D / (Ann * 2);

        // b = x + D / Ann  (the raw denominator shift; D is subtracted in the step)
        uint256 b = x + D / Ann;

        y = D;
        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            uint256 y_prev = y;
            // Newton step: y = (y² + c) / (2·y + b − D)
            uint256 denom = 2 * y + b - D;
            require(denom > 0, "SSM: denom underflow");
            y = (y * y + c) / denom;

            if (y > y_prev ? y - y_prev <= 1 : y_prev - y <= 1) break;
        }
    }

    /// @notice Compute the output amount for a swap using the StableSwap curve.
    ///
    ///         Algorithm:
    ///           1. Calculate current invariant D from (reserveIn, reserveOut).
    ///           2. New reserveIn = reserveIn + amountIn.
    ///           3. Solve for new reserveOut using getY.
    ///           4. output = reserveOut − newReserveOut − 1  (rounding protection).
    ///
    /// @param amountIn   Token amount being swapped in (raw, fee-adjusted by caller).
    /// @param reserveIn  Current reserve of the input token.
    /// @param reserveOut Current reserve of the output token.
    /// @param A          Amplification coefficient.
    /// @return amountOut Amount of output token the pool sends out.
    function getSwapOutput(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 A
    ) internal pure returns (uint256 amountOut) {
        require(reserveIn > 0 && reserveOut > 0, "SSM: zero reserve");
        require(amountIn > 0, "SSM: zero input");

        uint256 D            = calculateD(reserveIn, reserveOut, A);
        uint256 newReserveIn = reserveIn + amountIn;
        uint256 newReserveOut = getY(newReserveIn, D, A);

        require(newReserveOut < reserveOut, "SSM: no positive output");
        // subtract 1 wei for rounding protection (pool keeps the dust)
        amountOut = reserveOut - newReserveOut - 1;
    }

    // ─── View helper (for off-chain / test use) ─────────────────────────────────

    /// @notice Verify that a given (x, y, D, A) tuple satisfies the invariant
    ///         within a relative tolerance of 0.001% (plus 2 wei absolute floor).
    ///         Useful in tests; not intended for production logic.
    /// @return ok True if the invariant holds within tolerance.
    function checkInvariant(uint256 x, uint256 y, uint256 D, uint256 A)
        internal
        pure
        returns (bool ok)
    {
        // LHS = 4·A·(x+y) + D
        uint256 lhs = 4 * A * (x + y) + D;
        // RHS = 4·A·D + D³/(4xy)
        uint256 rhs = 4 * A * D + (D * D / (2 * x)) * D / (2 * y);
        // Allow up to 0.001% relative error (integer division accumulates error)
        uint256 larger  = lhs > rhs ? lhs : rhs;
        uint256 maxErr  = larger / 100_000 + 2; // 0.001% + 2 wei floor
        uint256 absDiff = lhs >= rhs ? lhs - rhs : rhs - lhs;
        ok = absDiff <= maxErr;
    }
}
