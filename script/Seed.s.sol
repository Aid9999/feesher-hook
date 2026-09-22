// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FeeshSeeder} from "../src/FeeshSeeder.sol";

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IV3PoolPrice {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// Seeds both sides of the book, in one transaction each:
///   1. the whole FEESHER balance of the seeder as one position reaching down
///      to the lowest usable tick (ask side);
///   2. SEED_ETH_WEI of native ETH, sent to the seeder and added just above
///      spot over ETH_WIDTH ticks (bid side), so the pool quotes in both
///      directions from the first block. Skipped when SEED_ETH_WEI is 0.
/// Neither position can ever be withdrawn: the seeder has no removal path.
///
/// Aborts unless the pool price corresponds to START_FDV_USD (default 20000)
/// within 2% at the current ETH/USD of ETH_USD_POOL.
/// env: PRIVATE_KEY, POOL_MANAGER, SEEDER, FEESH_TOKEN, HOOK, SEED_ETH_WEI,
///      ETH_WIDTH (default 6000 ticks, about 1.8x of price)
contract Seed is Script {
    /// Wider than the full tick range and a multiple of the tick spacing (60),
    /// so depositSupply clamps to minUsableTick and the ask side reaches the
    /// lowest usable price: the supply on offer never runs out and the price
    /// has no ceiling.
    int24 constant FULL_RANGE_WIDTH = 1_774_440;

    function run() external {
        FeeshSeeder seeder = FeeshSeeder(payable(vm.envAddress("SEEDER")));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(vm.envAddress("FEESH_TOKEN")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(vm.envAddress("HOOK"))
        });
        // pool price check (StateLibrary: pools mapping at slot 6, slot0 packed first)
        bytes32 poolId = keccak256(abi.encode(key));
        uint256 raw = uint256(IExtsload(vm.envAddress("POOL_MANAGER")).extsload(keccak256(abi.encode(poolId, uint256(6)))));
        uint256 sqrtP = uint160(raw);
        require(sqrtP != 0, "pool not initialized");
        uint256 tokensPerEth = (sqrtP * sqrtP) >> 192;
        (uint160 sq,,,,,,) = IV3PoolPrice(vm.envOr("ETH_USD_POOL", 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a)).slot0();
        uint256 ethUsdE6 = (uint256(sq) * uint256(sq) * 1e18) >> 192;
        uint256 fdvUsd = (4_444_000 * ethUsdE6) / tokensPerEth / 1e6;
        uint256 target = vm.envOr("START_FDV_USD", uint256(20_000));
        console2.log("pool FEESH per ETH:", tokensPerEth, "implied FDV USD:", fdvUsd);
        require(fdvUsd * 100 >= target * 98 && fdvUsd * 100 <= target * 102, "pool price does not match START_FDV_USD");

        uint256 ethWei = vm.envOr("SEED_ETH_WEI", uint256(0));
        int24 ethWidth = int24(int256(vm.envOr("ETH_WIDTH", uint256(6000))));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        seeder.depositSupply(key, FULL_RANGE_WIDTH);
        if (ethWei > 0) {
            (bool ok,) = payable(address(seeder)).call{value: ethWei}("");
            require(ok, "funding the seeder failed");
            seeder.depositEth(key, ethWidth);
        }
        vm.stopBroadcast();
        console2.log("seeded: ask side full range, bid side wei:", ethWei);
    }
}
