// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

interface IERC20From {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title FeeshRouter
/// @notice Exact-input swaps between native ETH and FEESH in the hook's v4 pool.
///
/// swapEthForFeesh() and swapFeeshForEth() enforce a minimum output and send the output to the
/// caller. The contract has no owner and holds no balances between calls.
/// previewSwap() executes the swap inside unlock() and reverts with the output
/// amount; use it via eth_call.
contract FeeshRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable hook;

    uint24 public constant FEE = 3000;
    int24 public constant TICK_SPACING = 60;

    error CallerNotManager();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error Preview(uint256 amountOut);
    error ZeroAmount();

    event Swapped(address indexed trader, bool ethIn, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager manager_, address token_, address hook_) {
        poolManager = manager_;
        token = token_;
        hook = hook_;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @notice Swaps msg.value ETH for FEESH. Reverts if output < minOut.
    function swapEthForFeesh(uint256 minOut) external payable returns (uint256 out) {
        if (msg.value == 0) revert ZeroAmount();
        out = abi.decode(poolManager.unlock(abi.encode(true, false, msg.sender, msg.value)), (uint256));
        if (out < minOut) revert InsufficientOutput(out, minOut);
        emit Swapped(msg.sender, true, msg.value, out);
    }

    /// @notice Swaps `amount` FEESH (requires allowance) for ETH. Reverts if output < minOut.
    function swapFeeshForEth(uint256 amount, uint256 minOut) external returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        out = abi.decode(poolManager.unlock(abi.encode(false, false, msg.sender, amount)), (uint256));
        if (out < minOut) revert InsufficientOutput(out, minOut);
        emit Swapped(msg.sender, false, amount, out);
    }

    /// @notice Output of a swap for `amountIn` at the current state, hook fee included.
    /// @dev The inner unlock always reverts with Preview(out); nothing is settled.
    function previewSwap(bool ethIn, uint256 amountIn) external returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        try poolManager.unlock(abi.encode(ethIn, true, msg.sender, amountIn)) {
            revert(); // unreachable: the quoting callback always reverts
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != Preview.selector) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
            assembly { out := mload(add(reason, 36)) }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotManager();
        (bool isBuy, bool quoting, address user, uint256 amountIn) = abi.decode(data, (bool, bool, address, uint256));
        PoolKey memory key = poolKey();
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: isBuy,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // caller deltas: negative = owed to the PoolManager, positive = receivable
        uint256 out = isBuy ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        if (quoting) revert Preview(out);

        if (isBuy) {
            poolManager.settle{value: uint256(-int256(delta.amount0()))}();
            poolManager.take(key.currency1, user, out);
        } else {
            poolManager.sync(key.currency1);
            IERC20From(token).transferFrom(user, address(poolManager), uint256(-int256(delta.amount1())));
            poolManager.settle();
            poolManager.take(key.currency0, user, out);
        }
        return abi.encode(out);
    }
}
