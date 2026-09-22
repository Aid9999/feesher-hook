// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FeeshToken} from "../src/FeeshToken.sol";
import {FeeshFeeHook} from "../src/FeeshFeeHook.sol";
import {FeeshSeeder} from "../src/FeeshSeeder.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// Deploys the token, the seeder and the hook against an EXISTING pond, and
/// initializes the pool:
///   1. FeeshToken (whole supply minted to the broadcaster, no constructor
///      arguments, no venue restrictions)
///   2. FeeshSeeder, funded with everything but RESERVE_WEI
///   3. FeeshFeeHook at a CREATE2 address carrying the flags 0x4CC, paying its
///      fees to POND
///   4. token.configure(poolManager, hook) and pool initialize at fee 3000 /
///      tickSpacing 60
/// Follow-up owner calls: script/Seed.s.sol (both sides of the book),
/// pond.setPriceSource(...), hook.openTrading().
///
/// env: PRIVATE_KEY, POOL_MANAGER, POND, TOKENS_PER_ETH or START_FDV_USD
///      priced with ETH_USD_POOL, RESERVE_WEI
interface IV3PoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

contract DeployStack is Script {
    uint160 constant FLAGS = 0x4CC;
    uint160 constant MASK = 0x3FFF;
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address pm = vm.envAddress("POOL_MANAGER");
        address pond = vm.envAddress("POND");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        uint256 tokensPerEth = vm.envOr("TOKENS_PER_ETH", uint256(0));
        if (tokensPerEth == 0) {
            (uint160 sq,,,,,,) = IV3PoolSlot0(vm.envOr("ETH_USD_POOL", 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a)).slot0();
            uint256 ethUsdE6 = (uint256(sq) * uint256(sq) * 1e18) >> 192;
            uint256 fdvUsd = vm.envOr("START_FDV_USD", uint256(20_000));
            tokensPerEth = (4_444_000 * ethUsdE6) / (fdvUsd * 1e6);
        }

        vm.startBroadcast(deployer);
        FeeshToken token = new FeeshToken();
        FeeshSeeder seeder = new FeeshSeeder(IPoolManager(pm), address(token));
        // everything but the reserve goes into the pool; the reserve stays with
        // the deployer, visible on chain from the very first block
        uint256 reserve = vm.envOr("RESERVE_WEI", uint256(0));
        require(reserve <= token.INITIAL_SUPPLY() / 20, "reserve above 5%");
        token.transfer(address(seeder), token.INITIAL_SUPPLY() - reserve);
        vm.stopBroadcast();

        // search a CREATE2 salt for an address with flags 0x4CC
        bytes memory creation =
            abi.encodePacked(type(FeeshFeeHook).creationCode, abi.encode(pm, pond, address(token), deployer));
        bytes32 initHash = keccak256(creation);
        uint256 salt;
        address hookAddr;
        for (salt = 0; salt < 1_000_000; salt++) {
            hookAddr = address(uint160(uint256(
                keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY_ADDR, bytes32(salt), initHash))
            )));
            // flags must match and the address must not start with 0x91
            if (uint160(hookAddr) & MASK == FLAGS && uint160(hookAddr) >> 152 != 0x91) break;
        }
        require(uint160(hookAddr) & MASK == FLAGS, "no salt found");

        vm.startBroadcast(deployer);
        FeeshFeeHook hook = new FeeshFeeHook{salt: bytes32(salt)}(IPoolManager(pm), pond, address(token), deployer);
        require(address(hook) == hookAddr, "address mismatch");
        token.configure(pm, address(hook));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        // price = token1/token0 = FEESHER per ETH
        uint160 sqrtP0 = uint160(_sqrt((tokensPerEth * 1e18 << 96) / 1e18) << 48);
        IPoolManager(pm).initialize(key, sqrtP0);
        vm.stopBroadcast();

        console2.log("FeeshToken:   ", address(token));
        console2.log("FeeshSeeder:  ", address(seeder));
        console2.log("FeeshPond:    ", pond);
        console2.log("FeeshFeeHook: ", address(hook), "salt", salt);
        console2.log("poolId:", uint256(keccak256(abi.encode(key))));
        console2.log("pool key: fee 3000, tickSpacing 60, sqrtP0", sqrtP0);
        console2.log("FEESHER per ETH:", tokensPerEth);
        console2.log("reserve kept by deployer:", reserve);
        console2.log("seeded into the pool:", token.INITIAL_SUPPLY() - reserve);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
