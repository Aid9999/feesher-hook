// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

interface IUR { function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable; }
interface IPermit2 { function approve(address token, address spender, uint160 amount, uint48 expiration) external; }
interface IERC20 { function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IHookOwn { function openTrading() external; function owner() external view returns (address); function feeBps() external view returns (uint256); function feeRecipient() external view returns (address); }
struct QuoteParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }
interface IQuoter {
    function quoteExactInputSingle(QuoteParams memory p) external returns (uint256 amountOut, uint256 gasEstimate);
    function quoteExactOutputSingle(QuoteParams memory p) external returns (uint256 amountIn, uint256 gasEstimate);
}
struct ExactInSingle { PoolKey poolKey; bool zeroForOne; uint128 amountIn; uint128 amountOutMinimum; bytes hookData; }
struct ExactOutSingle { PoolKey poolKey; bool zeroForOne; uint128 amountOut; uint128 amountInMaximum; bytes hookData; }

/// Mainnet fork against the deployed contracts: swaps through Uniswap's own
/// UniversalRouter (+Permit2) and Quoter, with empty hookData.
contract UniswapRouterFork is Test {
    IUR constant UR = IUR(0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99); // current UniversalRouter on 4663
    IQuoter constant QUOTER = IQuoter(0x076838736F90Cd1d30dED756A3B89E576BE972F8);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant HOOK = 0x3d1F46aA87bbCdEcB3afb64Db6a84EAce32204cC;
    address constant TOKEN = 0xbD86E40099E38B4081eDC3CBf56ED201Cd533A9F;
    address trader = address(0xBEEF01);
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC", string("https://rpc.mainnet.chain.robinhood.com")));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 3000, 60, IHooks(HOOK));
        vm.deal(trader, 10 ether);
    }

    function _buyIn(uint128 amt) internal {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInSingle(key, true, amt, 0, ""));
        p[1] = abi.encode(Currency.wrap(address(0)), uint256(amt));
        p[2] = abi.encode(Currency.wrap(TOKEN), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), p);
        vm.prank(trader);
        UR.execute{value: amt}(abi.encodePacked(uint8(0x10)), inputs, vm.getBlockTimestamp() + 60);
    }

    function test_closedThenRouterAndQuoter() public {
        // before openTrading: the router swap reverts
        vm.expectRevert();
        _buyIn(0.001 ether);

        vm.prank(IHookOwn(HOOK).owner());
        IHookOwn(HOOK).openTrading();
        vm.warp(vm.getBlockTimestamp() + 11);
        assertEq(IHookOwn(HOOK).feeBps(), 300);

        // UR exact-in buy matches the quote
        address rcpt = IHookOwn(HOOK).feeRecipient();
        uint256 r0 = rcpt.balance;
        _buyIn(0.01 ether);
        uint256 got = IERC20(TOKEN).balanceOf(trader);
        console2.log("UR buy got FEESHER", got);
        assertGt(got, 0);
        console2.log("fee to recipient (no NFTs minted) wei", rcpt.balance - r0);
        assertEq(rcpt.balance - r0, 0.01 ether * 300 / 10_000);

        // UR exact-in sell via Permit2
        vm.startPrank(trader);
        IERC20(TOKEN).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(TOKEN, address(UR), type(uint160).max, uint48(vm.getBlockTimestamp() + 3600));
        vm.stopPrank();
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInSingle(key, false, uint128(got / 2), 0, ""));
        p[1] = abi.encode(Currency.wrap(TOKEN), got / 2);
        p[2] = abi.encode(Currency.wrap(address(0)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), p);
        uint256 e0 = trader.balance;
        vm.prank(trader);
        UR.execute(abi.encodePacked(uint8(0x10)), inputs, vm.getBlockTimestamp() + 60);
        console2.log("UR sell ETH out", trader.balance - e0);
        assertGt(trader.balance - e0, 0);

        // UR exact-out sell: receive exactly 0.001 ETH
        uint256 qIn = IERC20(TOKEN).balanceOf(trader);
        p[0] = abi.encode(ExactOutSingle(key, false, 0.001 ether, uint128(qIn), ""));
        p[1] = abi.encode(Currency.wrap(TOKEN), qIn);
        p[2] = abi.encode(Currency.wrap(address(0)), uint256(0.001 ether));
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f)), p);
        e0 = trader.balance;
        uint256 f0 = IERC20(TOKEN).balanceOf(trader);
        vm.prank(trader);
        UR.execute(abi.encodePacked(uint8(0x10)), inputs, vm.getBlockTimestamp() + 60);
        console2.log("UR exact-out sell: FEESH in", f0 - IERC20(TOKEN).balanceOf(trader), "");
        assertEq(trader.balance - e0, 0.001 ether);

        // UR exact-out buy: exactly 1000 FEESH, leftover ETH swept back
        uint256 qEth = 0.01 ether;
        p[0] = abi.encode(ExactOutSingle(key, true, 1000e18, uint128(qEth), ""));
        p[1] = abi.encode(Currency.wrap(address(0)), qEth);
        p[2] = abi.encode(Currency.wrap(TOKEN), uint256(1000e18));
        bytes[] memory in2 = new bytes[](2);
        in2[0] = abi.encode(abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f)), p);
        in2[1] = abi.encode(address(0), trader, uint256(0));
        f0 = IERC20(TOKEN).balanceOf(trader);
        e0 = trader.balance;
        vm.prank(trader);
        UR.execute{value: qEth}(abi.encodePacked(uint8(0x10), uint8(0x04)), in2, vm.getBlockTimestamp() + 60);
        console2.log("UR exact-out buy: ETH in", e0 - trader.balance, "");
        assertEq(IERC20(TOKEN).balanceOf(trader) - f0, 1000e18);
    }
}
