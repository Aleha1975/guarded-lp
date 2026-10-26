// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {GuardedLP} from "../src/GuardedLP.sol";
import {MockToken, MockRouter, MockNPM, MockSpoke, MockAccount} from "./Mocks.sol";

contract GuardedLPTest is Test {
    GuardedLP g;
    MockSpoke spoke; address constant HC_USDC = 0x2100000000000000000000000000000000000000; MockToken usdc; MockToken weth; MockRouter router; MockNPM npm; address exe;
    address guardian = address(0xA11CE); address exitKey = address(0xE017); address user = address(0xBEEF); address thief = address(0xBAD);
    uint256 constant U = 1e6; uint256 constant W = 1e18;

    function setUp() public {
        usdc = new MockToken("USDC", 6); weth = new MockToken("WETH", 18);
        router = new MockRouter(); npm = new MockNPM(); exe = router.executor();
        spoke = new MockSpoke();
        g = new GuardedLP(GuardedLP.Venues(address(router), router.executor(), address(npm), address(usdc), address(spoke), 1337, HC_USDC), guardian, exitKey, 24, 5_000 * U, 5_000 * U);
        router.set(1e12, 2000); router.setBase(address(usdc));   // 2000 USDC (6 dec) per WETH (18 dec): buy out = in * 1e12 / 2000, sell the inverse
        vm.prank(exitKey); g.allowToken(address(weth));
        usdc.mint(user, 1_000 * U);
        vm.startPrank(user);
        usdc.approve(address(g), type(uint256).max);
        weth.approve(address(g), type(uint256).max);
        npm.setApprovalForAll(address(g), true);
        vm.stopPrank();
    }

    // ---- helpers
    function route(address tin, address tout, uint256 amount, uint256 minOut, address receiver) internal view returns (bytes memory) {
        GuardedLP.SwapDescriptionV2 memory d;
        d.srcToken = tin; d.dstToken = tout; d.dstReceiver = receiver; d.amount = amount; d.minReturnAmount = minOut;
        GuardedLP.SwapExecutionParams memory p; p.callTarget = exe; p.desc = d;
        return abi.encodeWithSelector(0xe21fd0e9, p);
    }
    function buyRoute(uint256 usdcIn, uint256 minOut) internal view returns (bytes memory) { return route(address(usdc), address(weth), usdcIn, minOut, address(g)); }
    function sellRoute(uint256 wethIn, uint256 minOut) internal view returns (bytes memory) { return route(address(weth), address(usdc), wethIn, minOut, address(g)); }
    function mintSpec(uint256 a0, uint256 a1) internal view returns (GuardedLP.MintSpec memory m) {
        m.token0 = address(weth); m.token1 = address(usdc); m.fee = 500; m.tickLower = -100; m.tickUpper = 100;
        m.amount0Desired = a0; m.amount1Desired = a1;
    }

    // ---- the happy path and the books
    function test_buy_mint_collect_decrease_sell_books() public {
        vm.startPrank(user);
        uint256 out = g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        assertEq(out, 0.1 ether);
        assertEq(weth.balanceOf(user), 0.1 ether);
        (uint256 lt, uint256 lu) = g.lotOf(user, address(weth)); assertEq(lt, 0.1 ether); assertEq(lu, 200 * U);
        assertEq(g.costOf(user), 200 * U);

        (uint256 id,, uint256 a0, uint256 a1) = g.mint(mintSpec(0.1 ether, 200 * U));
        assertEq(npm.ownerOf(id), user);
        assertEq(a0, 0.1 ether); assertEq(a1, 200 * U);
        (lt, lu) = g.lotOf(user, address(weth)); assertEq(lt, 0, "weth left the lot into the pool"); assertEq(lu, 200 * U, "its cost stays");
        assertEq(g.posUsdc(id), 200 * U); assertEq(g.costOf(user), 400 * U);
        assertEq(g.positionsOf(user).length, 1);

        // fees: 0.01 WETH + 30 USDC -> account; USDC income repays the position's cost first
        npm.addFees(id, 0.01 ether, 30 * U);
        (uint256 f0, uint256 f1) = g.collect(id);
        assertEq(f0, 0.01 ether); assertEq(f1, 30 * U);
        assertEq(weth.balanceOf(user), 0.01 ether); assertEq(usdc.balanceOf(user), 600 * U + 30 * U);
        assertEq(g.posUsdc(id), 170 * U); assertEq(g.costOf(user), 370 * U);
        (lt,) = g.lotOf(user, address(weth)); assertEq(lt, 0.01 ether, "fee tokens join the lot");

        // withdraw everything: all held tokens come back; USDC repays the rest of the position's cost, excess cuts WETH cost
        (,,,,,,, uint128 liq,,,,) = npm.positions(id);
        (uint256 d0, uint256 d1) = g.decrease(id, liq, 0, 0);
        assertEq(d0, 0.1 ether); assertEq(d1, 200 * U);
        assertEq(g.posUsdc(id), 0);
        (lt, lu) = g.lotOf(user, address(weth)); assertEq(lt, 0.11 ether); assertEq(lu, 170 * U, "30 USDC of extra income lowered the WETH cost");
        assertEq(g.costOf(user), 170 * U);

        g.burn(id);
        assertEq(g.positionsOf(user).length, 0); assertEq(g.posOwner(id), address(0));

        // sell the whole lot at the same price: 0.11 WETH -> 220 USDC >= cost 170 -> no loss
        out = g.sell(address(weth), 0.11 ether, 1, sellRoute(0.11 ether, 1));
        assertEq(out, 220 * U);
        (uint256 lost,) = g.budgetOf(user); assertEq(lost, 0);
        assertEq(g.costOf(user), 0);
        assertEq(usdc.balanceOf(user), 1_000 * U + 30 * U + 20 * U);
        vm.stopPrank();
    }

    // ---- recipient and route pins
    function test_buy_route_must_pay_gate() public {
        vm.prank(user);
        vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(address(weth), 100 * U, 1, route(address(usdc), address(weth), 100 * U, 1, thief));
    }
    function test_buy_router_misdirecting_output_fails_minout() public {
        router.setPayTo(thief);                                 // a route that pays someone else never delivers to the account
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.BelowMinOut.selector, 0, 1));
        g.buy(address(weth), 100 * U, 1, buyRoute(100 * U, 1));
    }
    function test_route_wrong_executor_or_amount() public {
        GuardedLP.SwapDescriptionV2 memory d; d.srcToken = address(usdc); d.dstToken = address(weth); d.dstReceiver = address(g); d.amount = 100 * U; d.minReturnAmount = 1;
        GuardedLP.SwapExecutionParams memory p; p.callTarget = thief; p.desc = d;
        vm.prank(user); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(address(weth), 100 * U, 1, abi.encodeWithSelector(0xe21fd0e9, p));
        vm.prank(user); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(address(weth), 100 * U, 1, buyRoute(99 * U, 1));
    }
    function test_sale_pays_account_even_if_called_by_executor_delegate() public {
        // the gate pays msg.sender; a delegation redeem runs AS the account, so msg.sender is the account
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        uint256 before = usdc.balanceOf(user);
        g.sell(address(weth), 0.05 ether, 1, sellRoute(0.05 ether, 1));
        assertEq(usdc.balanceOf(user) - before, 100 * U);
        assertEq(usdc.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
        vm.stopPrank();
    }

    // ---- lot and budget
    function test_sell_only_the_lot() public {
        weth.mint(user, 1 ether);                                // the owner's own WETH is not the executor's to sell
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0, 1 ether));
        g.sell(address(weth), 1 ether, 1, sellRoute(1 ether, 1));
    }
    function test_budget_blocks_a_dump_and_exit_key_passes() public {
        vm.startPrank(user);
        g.buy(address(weth), 800 * U, 1, buyRoute(800 * U, 1));   // 0.4 WETH at cost 800; account keeps 200 USDC
        vm.stopPrank();
        router.set(1e12, 500);                                      // price collapses 4x: 0.4 WETH -> 200 USDC
        // base = 800 cost + 200 USDC = 1000; budget 300; loss would be 600
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 600 * U, 300 * U));
        g.sell(address(weth), 0.4 ether, 1, sellRoute(0.4 ether, 1));
        // half of it: loss 300 = budget -> allowed, then nothing more today
        vm.prank(user); g.sell(address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        (uint256 lost, uint256 budget) = g.budgetOf(user); assertEq(lost, 300 * U); assertLt(budget, 300 * U);
        vm.prank(user); vm.expectRevert();
        g.sell(address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        // the cold key evacuates the rest to the account itself
        vm.prank(thief); vm.expectRevert(GuardedLP.NotExitKey.selector);
        g.exitSell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        uint256 before = usdc.balanceOf(user);
        vm.prank(exitKey); g.exitSell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        assertEq(usdc.balanceOf(user) - before, 100 * U);
        // a week later the budget is back
        vm.warp(block.timestamp + 7 days); (lost,) = g.budgetOf(user); assertEq(lost, 0);
    }
    function test_owner_moving_tokens_out_trims_lot_at_cost() public {
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        weth.transfer(thief, 0.05 ether);                            // owner sends half away
        g.sell(address(weth), 0.05 ether, 1, sellRoute(0.05 ether, 1));
        (uint256 lt, uint256 lu) = g.lotOf(user, address(weth)); assertEq(lt, 0); assertEq(lu, 0);
        assertEq(g.costOf(user), 0);
        vm.stopPrank();
    }

    // ---- allowlist
    function test_allowlist_guardian_delay_and_revoke() public {
        MockToken junk = new MockToken("JUNK", 18);
        GuardedLP.MintSpec memory m = mintSpec(0, 100 * U); m.token0 = address(junk);
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotAllowed.selector, address(junk)));
        g.mint(m);
        vm.prank(thief); vm.expectRevert(GuardedLP.NotGuardian.selector); g.allowToken(address(junk));
        vm.prank(guardian); g.allowToken(address(junk));
        assertFalse(g.allowed(address(junk)));
        vm.warp(block.timestamp + 1 days);
        assertTrue(g.allowed(address(junk)));
        vm.prank(guardian); g.revokeToken(address(junk));
        assertFalse(g.allowed(address(junk)));
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotAllowed.selector, address(junk)));
        g.buy(address(junk), 10 * U, 1, route(address(usdc), address(junk), 10 * U, 1, address(g)));
    }

    // ---- pause and keys
    function test_pause_stops_executor_not_the_way_out() public {
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        (uint256 id,,,) = g.mint(mintSpec(0.1 ether, 200 * U));
        vm.stopPrank();
        vm.prank(guardian); g.setPaused(true);
        vm.startPrank(user);
        vm.expectRevert(GuardedLP.IsPaused.selector); g.buy(address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.mint(mintSpec(0, 10 * U));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.sell(address(weth), 1, 1, sellRoute(1, 1));
        npm.addFees(id, 0, 5 * U);
        g.collect(id);                                               // income still comes home
        (,,,,,,, uint128 liq,,,,) = npm.positions(id);
        g.decrease(id, liq, 0, 0);                                   // and so does the liquidity
        vm.stopPrank();
        assertEq(weth.balanceOf(user), 0.1 ether);
    }
    function test_exit_decrease_by_cold_key_only_and_only_tracked_positions() public {
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        (uint256 id,,,) = g.mint(mintSpec(0.1 ether, 200 * U));
        vm.stopPrank();
        vm.prank(thief); vm.expectRevert(GuardedLP.NotExitKey.selector); g.exitDecrease(user, id, 0, 0);
        vm.prank(exitKey); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id)); g.exitDecrease(thief, id, 0, 0);
        vm.prank(exitKey); g.exitDecrease(user, id, 0, 0);
        assertEq(weth.balanceOf(user), 0.1 ether); assertEq(usdc.balanceOf(user), 800 * U);
    }
    function test_increase_after_owner_transferred_nft_is_refused() public {
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        (uint256 id,,,) = g.mint(mintSpec(0.05 ether, 100 * U));
        npm.transferFrom(user, thief, id);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id));
        g.increase(GuardedLP.AddSpec(id, 0, 50 * U, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id));
        g.collect(id);
        vm.stopPrank();
    }

    // ---- limits and leftovers
    function test_ops_rate_limit() public {
        vm.startPrank(user);
        for (uint256 i = 0; i < 24; i++) g.buy(address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.buy(address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.warp(block.timestamp + 1 hours);
        g.buy(address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.stopPrank();
    }
    function test_usdc_in_rate_limit_counts_buys_and_mints() public {
        usdc.mint(user, 10_000 * U);
        vm.startPrank(user);
        g.buy(address(weth), 3_000 * U, 1, buyRoute(3_000 * U, 1));
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.mint(mintSpec(0, 2_001 * U));
        g.mint(mintSpec(0, 2_000 * U));
        vm.stopPrank();
    }
    function test_mint_leftovers_go_back() public {
        npm.setTake(10000, 5000);                                    // the pool takes only half of the USDC offered
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        (uint256 id,, uint256 a0, uint256 a1) = g.mint(mintSpec(0.1 ether, 200 * U));
        assertEq(a0, 0.1 ether); assertEq(a1, 100 * U);
        assertEq(usdc.balanceOf(user), 700 * U, "100 USDC back");
        assertEq(usdc.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
        assertEq(g.posUsdc(id), 100 * U);
        vm.stopPrank();
    }
    function test_sale_route_that_pulls_less_returns_the_rest() public {
        vm.startPrank(user);
        g.buy(address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        router.setPullLess(true);
        g.sell(address(weth), 0.1 ether, 1, sellRoute(0.1 ether, 1));
        assertEq(weth.balanceOf(user), 0.05 ether);
        (uint256 lt, uint256 lu) = g.lotOf(user, address(weth)); assertEq(lt, 0.05 ether); assertEq(lu, 100 * U, "only the sold half of the lot settled its cost");
        vm.stopPrank();
    }
    function test_nothing_sticks_to_the_gate() public {
        vm.startPrank(user);
        g.buy(address(weth), 300 * U, 1, buyRoute(300 * U, 1));
        (uint256 id,,,) = g.mint(mintSpec(0.1 ether, 150 * U));
        npm.addFees(id, 0.001 ether, 1 * U);
        g.collect(id);
        (,,,,,,, uint128 liq,,,,) = npm.positions(id);
        g.decrease(id, liq / 2, 0, 0);
        g.sell(address(weth), 0.05 ether, 1, sellRoute(0.05 ether, 1));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
    }

    // ---- money back to the owner: payout and fundHedge go only to the account's owner()
    function _account(address who) internal returns (MockAccount acc) {
        acc = new MockAccount(who);
        usdc.mint(address(acc), 1_000 * U);
        acc.run(address(usdc), abi.encodeWithSelector(usdc.approve.selector, address(g), type(uint256).max));
    }
    function test_payout_goes_to_owner_only() public {
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        bytes memory r = acc.run(address(g), abi.encodeWithSelector(g.payout.selector, address(usdc), 250 * U)); r;
        assertEq(usdc.balanceOf(wallet), 250 * U, "owner wallet got it");
        assertEq(usdc.balanceOf(address(acc)), 750 * U);
        assertEq(usdc.balanceOf(address(g)), 0, "nothing sticks");
    }
    function test_payout_from_plain_eoa_reverts() public {
        vm.prank(user); vm.expectRevert(GuardedLP.NoBeneficiary.selector);
        g.payout(address(usdc), 1 * U);
    }
    function test_payout_zero_reverts() public {
        MockAccount acc = _account(address(0xB0B));
        vm.expectRevert("account call failed");
        acc.run(address(g), abi.encodeWithSelector(g.payout.selector, address(usdc), 0));
    }
    function test_fundHedge_bridges_to_owner_on_hedge_chain() public {
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        acc.run(address(g), abi.encodeWithSelector(g.fundHedge.selector, uint256(300 * U), GuardedLP.BridgeQuote(299 * U, address(0), uint32(block.timestamp), uint32(block.timestamp + 3600), 0)));
        assertEq(spoke.calls(), 1);
        assertEq(spoke.lastDepositor(), wallet, "refunds go to the owner wallet");
        assertEq(spoke.lastRecipient(), wallet, "lands on the owner's exchange account");
        assertEq(spoke.lastIn(), address(usdc)); assertEq(spoke.lastOut(), HC_USDC); assertEq(spoke.lastChain(), 1337);
        assertEq(spoke.lastInAmt(), 300 * U); assertEq(usdc.balanceOf(address(spoke)), 300 * U);
        assertEq(usdc.balanceOf(address(acc)), 700 * U); assertEq(usdc.balanceOf(address(g)), 0);
        assertEq(usdc.allowance(address(g), address(spoke)), 0, "approval cleared");
    }
    function test_fundHedge_refuses_fee_over_one_percent() public {
        MockAccount acc = _account(address(0xB0B));
        vm.expectRevert("account call failed");   // BridgeFee inside
        acc.run(address(g), abi.encodeWithSelector(g.fundHedge.selector, uint256(300 * U), GuardedLP.BridgeQuote(296 * U, address(0), uint32(block.timestamp), uint32(block.timestamp + 3600), 0)));
    }
    function test_fundHedge_counts_against_usdc_out_limit() public {
        MockAccount acc = _account(address(0xB0B));
        usdc.mint(address(acc), 10_000 * U);
        acc.run(address(g), abi.encodeWithSelector(g.fundHedge.selector, uint256(4_000 * U), GuardedLP.BridgeQuote(3_990 * U, address(0), uint32(block.timestamp), uint32(block.timestamp + 3600), 0)));
        vm.expectRevert("account call failed");   // RateLimited: 4000 + 2000 > 5000 per hour
        acc.run(address(g), abi.encodeWithSelector(g.fundHedge.selector, uint256(2_000 * U), GuardedLP.BridgeQuote(1_995 * U, address(0), uint32(block.timestamp), uint32(block.timestamp + 3600), 0)));
    }
}
