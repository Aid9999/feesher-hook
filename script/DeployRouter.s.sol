// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FeeshRouter} from "../src/FeeshRouter.sol";

/// Deploys FeeshRouter. env: PRIVATE_KEY, POOL_MANAGER, FEESH_TOKEN, HOOK
contract DeployRouter is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        FeeshRouter r = new FeeshRouter(IPoolManager(vm.envAddress("POOL_MANAGER")), vm.envAddress("FEESH_TOKEN"), vm.envAddress("HOOK"));
        vm.stopBroadcast();
        console2.log("FeeshRouter:", address(r));
    }
}
