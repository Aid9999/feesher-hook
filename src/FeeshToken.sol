// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

interface IDepositPermit {
    function spendDepositPermit(uint256 amount) external;
}

/// @title FeeshToken — "Feesher Hook" ($FEESHER)
/// @notice ERC-20 with a fixed supply minted to the deployer at construction.
///         No owner, no mint, no burn, no pause, no transfer tax, no blacklist
///         and no per-address limit. Balances move freely between wallets.
///
/// The single restriction is the v4 deposit permit: a transfer INTO the v4
/// PoolManager calls `spendDepositPermit` on the configured hook, which reverts
/// unless the hook authorized that exact amount earlier in the same
/// transaction. The hook authorizes it for swaps and liquidity additions in its
/// own pool, so the token can only be deposited into that pool and a rival v4
/// pool cannot be funded. Every other transfer, including to any Uniswap v2 or
/// v3 pool, any CEX, any bridge or any wallet, is untouched.
///
/// `configure` is one-shot and `disableGuard` is one-way: the deployer can drop
/// the restriction for good, but can never turn it back on or point it
/// somewhere else.
contract FeeshToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 4_444_000e18; // 4444 NFTs x 1000 FEESHER

    address public immutable deployer;
    address public guardedManager;
    address public guardHook;
    bool public configured;

    event Configured(address poolManager, address hook);

    constructor() ERC20("Feesher Hook", "FEESHER") {
        deployer = msg.sender;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Sets the PoolManager and hook addresses. Deployer only, callable once.
    function configure(address poolManager_, address hook_) external {
        require(msg.sender == deployer, "not deployer");
        require(!configured, "wired");
        require(poolManager_ != address(0) && hook_ != address(0), "zero");
        guardedManager = poolManager_;
        guardHook = hook_;
        configured = true;
        emit Configured(poolManager_, hook_);
    }

    /// @notice Drops the v4 deposit restriction for good. Deployer only, one way:
    ///         once off it cannot be turned back on, and `configure` stays spent.
    function disableGuard() external {
        require(msg.sender == deployer, "not deployer");
        guardedManager = address(0);
        guardHook = address(0);
        emit Configured(address(0), address(0));
    }

    function _update(address from, address to, uint256 value) internal override {
        // inflow to the v4 PoolManager requires the hook's transient allowance
        if (to == guardedManager && to != address(0)) {
            IDepositPermit(guardHook).spendDepositPermit(value);
        }
        super._update(from, to, value);
    }
}
