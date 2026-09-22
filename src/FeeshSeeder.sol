// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title FeeshSeeder
/// @notice Owner-operated unlock-callback contract that adds liquidity to the
///         pool and can swap. It has no liquidity removal path, so positions it
///         creates cannot be withdrawn.
///
/// withdrawLoose() transfers only token and ETH balances held by this contract;
/// it does not affect liquidity positions.
///
/// depositSupply() seeds the ask side (token below spot, down to the lowest
/// usable tick, so the supply on offer never runs out and the price has no
/// ceiling) and depositEth() seeds the bid side with whatever ETH was sent
/// here. Neither can be undone.
contract FeeshSeeder is Ownable, IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable token;

    constructor(IPoolManager m, address token_) Ownable(msg.sender) {
        manager = m;
        token = token_;
    }

    /// @notice Adds the contract's entire FEESH balance as one single-sided
    ///         position in [floor(tick) - spacing - width, floor(tick) - spacing].
    ///         Reverts if any ETH would be required.
    function depositSupply(PoolKey calldata key, int24 width) external onlyOwner {
        require(width > 0 && width % key.tickSpacing == 0, "width not aligned");
        manager.unlock(abi.encode(uint8(1), abi.encode(key, width)));
    }

    /// @notice Adds the contract's entire ETH balance as one single-sided
    ///         position in [ceil(tick) + spacing, ceil(tick) + spacing + width],
    ///         the bid side of the book. Reverts if any token would be required.
    function depositEth(PoolKey calldata key, int24 width) external onlyOwner {
        require(width > 0 && width % key.tickSpacing == 0, "width not aligned");
        manager.unlock(abi.encode(uint8(5), abi.encode(key, width)));
    }

    /// @notice Adds liquidity to an arbitrary range (add only).
    function addRange(PoolKey calldata key, int24 lo, int24 hi, int256 liq) external onlyOwner {
        require(liq > 0, "add only");
        manager.unlock(abi.encode(uint8(2), abi.encode(key, lo, hi, liq)));
    }

    function swapExactEthIn(PoolKey calldata key, uint256 ethIn) external payable onlyOwner {
        manager.unlock(abi.encode(uint8(3), abi.encode(key, ethIn)));
    }

    function swapExactFeeshIn(PoolKey calldata key, uint256 tokenIn) external onlyOwner {
        manager.unlock(abi.encode(uint8(4), abi.encode(key, tokenIn)));
    }

    function withdrawLoose(address payable to) external onlyOwner {
        uint256 b = IERC20Min(token).balanceOf(address(this));
        if (b > 0) IERC20Min(token).transfer(to, b);
        if (address(this).balance > 0) {
            (bool ok, ) = to.call{value: address(this).balance}("");
            require(ok, "send");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint8 what, bytes memory inner) = abi.decode(data, (uint8, bytes));

        if (what == 1) {
            (PoolKey memory key, int24 width) = abi.decode(inner, (PoolKey, int24));
            (uint160 sqrtP, int24 tick) = _slot0(key);
            require(sqrtP != 0, "pool not initialized");
            int24 hi = (tick / key.tickSpacing) * key.tickSpacing - key.tickSpacing;
            int24 lo = hi - width;
            if (lo < TickMath.minUsableTick(key.tickSpacing)) lo = TickMath.minUsableTick(key.tickSpacing);
            require(lo < hi, "width");
            uint256 bal = IERC20Min(token).balanceOf(address(this));
            require(bal > 0, "nothing to seed");
            // range below spot holds token1 only: amount1 = L * (sqrtHi - sqrtLo) / Q96,
            // L is derived from the balance minus a rounding margin
            uint160 sqrtLo = TickMath.getSqrtPriceAtTick(lo);
            uint160 sqrtHi = TickMath.getSqrtPriceAtTick(hi);
            uint256 liq = FullMath.mulDiv(bal, FixedPoint96.Q96, sqrtHi - sqrtLo);
            if (liq > 1e3) liq -= 1e3;
            (BalanceDelta delta, ) = manager.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(liq), salt: bytes32(0)}), ""
            );
            require(delta.amount0() == 0, "ETH was required");
            _clearDeltas(delta);
        } else if (what == 2) {
            (PoolKey memory key, int24 lo, int24 hi, int256 liq) =
                abi.decode(inner, (PoolKey, int24, int24, int256));
            (BalanceDelta delta, ) = manager.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: bytes32(0)}), ""
            );
            _clearDeltas(delta);
        } else if (what == 3) {
            (PoolKey memory key, uint256 ethIn) = abi.decode(inner, (PoolKey, uint256));
            BalanceDelta delta = manager.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
            _clearDeltas(delta);
        } else if (what == 5) {
            (PoolKey memory key, int24 width) = abi.decode(inner, (PoolKey, int24));
            (uint160 sqrtP, int24 tick) = _slot0(key);
            require(sqrtP != 0, "pool not initialized");
            // truncation is toward zero, so adding one spacing always lands above spot
            int24 lo = (tick / key.tickSpacing) * key.tickSpacing + key.tickSpacing;
            int24 hi = lo + width;
            if (hi > TickMath.maxUsableTick(key.tickSpacing)) hi = TickMath.maxUsableTick(key.tickSpacing);
            require(lo < hi, "width");
            uint256 bal = address(this).balance;
            require(bal > 0, "nothing to seed");
            // range above spot holds token0 only:
            // amount0 = L * (sqrtHi - sqrtLo) * Q96 / (sqrtHi * sqrtLo)
            uint160 sqrtLo = TickMath.getSqrtPriceAtTick(lo);
            uint160 sqrtHi = TickMath.getSqrtPriceAtTick(hi);
            uint256 liq = FullMath.mulDiv(
                bal, FullMath.mulDiv(sqrtLo, sqrtHi, FixedPoint96.Q96), sqrtHi - sqrtLo
            );
            if (liq > 1e3) liq -= 1e3;
            (BalanceDelta delta, ) = manager.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(liq), salt: bytes32(0)}), ""
            );
            require(delta.amount1() == 0, "token was required");
            _clearDeltas(delta);
        } else {
            (PoolKey memory key, uint256 tokenIn) = abi.decode(inner, (PoolKey, uint256));
            BalanceDelta delta = manager.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
                ""
            );
            _clearDeltas(delta);
        }
        return "";
    }

    function _slot0(PoolKey memory key) internal view returns (uint160 sqrtP, int24 tick) {
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 slot = keccak256(abi.encode(poolId, uint256(6)));
        bytes32 raw = manager.extsload(slot);
        sqrtP = uint160(uint256(raw));
        tick = int24(int256(uint256(raw) >> 160));
    }

    function _clearDeltas(BalanceDelta delta) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) manager.settle{value: uint256(uint128(-a0))}();
        if (a1 < 0) {
            manager.sync(Currency.wrap(token));
            IERC20Min(token).transfer(address(manager), uint256(uint128(-a1)));
            manager.settle();
        }
        if (a0 > 0) manager.take(Currency.wrap(address(0)), address(this), uint256(uint128(a0)));
        if (a1 > 0) manager.take(Currency.wrap(token), address(this), uint256(uint128(a1)));
    }

    receive() external payable {}
}
