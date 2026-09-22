// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {FeeshPond} from "../src/FeeshPond.sol";
import {FeeshFeeHook} from "../src/FeeshFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IRouter {
    function swapEthForFeesh(uint256 minOut) external payable returns (uint256);
    function swapFeeshForEth(uint256 amount, uint256 minOut) external returns (uint256);
}

interface IDrop {
    function setMaxSupply(uint256 v) external;
    function ownerMint(address to, uint256 qty) external;
    function owner() external view returns (address);
    function walletBalance(uint256 id) external view returns (uint256);
    function collect(uint256[] calldata ids) external returns (uint256);
    function liveTotal() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

/// The whole mechanism driven against the contracts that are actually
/// deployed on mainnet, on a fork of it. Nothing here is a mock: these are the
/// live addresses, the live pool and the live collection.
contract MainnetLiveTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IDrop constant DROP = IDrop(0x16F0Bf3F63b7eC7A6B92b0a9F678ec0FBF90A581);
    IERC20 constant TOKEN = IERC20(0xbD86E40099E38B4081eDC3CBf56ED201Cd533A9F);
    FeeshPond constant POND = FeeshPond(payable(0xcB44F2b726cB01f952691f4F81051190E2C51207));
    FeeshFeeHook constant HOOK = FeeshFeeHook(0x3d1F46aA87bbCdEcB3afb64Db6a84EAce32204cC);
    IRouter constant ROUTER = IRouter(0x6D7f16f7003783aE71562E7e257103e2c7Cff21e);
    address constant OWNER = 0xE36B78A44a9647B316000822Ac81391F580d3475;
    address constant ROLLER = 0x75D4674e0EFC842aDDc7741Dd96a20C448919D64;

    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
    }

    function _nextBlock() internal {
        vm.setBlockhash(block.number, keccak256(abi.encode("rh", block.number)));
        vm.roll(block.number + 1);
    }

    function test_theWholeThingOnMainnetContracts() public {
        console2.log("=== what is deployed ===");
        console2.log("token   ", TOKEN.name(), TOKEN.symbol());
        console2.log("supply  ", TOKEN.totalSupply() / 1e18);
        console2.log("reserve on owner", TOKEN.balanceOf(OWNER) / 1e18);
        console2.log("hook pays to    ", HOOK.feeRecipient());
        console2.log("trading opened  ", HOOK.tradingOpenedAt());
        console2.log("fee now (bps)   ", HOOK.feeBps());
        console2.log("hold L1 (FEESH) ", POND.requiredHold(1) / 1e18);
        console2.log("collection live ", DROP.liveTotal());

        // the collection has no mint yet: give alice a feesher the way the
        // owner will when the drop opens
        vm.prank(DROP.owner());
        DROP.ownerMint(alice, 1);
        assertEq(DROP.liveTotal(), 1);

        // alice buys the tokens she needs and activates — trading has to be on
        vm.prank(OWNER);
        HOOK.openTrading();
        vm.warp(block.timestamp + 301); // past the anti-snipe window
        assertEq(HOOK.feeBps(), 300, "flat 3% after the window");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        ROUTER.swapEthForFeesh{value: 0.02 ether}(0);
        uint256 held = TOKEN.balanceOf(alice);
        console2.log("alice bought    ", held / 1e18, "FEESH");
        assertGt(held, POND.requiredHold(1), "enough to activate");

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        POND.activate(ids);
        assertEq(POND.activeLevel(1), 1, "activated");
        assertEq(POND.tickets(), 10);

        // a trade pays its fee into the pond and queues for its own draw
        uint256 before = address(POND).balance;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        ROUTER.swapEthForFeesh{value: 0.1 ether}(0);
        uint256 fee = address(POND).balance - before;
        console2.log("fee of a 0.1 ETH buy", fee);
        assertEq(fee, 0.003 ether, "3% in ETH");
        // alice's first buy paid a fee too, so there are two trades queued —
        // each gets its own draw, which is the whole point
        assertEq(POND.pending(), 2, "one queue entry per trade");

        // the roller settles it and is kept at its float
        _nextBlock();
        uint256 rollerBefore = ROLLER.balance;
        vm.prank(ROLLER, ROLLER);
        POND.fish();
        assertEq(POND.pending(), 0, "both drawn in one call");
        assertGt(POND.caught(1), 0, "the only feesher caught it");
        console2.log("caught by #1    ", POND.caught(1));
        console2.log("protocol share  ", POND.protocolOwed());
        console2.log("roller delta    ", int256(ROLLER.balance) - int256(rollerBefore));

        // pull into the feesher's wallet, then claim it out
        uint256 booked = POND.caught(1);
        POND.pull(ids);
        assertEq(DROP.walletBalance(1), booked, "in the feesher's wallet");
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        DROP.collect(ids);
        assertEq(alice.balance - aliceBefore, booked, "and in alice's hands");

        // the protocol's sixth is the owner's alone
        vm.prank(OWNER);
        uint256 got = POND.withdrawProtocol();
        console2.log("owner withdrew  ", got);
        assertGt(got, 0);

        // selling works too, against the liquidity that is in the pool
        vm.startPrank(alice);
        TOKEN.approve(address(ROUTER), type(uint256).max);
        uint256 out = ROUTER.swapFeeshForEth(TOKEN.balanceOf(alice) / 2, 0);
        vm.stopPrank();
        console2.log("sold half back for", out, "wei");
        assertGt(out, 0, "the pool bought it back");
    }
}
