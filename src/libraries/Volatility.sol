// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/Console.sol";

/// @title Volatility library
/// @notice Provides functions that use Uniswap V4 to compute price volatility
library Volatility {
    error TimeToExpiryExceedsTotalDuration();
    error InvalidBaseFee();
    error LiquidityCannotBeZero();
    error sqrtTickTVLCannotBeZero();
    error ResultOverflow();
    error TotalDurationIsZero();

    uint256 constant RATE_VALUE = 1e18;
    uint256 constant SCALE = 1e18;

    struct PoolMetadata {
        // base dynamic fee of the pool
        uint24 baseFee;
        // the pool tick spacing
        int24 tickSpacing;
    }

    struct PoolData {
        // the current price (from pool.slot0())
        uint160 sqrtPriceX96;
        // the current tick (from pool.slot0())
        int24 currentTick;
        // the mean liquidity over some period (from OracleLibrary.consult())
        uint160 secondsPerLiquidityX128;
        // the number of seconds to look back when getting mean tick and mean liquidity
        uint32 oracleLookback;
        // the liquidity depth at currentTick (from pool.liquidity())
        uint128 tickLiquidity;
    }

    struct FeeGrowthGlobals {
        // the fee growth as a Q128.128 fees of token0 collected per unit of liquidity for the entire life of the pool
        uint256 feeGrowthGlobal0X128;
        // the fee growth as a Q128.128 fees of token1 collected per unit of liquidity for the entire life of the pool
        uint256 feeGrowthGlobal1X128;
        // the block timestamp at which feeGrowthGlobal0X128 and feeGrowthGlobal1X128 were last updated
        uint32 timestamp;
    }

    /**
     * @notice Estimates implied volatility with customizable timeframes and time decay (Theta)
     * @param metadata Pool's metadata (may be cached)
     * @param data A summary of the pool's state (from `pool.slot0` and `pool.observe`)
     * @param a Cumulative feeGrowthGlobals at a past point in time
     * @param b Cumulative feeGrowthGlobals at the current block
     * @param timeToExpiry Time remaining until the option's expiry (in seconds)
     * @param riskFeeRate Proxy for risk-fee interest rate (e.g., stablecoin lending rate)
     * @return Estimate of the implied volatility adjusted for theta and timeframe
     */
    function estimateVolatility(
        PoolMetadata memory metadata,
        PoolData memory data,
        FeeGrowthGlobals memory a,
        FeeGrowthGlobals memory b,
        uint32 timeToExpiry,
        uint256 riskFeeRate,
        uint32 totalDuration
    ) internal pure returns (uint256) {
        if (timeToExpiry >= totalDuration) revert TimeToExpiryExceedsTotalDuration();
        if (metadata.baseFee == 0) revert InvalidBaseFee();
        if (data.tickLiquidity == 0) revert LiquidityCannotBeZero();

        uint256 volumeGamma0Gamma1 = _computeVolumeGamma(metadata, data, a, b);

        // Calculate the liquidity value at the current tick and apply square root
        uint128 sqrtTickTVLX32 = uint128(
            FixedPointMathLib.sqrt(
                computeTickTVLX64(metadata.tickSpacing, data.currentTick, data.sqrtPriceX96, data.tickLiquidity)
            )
        );

        if (sqrtTickTVLX32 == 0) revert sqrtTickTVLCannotBeZero();

        // Adjust volatility for time decay (Theta)
        uint256 timeAdjustedVolatility = _applyThetaAdjustment(volumeGamma0Gamma1, timeToExpiry, totalDuration);

        // Adjust volatility for risk-free interest rate (Rho)
        uint256 riskFeeAdjustedVolatility = _applyRiskFreeRateAdjustment(timeAdjustedVolatility, riskFeeRate);

        return riskFeeAdjustedVolatility / sqrtTickTVLX32;
    }

    /**
     * @notice Estimates implied volatility using https://lambert-guillaume.medium.com/on-chain-volatility-and-uniswap-v3-d031b98143d1
     * @param metadata The pool's metadata (may be cached)
     * @param data A summary of the pool's state from `pool.slot0` `pool.observe` and `pool.liquidity`
     * @param a The pool's cumulative feeGrowthGlobals some time in the past
     * @param b The pool's cumulative feeGrowthGlobals as of the current block
     * @return An estimate of the 24 hour implied volatility scaled by 1e18
     */
    function estimate24H(
        PoolMetadata memory metadata,
        PoolData memory data,
        FeeGrowthGlobals memory a,
        FeeGrowthGlobals memory b
    ) internal pure returns (uint256) {
        uint256 volumeGamma0Gamma1;
        {
            uint128 revenue0Gamma1 = computeRevenueGamma(
                a.feeGrowthGlobal0X128,
                b.feeGrowthGlobal0X128,
                data.secondsPerLiquidityX128,
                data.oracleLookback,
                metadata.baseFee
            );
            uint128 revenue1Gamma0 = computeRevenueGamma(
                a.feeGrowthGlobal1X128,
                b.feeGrowthGlobal1X128,
                data.secondsPerLiquidityX128,
                data.oracleLookback,
                metadata.baseFee
            );

            // This is an approximation. Ideally the fees earned during each swap would be multiplied by the price
            // *at that swap*. But for prices simulated with GBM and swap sizes either normally or uniformly distributed,
            // the error you get from using geometric mean price is <1% even with high drift and volatility.
            volumeGamma0Gamma1 = revenue1Gamma0 + amount0ToAmount1(revenue0Gamma1, data.currentTick);
        }

        uint128 sqrtTickTVLX32 = uint128(
            FixedPointMathLib.sqrt(
                computeTickTVLX64(metadata.tickSpacing, data.currentTick, data.sqrtPriceX96, data.tickLiquidity)
            )
        );
        uint48 timeAdjustmentX32 = uint48(FixedPointMathLib.sqrt((uint256(1 days) << 64) / (b.timestamp - a.timestamp)));

        if (sqrtTickTVLX32 == 0) {
            return 0;
        }
        unchecked {
            return (uint256(2e18) * uint256(timeAdjustmentX32) * FixedPointMathLib.sqrt(volumeGamma0Gamma1))
                / sqrtTickTVLX32;
        }
    }

    /**
     * @notice Computes an `amount1` that (at `tick`) is equivalent in worth to the provided `amount0`
     * @param amount0 The amount of token0 to convert
     * @param tick The tick at which the conversion should hold true
     * @return amount1 An equivalent amount of token1
     */
    function amount0ToAmount1(uint128 amount0, int24 tick) internal pure returns (uint256 amount1) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint224 priceX96 = uint224(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96));

        amount1 = FullMath.mulDiv(amount0, priceX96, FixedPoint96.Q96);
    }

    /**
     * @notice Computes pool revenue using feeGrowthGlobal accumulators, then scales it down by a factor of gamma
     * @param feeGrowthGlobalAX128 The value of feeGrowthGlobal (either 0 or 1) at time A
     * @param feeGrowthGlobalBX128 The value of feeGrowthGlobal (either 0 or 1, but matching) at time B (B > A)
     * @param secondsPerLiquidityX128 The difference in the secondsPerLiquidity accumulator from `secondsAgo` seconds ago until now
     * @param secondsAgo The oracle lookback period that was used to find `secondsPerLiquidityX128`
     * @param baseFee The fee factor to scale by
     * @return Revenue over the period from `block.timestamp - secondsAgo` to `block.timestamp`, scaled down by a factor of gamma
     */
    function computeRevenueGamma(
        uint256 feeGrowthGlobalAX128,
        uint256 feeGrowthGlobalBX128,
        uint160 secondsPerLiquidityX128,
        uint32 secondsAgo,
        uint24 baseFee
    ) internal pure returns (uint128) {
        unchecked {
            uint256 temp = feeGrowthGlobalBX128 >= feeGrowthGlobalAX128
                ? feeGrowthGlobalBX128 - feeGrowthGlobalAX128
                : type(uint256).max + feeGrowthGlobalAX128 - feeGrowthGlobalBX128;

            temp = FullMath.mulDiv(temp, secondsAgo * baseFee, secondsPerLiquidityX128 * 1e6);
            return temp > type(uint128).max ? type(uint128).max : uint128(temp);
        }
    }

    /**
     * @notice Computes Delta, which measures the sensitivity of the option price to the price of the underlying asset
     * @param amount0 Amount of token0 involved in the swap
     * @param tick Current tick (price level)
     * @return Delta value for the option
     */
    function computeDelta(uint128 amount0, int24 tick) internal pure returns (uint256) {
        // Delta approximates how much the option price changes for a change in the underlying asset's price
        return amount0ToAmount1(amount0, tick);
    }

    /**
     * @notice Computes Vega, which measures the sensitivity of option price to volatility changes
     * @param volatility Current implied volatility
     * @return Vega value for the option
     */
    function computeVega(uint256 volatility) internal pure returns (uint256) {
        // Simple approximation for Vega as proportional to volatility (adjustable model)
        return volatility / RATE_VALUE;
    }

    /**
     * @notice Computes Rho, which measures the sensitivity of option price to the risk-free rate
     * @param riskFreeRate Current risk-free rate (scaled by 1e18)
     * @return Rho value for the option
     */
    function computeRho(uint256 riskFreeRate) internal pure returns (uint256) {
        // Rho affects how sensitive the option is to changes in interest rates (simplified model)
        return riskFreeRate;
    }

    /**
     * @notice Computes the value of liquidity available at the current tick, denominated in token1
     * @param tickSpacing The pool tick spacing (from pool.tickSpacing())
     * @param tick The current tick (from pool.slot0())
     * @param sqrtPriceX96 The current price (from pool.slot0())
     * @param liquidity The liquidity depth at currentTick (from pool.liquidity())
     */
    function computeTickTVLX64(int24 tickSpacing, int24 tick, uint160 sqrtPriceX96, uint128 liquidity)
        internal
        pure
        returns (uint256 tickTVL)
    {
        tick = _floor(tick, tickSpacing);

        // both value0 and value1 fit in uint192
        (uint256 value0, uint256 value1) = _getValuesOfLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick + tickSpacing), liquidity
        );

        tickTVL = (value0 + value1) << 64;
    }

    /**
     * @notice Computes the value of the liquidity in terms of token1
     * @dev Each return value can fit in a uint192 if necessary
     * @param sqrtRatioX96 A sqrt price representing the current pool prices
     * @param sqrtRatioAX96 A sqrt price representing the lower tick boundary
     * @param sqrtRatioBX96 A sqrt price representing the upper tick boundary
     * @param liquidity The liquidity being valued
     * @return value0 The value of amount0 underlying `liquidity`, in terms of token1
     * @return value1 The amount of token1
     */
    function _getValuesOfLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) private pure returns (uint256 value0, uint256 value1) {
        // console.log("sqrtRatioX96: %d", sqrtRatioX96);
        // console.log("sqrtRatioAX96: %d", sqrtRatioAX96);
        // console.log("sqrtRatioBX96: %d", sqrtRatioBX96);
        // console.log("Liquidity: %d", liquidity);
        assert(sqrtRatioAX96 <= sqrtRatioX96 && sqrtRatioX96 <= sqrtRatioBX96);
        // console.log("Passed assert");

        unchecked {
            uint224 numerator = uint224(FullMath.mulDiv(sqrtRatioX96, sqrtRatioBX96 - sqrtRatioX96, FixedPoint96.Q96));
            // console.log("Numerator: %d", numerator);

            value0 = FullMath.mulDiv(liquidity, numerator, sqrtRatioBX96);
            value1 = FullMath.mulDiv(liquidity, sqrtRatioX96 - sqrtRatioAX96, FixedPoint96.Q96);
            // console.log("Value0: %d", value0);
            // console.log("Value1: %d", value1);
        }
    }

    /// @notice Rounds down to the nearest tick where tick % tickSpacing == 0
    /// @param tick The tick to round
    /// @param tickSpacing The tick spacing of the pool
    /// @return the floored tick
    /// @dev Ensure tick +/- tickSpacing does not overflow or underflow int24
    function _floor(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 mod = tick % tickSpacing;

        unchecked {
            if (mod >= 0) {
                return tick - mod;
            } else {
                return tick - mod - tickSpacing;
            }
        }
    }

    /// @notice Computes the volume-adjusted gamma for fee growth
    function _computeVolumeGamma(
        PoolMetadata memory metadata,
        PoolData memory data,
        FeeGrowthGlobals memory a,
        FeeGrowthGlobals memory b
    ) private pure returns (uint256) {
        uint128 revenue0Gamma1 = computeRevenueGamma(
            a.feeGrowthGlobal0X128,
            b.feeGrowthGlobal0X128,
            data.secondsPerLiquidityX128,
            data.oracleLookback,
            metadata.baseFee
        );
        uint128 revenue1Gamma0 = computeRevenueGamma(
            a.feeGrowthGlobal1X128,
            b.feeGrowthGlobal1X128,
            data.secondsPerLiquidityX128,
            data.oracleLookback,
            metadata.baseFee
        );
        return revenue1Gamma0 + amount0ToAmount1(revenue0Gamma1, data.currentTick);
    }

    /// @notice Applies time decay (Theta) adjustment to the volatility estimate
    /// @param volumeGamma0Gamma1 Volume-derived volatility estimate
    /// @param timeToExpiry Time remaining until the option's expiry (in seconds)
    /// @return Volatility adjusted for time decay
    function _applyThetaAdjustment(uint256 volumeGamma0Gamma1, uint32 timeToExpiry, uint32 totalDuration)
        internal
        pure
        returns (uint256)
    {
        if (totalDuration == 0) revert TotalDurationIsZero();
        // As time decreases, volatility should also decrease
        if (timeToExpiry == 0) return volumeGamma0Gamma1; // No adjustment if optino already expired

        // Use normalized time to apply a proper decay, ensuring we are within range
        uint256 normalizedTime = (timeToExpiry * SCALE) / totalDuration;

        // Decay effect based on the ratio of time left to total time using exp(-normalizedTime)
        uint256 decayFactor = SCALE / exp(normalizedTime); // Invert to simulate e^(-x)

        return (volumeGamma0Gamma1 * decayFactor) / SCALE; // Apply the decay factor
    }

    /// @notice Adjusts volatility for the risk-free interest rate (Rho)
    /// @param timeAdjustedVolatility Volatility already adjusted for time decay
    /// @param riskFreeRate Annualized risk-free rate (scaled by 1e18)
    /// @return Volatility adjusted for the risk-free rate
    function _applyRiskFreeRateAdjustment(uint256 timeAdjustedVolatility, uint256 riskFreeRate)
        private
        pure
        returns (uint256)
    {
        // Higher risk-free rate generally redeuces volatility sensitivity (simplified Rho adjustment)
        return timeAdjustedVolatility * (SCALE - riskFreeRate) / SCALE;
    }

    /// @notice Approximate the exponential of a given number using a Taylor series
    /// @dev The input `x` should be scaled by 1e18 (fixed-point) for precision. The output is also scaled by 1e18.
    /// @param x The exponent in the expression e^x, scaled by 1e18
    /// @return result The result of e^x, scaled by 1e18
    function exp(uint256 x) private pure returns (uint256 result) {
        result = SCALE; // Start with 1 in fixed-point form (1e18)
        uint256 term = SCALE; // Term to keep track of x^n / n!

        // Handle small exponent case
        if (x == 0) return SCALE; // Return 1 if x is 0

        // Add the first 10 terms of the Taylor series for e^x
        unchecked {
            for (uint256 i = 1; i <= 10; ++i) {
                term = (term * x) / (SCALE * i); // Compute x^i / i!
                result += term; // Add the term to the result

                // Stop early if term is too small to affect the result
                if (term < 1e8) break;
            }
        }

        if (result < SCALE) revert ResultOverflow(); // Ensure the result is within bounds
    }
}
