// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FeeshPond, IFeesherCollection} from "../src/FeeshPond.sol";

/// Deploys a FeeshPond against an existing collection and points an existing
/// hook at it. The hook holds no state about the pond beyond the recipient
/// address, so the vault can be replaced without touching the pool.
///
/// env: PRIVATE_KEY, FEESHER_NFT, HOOK, FEESH_TOKEN, POOL_MANAGER, POOL_ID,
///      ETH_USD_POOL (zero uses ETH_USD_E6), ETH_USD_E6, MIN_FEE_WEI,
///      PROTOCOL_RECIPIENT (default: broadcaster)
interface IFeeHook {
    function setFeeRecipient(address r) external;
    function feeRecipient() external view returns (address);
}

contract DeployPondOnly is Script {
    function run() external {
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        address nft = vm.envAddress("FEESHER_NFT");
        address hook = vm.envAddress("HOOK");
        address recipient = vm.envOr("PROTOCOL_RECIPIENT", deployer);

        vm.startBroadcast(deployer);
        FeeshPond pond = new FeeshPond(IFeesherCollection(nft), recipient, deployer);
        pond.setPriceSource(
            vm.envAddress("FEESH_TOKEN"),
            vm.envAddress("POOL_MANAGER"),
            vm.envBytes32("POOL_ID"),
            vm.envOr("ETH_USD_POOL", address(0)),
            vm.envOr("ETH_USD_E6", uint256(0))
        );
        pond.setMinFee(vm.envOr("MIN_FEE_WEI", uint256(0)));
        IFeeHook(hook).setFeeRecipient(address(pond));
        vm.stopBroadcast();

        console2.log("FeeshPond:  ", address(pond));
        console2.log("hook now pays:", IFeeHook(hook).feeRecipient());
        console2.log("hold L1..L4:", pond.requiredHold(1), pond.requiredHold(4));
    }
}
