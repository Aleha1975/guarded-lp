// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {GuardedLP} from "../src/GuardedLP.sol";

interface IERC20C { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); function allowance(address, address) external view returns (uint256); }

/// Real Base TokenMessengerV2 (latest block): fundHedge must make the real contract emit DepositForBurn with
/// destinationDomain 19, mintRecipient = Forwarder and our 56-byte hookData.
/// Run: BASE_RPC=https://base-rpc.publicnode.com forge test --match-contract ForkCctp
contract ForkCctpTest is Test {
    address constant TM = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant FWD = 0xb21D281DEdb17AE5B501F6AA8256fe38C4e45757;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant EXECUTOR = 0x8F10B468b06c6FD214B65F87778827F7D113f996;
    bytes32 constant TOPIC = keccak256("DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)");
    address op = address(0x0907); address user = address(0xBEEF);
    GuardedLP g;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC not set");
        vm.createSelectFork(rpc);
        g = new GuardedLP(GuardedLP.Venues(ROUTER, EXECUTOR, NPM, FACTORY, USDC, TM, FWD), address(0xA11CE), address(0xE017), 24, 5_000e6, 5_000e6);
        deal(USDC, user, 100e6);
        vm.startPrank(user);
        IERC20C(USDC).approve(address(g), type(uint256).max);
        g.authorize(op, 1_000e6);
        vm.stopPrank();
    }

    function _run(bool fast, bool toSpot, uint32 finality, uint32 dex) internal {
        uint256 maxFee = fast ? 0.3e6 : 0.26e6;
        vm.recordLogs();
        vm.prank(op); g.fundHedge(user, 20e6, maxFee, fast, toSpot);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != TM || logs[i].topics[0] != TOPIC) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USDC, "burnToken");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(g), "depositor is the gate");
            assertEq(uint32(uint256(logs[i].topics[3])), finality, "minFinalityThreshold");
            (uint256 amount, bytes32 mintRecipient, uint32 domain, , bytes32 caller, uint256 mf, bytes memory hook) =
                abi.decode(logs[i].data, (uint256, bytes32, uint32, bytes32, bytes32, uint256, bytes));
            assertEq(amount, 20e6); assertEq(domain, 19);
            assertEq(mintRecipient, bytes32(uint256(uint160(FWD)))); assertEq(caller, bytes32(uint256(uint160(FWD))));
            assertEq(mf, maxFee);
            assertEq(hook.length, 56);
            assertEq(hook, bytes.concat(bytes24("cctp-forward"), bytes4(0), bytes4(uint32(24)), bytes20(user), bytes4(dex)));
        }
        assertTrue(found, "DepositForBurn not emitted by the real TokenMessengerV2");
        assertEq(IERC20C(USDC).allowance(address(g), TM), 0, "approval cleared");
    }
    function test_real_tokenmessenger_perps_fast() public { _run(true, false, 1000, 0); }
    function test_real_tokenmessenger_spot_standard() public { _run(false, true, 2000, type(uint32).max); }
}
