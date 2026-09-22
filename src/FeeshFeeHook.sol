// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title FeeshFeeHook
/// @notice Uniswap v4 hook for the native ETH / FEESHER pool.
///
/// The pool is an ordinary 0.3% fee tier (`fee = 3000`, `tickSpacing = 60`):
/// liquidity providers earn the pool fee exactly as they would in a pool with
/// no hook at all, and the protocol fee the PoolManager may switch on applies
/// to it untouched. The hook never overrides the LP fee, never sets a dynamic
/// fee and never calls into the PoolManager's fee accounting.
///
/// On top of that, every swap pays a separate fee in native ETH, transferred to
/// `feeRecipient` with a single `poolManager.take` inside the swap. The hook
/// holds no balance, reads no external contract and runs no loop; what happens
/// to the fee afterwards is entirely the recipient's business.
///
/// Where the fee is taken from, per swap shape
/// (currency0 = native ETH, currency1 = FEESHER):
///   - buy,  exact input  (ETH -> FEESHER): from the ETH sent in     (beforeSwap)
///   - sell, exact output (FEESHER -> ETH): added to the ETH owed     (beforeSwap)
///   - sell, exact input  (FEESHER -> ETH): from the ETH paid out     (afterSwap)
///   - buy,  exact output (ETH -> FEESHER): added to the ETH sent in  (afterSwap)
/// All four are charged at the same rate on the gross ETH leg, so no swap shape
/// is cheaper or more expensive than another.
///
/// Fee schedule: `openingFeeBps` at the moment `openTrading()` is called,
/// decaying linearly to `baseFeeBps` over OPENING_PERIOD (10 seconds), then
/// `baseFeeBps` (3%) forever. The opening step exists only to make the first
/// block unattractive to snipe. Swaps revert before `openTrading()`.
///
/// What the owner can never do, by construction:
///   - re-close trading: `openTrading` reverts once `tradingOpenedAt` is set,
///     and nothing else in the contract writes that slot;
///   - raise the fee after the open: `setFeeSchedule` rejects any value above
///     the current one once trading is open, so the schedule a swapper sees at
///     the open is the worst case it can ever face;
///   - block, tax or blacklist an address: no such code path exists here or in
///     the token;
///   - touch liquidity, balances or the pool's price: the hook holds no
///     balance and never calls `modifyLiquidity`, `donate` or `swap`;
///   - upgrade anything: no proxy, no delegatecall, `poolManager` and
///     `feeshToken` are immutable.
/// The only owner powers are `openTrading` (one way), `setFeeRecipient` and
/// `setFeeSchedule` (downward once open).
///
/// Pool exclusivity: the hook is also the gatekeeper for FEESHER entering the
/// PoolManager. During this pool's swaps and liquidity additions it grants a
/// transient permit for the exact FEESHER amount owed; FeeshToken consults it on
/// every transfer toward the PoolManager and reverts anything beyond it, so a
/// rival v4 pool cannot be funded. The permit lives in the token's
/// configuration and can be switched off there without touching this hook.
/// Nothing outside the v4 PoolManager is restricted.
///
/// Every callback also checks the pool key it was handed, so a pool anyone else
/// creates with this hook address cannot borrow its permits or its fee logic.
///
/// Deployment: the hook address must encode the permission flags
/// BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA |
/// AFTER_SWAP_RETURNS_DELTA | AFTER_ADD_LIQUIDITY (0x4CC), found by a CREATE2
/// salt search after the token is deployed.
contract FeeshFeeHook is IHooks, IUnlockCallback, Ownable {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    address public immutable feeshToken;

    /// Transient storage slot holding the FEESH deposit permit (EIP-1967 style derivation).
    bytes32 internal constant DEPOSIT_PERMIT_SLOT = bytes32(uint256(keccak256("FeeshFeeHook.depositPermit")) - 1);

    address public feeRecipient;
    /// Timestamp of openTrading(); zero while trading is closed.
    uint64 public tradingOpenedAt;
    /// Fee at the moment trading opens, in bps.
    uint16 public openingFeeBps = 9000;
    /// Fee from the end of OPENING_PERIOD onward, in bps.
    uint16 public baseFeeBps = 300;
    uint32 public constant OPENING_PERIOD = 10;
    uint16 public constant MAX_FEE_BPS = 9000;
    /// Pool parameters accepted by the callbacks. Any other pool key that
    /// references this hook reverts with UnsupportedPool.
    uint24 public constant POOL_FEE = 3000;
    int24 public constant POOL_TICK_SPACING = 60;

    /// Fees that could not be transferred during a swap (a PoolManager without
    /// a native float settles at the end of the unlock), held as ERC-6909
    /// claims until `collectFees`.
    uint256 public pendingFees;

    event TradingOpened(uint256 at);
    event FeeTaken(address indexed recipient, uint256 amount);
    event FeeDeferred(uint256 amount);

    error CallerNotManager();
    error AlreadyOpen();
    error InvalidFeeSchedule();
    error TradingNotOpen();
    error CallbackDisabled();
    error DepositNotPermitted();
    error NoPendingFees();
    error UnsupportedPool();

    // The owner is passed explicitly: with CREATE2 deployment msg.sender is the factory.
    constructor(IPoolManager pm, address recipient, address token, address owner_) Ownable(owner_) {
        poolManager = pm;
        feeRecipient = recipient;
        feeshToken = token;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert CallerNotManager();
        _;
    }

    modifier onlySupportedPool(PoolKey calldata key) {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != feeshToken
                || key.fee != POOL_FEE || key.tickSpacing != POOL_TICK_SPACING
        ) revert UnsupportedPool();
        _;
    }

    // ---------------------------------------------------------------- control

    /// @notice Opens trading; swaps revert before this call.
    function openTrading() external onlyOwner {
        if (tradingOpenedAt != 0) revert AlreadyOpen();
        tradingOpenedAt = uint64(block.timestamp);
        emit TradingOpened(block.timestamp);
    }

    function setFeeRecipient(address r) external onlyOwner { feeRecipient = r; }

    /// @notice Sets opening and base fees. Requires base <= opening <= MAX_FEE_BPS;
    ///         once trading is open, neither value may increase.
    function setFeeSchedule(uint16 opening, uint16 base) external onlyOwner {
        if (opening > MAX_FEE_BPS || base > opening) revert InvalidFeeSchedule();
        if (tradingOpenedAt != 0 && (opening > openingFeeBps || base > baseFeeBps)) revert InvalidFeeSchedule();
        openingFeeBps = opening;
        baseFeeBps = base;
    }

    /// @notice Fee in bps at the current timestamp: base + (opening - base) * remaining / OPENING_PERIOD.
    function feeBps() public view returns (uint256) {
        uint256 opened = tradingOpenedAt;
        if (opened == 0) return openingFeeBps;
        uint256 elapsed = block.timestamp - opened;
        if (elapsed >= OPENING_PERIOD) return baseFeeBps;
        return baseFeeBps + (uint256(openingFeeBps - baseFeeBps) * (OPENING_PERIOD - elapsed)) / OPENING_PERIOD;
    }

    // ------------------------------------------------------------------- fee

    function _takeFee(uint256 amount) internal {
        if (amount == 0) return;
        // fast path: hand the fee straight to the recipient. If the
        // PoolManager holds no native float yet, bank it as an ERC-6909 claim
        // and let collectFees() cash it out.
        try poolManager.take(Currency.wrap(address(0)), feeRecipient, amount) {
            emit FeeTaken(feeRecipient, amount);
        } catch {
            poolManager.mint(address(this), 0, amount); // id 0 = native ETH
            pendingFees += amount;
            emit FeeDeferred(amount);
        }
    }

    /// @notice Pays banked fees out to `feeRecipient`. Callable by anyone.
    function collectFees() external {
        if (pendingFees == 0) revert NoPendingFees();
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external onlyManager returns (bytes memory) {
        uint256 amount = pendingFees;
        pendingFees = 0;
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), feeRecipient, amount);
        emit FeeTaken(feeRecipient, amount);
        return "";
    }

    // --------------------------------------------------------- deposit permits

    function _permitDeposit(uint256 amount) internal {
        bytes32 slot = DEPOSIT_PERMIT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), amount))
        }
    }

    /// @notice Called by FeeshToken on transfers to the PoolManager; consumes
    ///         the transient allowance or reverts.
    function spendDepositPermit(uint256 amount) external {
        if (msg.sender != feeshToken) revert DepositNotPermitted();
        bytes32 slot = DEPOSIT_PERMIT_SLOT;
        uint256 allowed;
        assembly ("memory-safe") {
            allowed := tload(slot)
        }
        if (allowed < amount) revert DepositNotPermitted();
        assembly ("memory-safe") {
            tstore(slot, sub(allowed, amount))
        }
    }

    // ------------------------------------------------------------ swap hooks

    /// Charges exact-input buys and exact-output sells, where ETH is the
    /// specified currency.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        onlySupportedPool(key)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (tradingOpenedAt == 0) revert TradingNotOpen();
        // zeroForOne = native in (currency0); amountSpecified < 0 = exact input
        if (params.zeroForOne && params.amountSpecified < 0) {
            uint256 nativeIn = uint256(-params.amountSpecified);
            uint256 fee = (nativeIn * feeBps()) / 10_000;
            _takeFee(fee);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
        }
        // exact-output sell: amountToSwap becomes X + fee, the hook is credited
        // the fee and the swapper receives X; fee = X * bps / (10000 - bps),
        // i.e. bps of the gross output
        if (!params.zeroForOne && params.amountSpecified > 0) {
            uint256 bps = feeBps();
            uint256 fee = (uint256(params.amountSpecified) * bps) / (10_000 - bps);
            _takeFee(fee);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// Charges exact-input sells and exact-output buys, where ETH is the
    /// unspecified currency, and grants the FEESH deposit permit for sells.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        onlySupportedPool(key)
        returns (bytes4, int128)
    {
        uint256 gross;
        if (!params.zeroForOne && params.amountSpecified < 0) {
            // exact-input sell: user receives native (delta.amount0 > 0)
            int128 nativeOut = delta.amount0();
            if (nativeOut > 0) gross = uint256(uint128(nativeOut));
        } else if (params.zeroForOne && params.amountSpecified > 0) {
            // exact-output buy: user owes native (delta.amount0 < 0)
            int128 nativeIn = delta.amount0();
            if (nativeIn < 0) gross = uint256(uint128(-nativeIn));
        }
        uint256 fee = (gross * feeBps()) / 10_000;
        _takeFee(fee);
        // FEESH owed to the PoolManager by this swap
        int128 feeshOwed = delta.amount1();
        if (feeshOwed < 0) _permitDeposit(uint256(uint128(-feeshOwed)));
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// Grants the FEESH deposit permit for a liquidity addition to this pool.
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyManager onlySupportedPool(key) returns (bytes4, BalanceDelta) {
        int128 feeshOwed = delta.amount1();
        if (feeshOwed < 0) _permitDeposit(uint256(uint128(-feeshOwed)));
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // --------------------------------------- unused callbacks (flags are off)

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) { revert CallbackDisabled(); }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) { revert CallbackDisabled(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert CallbackDisabled(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert CallbackDisabled(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert CallbackDisabled(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert CallbackDisabled(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert CallbackDisabled(); }
}
