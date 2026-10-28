// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {GuardedLP, INPM} from "../src/GuardedLP.sol";
import {MockToken, MockRouter, MockNPM, MockSpoke, MockAccount, MockFactory, MockPool} from "./Mocks.sol";

contract GuardedLPTest is Test {
    GuardedLP g;
    MockSpoke spoke; address constant HC_USDC = 0x2100000000000000000000000000000000000000;
    MockToken usdc; MockToken weth; MockRouter router; MockNPM npm; MockFactory factory; MockPool pool; address exe;
    address guardian = address(0xA11CE); address exitKey = address(0xE017); address user = address(0xBEEF); address thief = address(0xBAD);
    address op = address(0x0907);
    uint256 constant U = 1e6; uint256 constant W = 1e18;
    uint256 constant CAP = 100_000 * 1e6;

    function _deploy(uint8 hedgeDecimals) internal returns (GuardedLP) {
        return new GuardedLP(GuardedLP.Venues(address(router), router.executor(), address(npm), address(factory), address(usdc), address(spoke), 1337, HC_USDC, hedgeDecimals),
            guardian, exitKey, 24, 5_000 * U, 5_000 * U);
    }

    function setUp() public {
        usdc = new MockToken("USDC", 6); weth = new MockToken("WETH", 18);
        router = new MockRouter(); npm = new MockNPM(); exe = router.executor();
        spoke = new MockSpoke(); factory = new MockFactory(); pool = new MockPool();
        factory.setPool(address(weth), address(usdc), 500, address(pool));
        g = _deploy(6);
        router.set(1e12, 2000); router.setBase(address(usdc));   // 2000 USDC (6 dec) per WETH (18 dec): buy out = in * 1e12 / 2000, sell the inverse
        vm.prank(exitKey); g.allowToken(address(weth));
        usdc.mint(user, 1_000 * U);
        vm.startPrank(user);
        usdc.approve(address(g), type(uint256).max);
        weth.approve(address(g), type(uint256).max);
        npm.setApprovalForAll(address(g), true);
        g.authorize(op, CAP);
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
    function _buy(uint256 usdcIn) internal returns (uint256 out) { vm.prank(op); out = g.buy(user, address(weth), usdcIn, 1, buyRoute(usdcIn, 1)); }
    function _sell(uint256 amt) internal returns (uint256 out) { vm.prank(op); out = g.sell(user, address(weth), amt, 1, sellRoute(amt, 1)); }
    function _mint(uint256 a0, uint256 a1) internal returns (uint256 id) { vm.prank(op); (id,,,) = g.mint(user, mintSpec(a0, a1)); }
    function _liq(uint256 id) internal view returns (uint128 liq) { (,,,,,,, liq,,,,) = npm.positions(id); }
    function _decreaseAll(uint256 id) internal returns (uint256 d0, uint256 d1) { uint128 l = _liq(id); vm.prank(op); (d0, d1) = g.decrease(user, id, l, 0, 0); }
    function _lot(address a) internal view returns (uint256 t, uint256 c) { return g.lotOf(a, address(weth)); }
    function _lost() internal view returns (uint256 l) { (l,) = g.budgetOf(user); }

    // ================================================================ v1 behaviours, ported
    function test_buy_mint_collect_decrease_sell_books() public {
        uint256 out = _buy(200 * U);
        assertEq(out, 0.1 ether);
        assertEq(weth.balanceOf(user), 0.1 ether);
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0.1 ether); assertEq(lu, 200 * U);
        assertEq(g.costOf(user), 200 * U);

        vm.prank(op); (uint256 id,, uint256 a0, uint256 a1) = g.mint(user, mintSpec(0.1 ether, 200 * U));
        assertEq(npm.ownerOf(id), user);
        assertEq(a0, 0.1 ether); assertEq(a1, 200 * U);
        (lt, lu) = _lot(user); assertEq(lt, 0, "weth left the lot into the pool"); assertEq(lu, 0, "its cost moved onto the position");
        assertEq(g.posCost(id), 400 * U, "200 USDC + the weth cost share"); assertEq(g.costOf(user), 400 * U);
        assertEq(g.positionsOf(user).length, 1);

        // fees: 0.01 WETH + 30 USDC -> wallet; fees join at zero cost, the position's cost is untouched
        npm.addFees(id, 0.01 ether, 30 * U);
        vm.prank(op); (uint256 f0, uint256 f1) = g.collect(user, id);
        assertEq(f0, 0.01 ether); assertEq(f1, 30 * U);
        assertEq(weth.balanceOf(user), 0.01 ether); assertEq(usdc.balanceOf(user), 600 * U + 30 * U);
        assertEq(g.posCost(id), 400 * U); assertEq(g.costOf(user), 400 * U);
        (lt, lu) = _lot(user); assertEq(lt, 0.01 ether, "fee tokens join the lot"); assertEq(lu, 0, "at zero cost");

        (uint256 d0, uint256 d1) = _decreaseAll(id);
        assertEq(d0, 0.1 ether); assertEq(d1, 200 * U);
        assertEq(g.posCost(id), 0);
        (lt, lu) = _lot(user); assertEq(lt, 0.11 ether); assertEq(lu, 200 * U, "USDC repaid 200 of 400, the rest rides on the returned WETH");
        assertEq(g.costOf(user), 200 * U);

        vm.prank(op); g.burn(user, id);
        assertEq(g.positionsOf(user).length, 0); assertEq(g.posOwner(id), address(0));
        assertEq(_lost(), 0);

        out = _sell(0.11 ether);
        assertEq(out, 220 * U);
        assertEq(_lost(), 0);
        assertEq(g.costOf(user), 0);
        assertEq(usdc.balanceOf(user), 1_000 * U + 30 * U + 20 * U);
    }

    function test_buy_route_must_pay_gate() public {
        vm.prank(op);
        vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(user, address(weth), 100 * U, 1, route(address(usdc), address(weth), 100 * U, 1, thief));
    }
    function test_buy_router_misdirecting_output_fails_minout() public {
        router.setPayTo(thief);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.BelowMinOut.selector, 0, 1));
        g.buy(user, address(weth), 100 * U, 1, buyRoute(100 * U, 1));
    }
    function test_route_wrong_executor_or_amount() public {
        GuardedLP.SwapDescriptionV2 memory d; d.srcToken = address(usdc); d.dstToken = address(weth); d.dstReceiver = address(g); d.amount = 100 * U; d.minReturnAmount = 1;
        GuardedLP.SwapExecutionParams memory p; p.callTarget = thief; p.desc = d;
        vm.prank(op); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(user, address(weth), 100 * U, 1, abi.encodeWithSelector(0xe21fd0e9, p));
        vm.prank(op); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(user, address(weth), 100 * U, 1, buyRoute(99 * U, 1));
    }
    function test_sale_pays_the_account() public {
        _buy(200 * U);
        uint256 before = usdc.balanceOf(user);
        _sell(0.05 ether);
        assertEq(usdc.balanceOf(user) - before, 100 * U);
        assertEq(usdc.balanceOf(op), 0, "the operator never receives money");
        assertEq(usdc.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
    }
    function test_sell_only_the_lot() public {
        weth.mint(user, 1 ether);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0, 1 ether));
        g.sell(user, address(weth), 1 ether, 1, sellRoute(1 ether, 1));
    }
    function test_budget_blocks_a_dump_and_exit_key_passes() public {
        _buy(800 * U);                                              // 0.4 WETH at cost 800; wallet keeps 200 USDC
        router.set(1e12, 500);                                      // price collapses 4x: 0.4 WETH -> 200 USDC
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 600 * U, 300 * U));
        g.sell(user, address(weth), 0.4 ether, 1, sellRoute(0.4 ether, 1));
        _sell(0.2 ether);
        (uint256 lost, uint256 budget) = g.budgetOf(user); assertEq(lost, 300 * U); assertLt(budget, 300 * U);
        vm.prank(op); vm.expectRevert();
        g.sell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        vm.prank(thief); vm.expectRevert(GuardedLP.NotExitKey.selector);
        g.exitSell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        uint256 before = usdc.balanceOf(user);
        vm.prank(exitKey); g.exitSell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        assertEq(usdc.balanceOf(user) - before, 100 * U);
        vm.warp(block.timestamp + 7 days); (lost,) = g.budgetOf(user); assertEq(lost, 0);
    }
    function test_unlock_by_exit_key_clears_the_budget() public {
        _buy(800 * U); router.set(1e12, 500); _sell(0.2 ether);
        assertGt(_lost(), 0);
        address[] memory a = new address[](1); a[0] = user;
        vm.prank(op); vm.expectRevert(GuardedLP.NotExitKey.selector); g.unlock(a);
        vm.prank(exitKey); g.unlock(a);
        assertEq(_lost(), 0);
    }
    function test_owner_moving_tokens_out_trims_lot_at_cost() public {
        _buy(200 * U);
        vm.prank(user); weth.transfer(thief, 0.05 ether);
        _sell(0.05 ether);
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0); assertEq(lu, 0);
        assertEq(g.costOf(user), 0);
    }

    function test_allowlist_guardian_delay_and_revoke() public {
        MockToken junk = new MockToken("JUNK", 18);
        GuardedLP.MintSpec memory m = mintSpec(0, 100 * U); m.token0 = address(junk);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotAllowed.selector, address(junk)));
        g.mint(user, m);
        vm.prank(thief); vm.expectRevert(GuardedLP.NotGuardian.selector); g.allowToken(address(junk));
        vm.prank(guardian); g.allowToken(address(junk));
        assertFalse(g.allowed(address(junk)));
        vm.warp(block.timestamp + 1 days);
        assertTrue(g.allowed(address(junk)));
        vm.prank(guardian); g.revokeToken(address(junk));
        assertFalse(g.allowed(address(junk)));
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotAllowed.selector, address(junk)));
        g.buy(user, address(junk), 10 * U, 1, route(address(usdc), address(junk), 10 * U, 1, address(g)));
    }

    function test_pause_stops_executor_not_the_way_out() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(guardian); g.setPaused(true);
        vm.startPrank(op);
        vm.expectRevert(GuardedLP.IsPaused.selector); g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.mint(user, mintSpec(0, 10 * U));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.sell(user, address(weth), 1, 1, sellRoute(1, 1));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.increase(user, GuardedLP.AddSpec(id, 0, 10 * U, 0, 0));
        npm.addFees(id, 0, 5 * U);
        g.collect(user, id);
        uint128 liq = _liq(id);
        g.decrease(user, id, liq, 0, 0);
        vm.stopPrank();
        assertEq(weth.balanceOf(user), 0.1 ether);
    }
    function test_pause_window_and_cooldown() public {
        vm.prank(guardian); g.setPaused(true);
        assertTrue(g.paused());
        vm.warp(block.timestamp + 7 days); assertFalse(g.paused());
        vm.prank(guardian); vm.expectRevert(GuardedLP.PauseCooldown.selector); g.setPaused(true);
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian); g.setPaused(true); assertTrue(g.paused());
    }
    function test_guardian_replace_and_propose() public {
        vm.prank(guardian); g.proposeGuardian(thief);
        vm.prank(thief); g.acceptGuardian(); assertEq(g.guardian(), thief);
        vm.prank(exitKey); g.replaceGuardian(guardian); assertEq(g.guardian(), guardian);
        vm.prank(thief); vm.expectRevert(GuardedLP.NotExitKey.selector); g.replaceGuardian(thief);
    }
    function test_exit_decrease_by_cold_key_only_and_only_tracked_positions() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(thief); vm.expectRevert(GuardedLP.NotExitKey.selector); g.exitDecrease(user, id, 0, 0);
        vm.prank(exitKey); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id)); g.exitDecrease(thief, id, 0, 0);
        vm.prank(exitKey); g.exitDecrease(user, id, 0, 0);
        assertEq(weth.balanceOf(user), 0.1 ether); assertEq(usdc.balanceOf(user), 800 * U);
    }
    function test_increase_after_owner_transferred_nft_is_refused() public {
        _buy(200 * U);
        uint256 id = _mint(0.05 ether, 100 * U);
        vm.prank(user); npm.transferFrom(user, thief, id);
        vm.startPrank(op);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id));
        g.increase(user, GuardedLP.AddSpec(id, 0, 50 * U, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id));
        g.collect(user, id);
        vm.stopPrank();
    }
    function test_increase_adds_cost_and_lot_share() public {
        _buy(200 * U);
        uint256 id = _mint(0.05 ether, 100 * U);                 // posCost 100 + 100
        assertEq(g.posCost(id), 200 * U);
        vm.prank(op); g.increase(user, GuardedLP.AddSpec(id, 0.05 ether, 100 * U, 0, 0));
        assertEq(g.posCost(id), 400 * U); assertEq(g.costOf(user), 400 * U);
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0); assertEq(lu, 0);
    }

    function test_ops_rate_limit() public {
        vm.startPrank(op);
        for (uint256 i = 0; i < 24; i++) g.buy(user, address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.buy(user, address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.warp(block.timestamp + 1 hours);
        g.buy(user, address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.stopPrank();
    }
    function test_usdc_in_rate_limit_counts_buys_and_mints() public {
        usdc.mint(user, 10_000 * U);
        _buy(3_000 * U);
        vm.startPrank(op);
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.mint(user, mintSpec(0, 2_001 * U));
        g.mint(user, mintSpec(0, 2_000 * U));
        vm.stopPrank();
    }
    function test_mint_leftovers_go_back() public {
        npm.setTake(10000, 5000);
        _buy(200 * U);
        vm.prank(op); (uint256 id,, uint256 a0, uint256 a1) = g.mint(user, mintSpec(0.1 ether, 200 * U));
        assertEq(a0, 0.1 ether); assertEq(a1, 100 * U);
        assertEq(usdc.balanceOf(user), 700 * U, "100 USDC back");
        assertEq(usdc.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
        assertEq(g.posCost(id), 300 * U, "100 USDC + the 200 weth cost");
    }
    function test_mint_leftover_tokens_stay_in_lot_with_their_cost() public {
        npm.setTake(5000, 10000);                                  // the pool takes only half of the WETH offered
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        assertEq(weth.balanceOf(user), 0.05 ether);
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0.05 ether); assertEq(lu, 100 * U);
        assertEq(g.posCost(id), 300 * U); assertEq(g.costOf(user), 400 * U);
    }
    function test_sale_route_that_pulls_less_returns_the_rest() public {
        _buy(200 * U);
        router.setPullLess(true);
        _sell(0.1 ether);
        assertEq(weth.balanceOf(user), 0.05 ether);
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0.05 ether); assertEq(lu, 100 * U, "only the sold half of the lot settled its cost");
    }
    function test_nothing_sticks_to_the_gate() public {
        _buy(300 * U);
        uint256 id = _mint(0.1 ether, 150 * U);
        npm.addFees(id, 0.001 ether, 1 * U);
        vm.startPrank(op);
        g.collect(user, id);
        g.decrease(user, id, _liq(id) / 2, 0, 0);
        g.sell(user, address(weth), 0.05 ether, 1, sellRoute(0.05 ether, 1));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(g)), 0); assertEq(weth.balanceOf(address(g)), 0);
    }
    function test_partial_decrease_splits_cost_pro_rata() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);                   // posCost 400
        uint128 l = _liq(id);
        vm.prank(op); g.decrease(user, id, l / 2, 0, 0);
        assertEq(g.posCost(id), 200 * U);
        assertEq(g.costOf(user), 300 * U, "100 USDC repaid; 100 rides on 0.05 WETH");
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0.05 ether); assertEq(lu, 100 * U);
    }

    // ================================================================ money back to the owner
    function _account(address who) internal returns (MockAccount acc) {
        acc = new MockAccount(who);
        usdc.mint(address(acc), 1_000 * U);
        acc.run(address(usdc), abi.encodeWithSelector(usdc.approve.selector, address(g), type(uint256).max));
        acc.run(address(g), abi.encodeWithSelector(g.authorize.selector, op, CAP));
    }
    function _quote(uint256 out) internal view returns (GuardedLP.BridgeQuote memory) { return GuardedLP.BridgeQuote(out, address(0), uint32(block.timestamp), uint32(block.timestamp + 3600), 0); }

    function test_payout_goes_to_owner_only() public {
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        vm.prank(op); g.payout(address(acc), address(usdc), 250 * U);
        assertEq(usdc.balanceOf(wallet), 250 * U, "owner wallet got it");
        assertEq(usdc.balanceOf(address(acc)), 750 * U);
        assertEq(usdc.balanceOf(address(g)), 0, "nothing sticks");
    }
    function test_payout_from_plain_eoa_reverts() public {
        vm.prank(op); vm.expectRevert(GuardedLP.NoBeneficiary.selector);
        g.payout(user, address(usdc), 1 * U);
        vm.prank(user); vm.expectRevert(GuardedLP.NoBeneficiary.selector);
        g.payout(user, address(usdc), 1 * U);
    }
    function test_payout_zero_reverts() public {
        MockAccount acc = _account(address(0xB0B));
        vm.prank(op); vm.expectRevert(GuardedLP.ZeroAmount.selector);
        g.payout(address(acc), address(usdc), 0);
    }
    function test_payout_by_stranger_reverts() public {
        MockAccount acc = _account(address(0xB0B));
        vm.prank(thief); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.payout(address(acc), address(usdc), 1 * U);
    }
    function test_payout_refused_when_owner_is_the_account() public {
        MockAccount self = new MockAccount(address(0xB0B));
        // an account whose owner() returns itself: etch an owner-self account
        address a = address(0xA55);
        vm.etch(a, address(self).code);
        vm.store(a, bytes32(0), bytes32(uint256(uint160(a))));
        assertEq(MockAccount(a).owner(), a);
        vm.prank(a); g.authorize(op, CAP);
        vm.prank(op); vm.expectRevert(GuardedLP.NoBeneficiary.selector);
        g.payout(a, address(usdc), 1 * U);
    }
    function test_fundHedge_bridges_to_owner_on_hedge_chain() public {
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        vm.prank(op); g.fundHedge(address(acc), 300 * U, _quote(299 * U));
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
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc), 300 * U, _quote(296 * U));
    }
    function test_fundHedge_counts_against_usdc_out_limit() public {
        MockAccount acc = _account(address(0xB0B));
        usdc.mint(address(acc), 10_000 * U);
        vm.startPrank(op);
        g.fundHedge(address(acc), 4_000 * U, _quote(3_990 * U));
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.fundHedge(address(acc), 2_000 * U, _quote(1_995 * U));
        vm.stopPrank();
    }

    // ================================================================ audit 1057 regressions
    // ---- H-1: price check, young pools, lot bound
    function test_H1_mint_at_manipulated_price_reverts_PriceOff() public {
        _buy(200 * U);
        pool.setSpot(400);                                           // twap 0, spot 400 ticks away (> 150)
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(400), int24(0)));
        g.mint(user, mintSpec(0.1 ether, 200 * U));
        pool.setSpot(-400);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(-400), int24(0)));
        g.mint(user, mintSpec(0.1 ether, 200 * U));
        pool.setSpot(150);                                           // exactly at the bound: allowed
        _mint(0.1 ether, 200 * U);
    }
    function test_H1_mint_with_negative_twap_rounds_down() public {
        _buy(200 * U);
        pool.setTwap(-1000); pool.setSpot(-1000);
        _mint(0.1 ether, 100 * U);
        pool.setSpot(-1000 + 151);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(-849), int24(-1000)));
        g.mint(user, mintSpec(0.05 ether, 50 * U));
    }
    function test_H1_mint_into_young_pool_reverts() public {
        _buy(200 * U);
        pool.setYoung(true);
        vm.prank(op); vm.expectRevert(bytes("OLD"));
        g.mint(user, mintSpec(0.1 ether, 200 * U));
    }
    function test_H1_mint_in_missing_pool_reverts_BadPool() public {
        _buy(200 * U);
        GuardedLP.MintSpec memory m = mintSpec(0.1 ether, 200 * U); m.fee = 3000;
        vm.prank(op); vm.expectRevert(GuardedLP.BadPool.selector);
        g.mint(user, m);
    }
    function test_H1_increase_at_manipulated_price_or_young_pool_reverts() public {
        _buy(200 * U);
        uint256 id = _mint(0.05 ether, 100 * U);
        pool.setSpot(500);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(500), int24(0)));
        g.increase(user, GuardedLP.AddSpec(id, 0, 50 * U, 0, 0));
        pool.setSpot(0); pool.setYoung(true);
        vm.prank(op); vm.expectRevert(bytes("OLD"));
        g.increase(user, GuardedLP.AddSpec(id, 0, 50 * U, 0, 0));
    }
    function test_H1_mint_non_usdc_leg_larger_than_lot_reverts_NotInLot() public {
        _buy(200 * U);                                               // lot 0.1 WETH
        weth.mint(user, 5 ether);                                    // the wallet holds much more outside the lot
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0.1 ether, 0.5 ether));
        g.mint(user, mintSpec(0.5 ether, 200 * U));
    }
    function test_H1_decrease_at_manipulated_price_reverts_but_exitDecrease_works() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        pool.setSpot(900);
        uint128 l = _liq(id);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(900), int24(0)));
        g.decrease(user, id, l, 0, 0);
        pool.setYoung(true);                                          // even with an unanswerable window the cold key gets out
        vm.prank(exitKey); g.exitDecrease(user, id, 0, 0);
        assertEq(weth.balanceOf(user), 0.1 ether); assertEq(usdc.balanceOf(user), 800 * U);
        assertEq(g.posCost(id), 0);
    }
    function test_H1_collect_only_decrease_skips_price_check() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        npm.addFees(id, 0, 7 * U);
        pool.setSpot(900);
        vm.prank(op); (, uint256 a1) = g.decrease(user, id, 0, 0, 0);   // liquidity 0: only collects, nothing moves price
        assertEq(a1, 7 * U);
    }

    // ---- H-2: only the lot can enter positions or be sold
    function test_H2_tokens_outside_the_lot_cannot_enter_a_position() public {
        weth.mint(user, 3 ether);                                    // outside holdings, no lot at all
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0, 1 ether));
        g.mint(user, mintSpec(1 ether, 100 * U));
        _buy(20 * U);                                                // lot 0.01 WETH, wallet holds 3.01
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0.01 ether, 1 ether));
        g.mint(user, mintSpec(1 ether, 100 * U));
        uint256 id = _mint(0.01 ether, 100 * U);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0, 1 ether));
        g.increase(user, GuardedLP.AddSpec(id, 1 ether, 0, 0, 0));
    }
    function test_H2_outside_tokens_cannot_be_laundered_into_the_lot_and_sold_outside_the_budget() public {
        weth.mint(user, 3 ether);                                    // 3 WETH outside the lot
        _buy(20 * U);                                                // lot is only what the gate bought: 0.01
        (uint256 lt,) = _lot(user); assertEq(lt, 0.01 ether, "a buy credits the delta, not the balance");
        // a position round trip returns only what went in, plus fees
        uint256 id = _mint(0.01 ether, 100 * U);
        uint128 l = _liq(id);
        vm.prank(op); g.decrease(user, id, l, 0, 0);
        (lt,) = _lot(user); assertEq(lt, 0.01 ether, "only the principal came back to the lot");
        // selling more than the lot is refused, however much the wallet holds
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotInLot.selector, 0.01 ether, 3 ether));
        g.sell(user, address(weth), 3 ether, 1, sellRoute(3 ether, 1));
        // nor can a lot-sized sale carry the outside tokens: the route's amount is pinned
        vm.prank(op); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.sell(user, address(weth), 0.01 ether, 1, sellRoute(3 ether, 1));
        // a position the wallet opened itself (untracked) cannot be pulled into the books either
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, 999));
        g.decrease(user, 999, 1, 0, 0);
        assertEq(weth.balanceOf(user), 3.01 ether);
    }
    function test_H2_untracked_nft_cannot_be_adopted() public {
        // an NFT the wallet minted directly on the NPM: the gate has no record, so nothing can move or credit it
        vm.startPrank(user);
        npm.setApprovalForAll(address(g), true);
        weth.mint(user, 1 ether); weth.approve(address(npm), type(uint256).max); usdc.approve(address(npm), type(uint256).max);
        (uint256 id,,,) = npm.mint(_npmParams(1 ether, 100 * U));
        vm.stopPrank();
        vm.startPrank(op);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id)); g.decrease(user, id, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id)); g.increase(user, GuardedLP.AddSpec(id, 1, 1, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id)); g.collect(user, id);
        vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, id)); g.burn(user, id);
        vm.stopPrank();
    }
    function _npmParams(uint256 a0, uint256 a1) internal view returns (INPM.MintParams memory) { return INPM.MintParams(address(weth), address(usdc), 500, -100, 100, a0, a1, 0, 0, user, block.timestamp); }

    // ---- M-1: cost follows the tokens, losses are booked
    function test_M1_position_returning_less_usdc_and_no_tokens_books_a_loss() public {
        vm.prank(op); (uint256 id,,,) = g.mint(user, mintSpec(0, 200 * U));      // USDC-only position, cost 200
        assertEq(g.posCost(id), 200 * U); assertEq(g.costOf(user), 200 * U);
        npm.setHeld(id, 0, 120 * U);                                              // the pool returns only 120
        (uint256 d0, uint256 d1) = _decreaseAll(id);
        assertEq(d0, 0); assertEq(d1, 120 * U);
        assertEq(g.costOf(user), 0, "no inflated cost left behind");
        assertEq(_lost(), 80 * U, "80 USDC booked as loss");
        assertEq(g.posCost(id), 0);
    }
    function test_M1_loss_in_usdc_with_tokens_back_rides_on_the_tokens() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);                                  // posCost 400
        npm.setHeld(id, 0.2 ether, 100 * U);                                     // price moved: more WETH, less USDC
        _decreaseAll(id);
        (uint256 lt, uint256 lu) = _lot(user); assertEq(lt, 0.2 ether); assertEq(lu, 300 * U, "100 USDC repaid, 300 rides on the WETH");
        assertEq(g.costOf(user), 300 * U);
        assertEq(_lost(), 0, "booked only when the WETH is sold");
        router.set(1e12, 1000);                                                   // WETH now 1000: 0.2 -> 200 USDC, cost 300
        _sell(0.2 ether);
        assertEq(_lost(), 100 * U); assertEq(g.costOf(user), 0);
    }
    function test_M1_burn_with_leftover_cost_books_a_loss() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);                                  // posCost 400
        // the wallet takes the liquidity out by itself, outside the gate
        uint128 l = _liq(id);
        vm.startPrank(user);
        npm.decreaseLiquidity(_dec(id, l));
        npm.collect(INPM.CollectParams(id, user, type(uint128).max, type(uint128).max));
        vm.stopPrank();
        assertEq(g.posCost(id), 400 * U);
        vm.prank(op); g.burn(user, id);
        assertEq(g.posCost(id), 0);
        assertEq(g.costOf(user), 0, "costOf never stays inflated after burn");
        assertEq(_lost(), 400 * U);
        assertEq(g.positionsOf(user).length, 0);
    }
    function test_M1_forget_with_leftover_cost_books_a_loss() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(user); npm.transferFrom(user, thief, id);
        vm.prank(user); g.forget(user, id);                                       // the wallet itself may forget
        assertEq(g.costOf(user), 0); assertEq(_lost(), 400 * U); assertEq(g.posOwner(id), address(0));
    }
    function test_M1_clean_burn_books_nothing() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        _decreaseAll(id);
        vm.prank(op); g.burn(user, id);
        assertEq(_lost(), 0);
        assertEq(g.costOf(user), 200 * U, "the cost now rides on the WETH in the lot");
    }

    // ---- M-2
    function test_M2_non_usdc_pair_reverts_NotUsdcPair() public {
        MockToken dai = new MockToken("DAI", 18);
        vm.prank(exitKey); g.allowToken(address(dai));
        GuardedLP.MintSpec memory m = mintSpec(0.1 ether, 0); m.token1 = address(dai);
        vm.prank(op); vm.expectRevert(GuardedLP.NotUsdcPair.selector);
        g.mint(user, m);
        m.token0 = address(dai); m.token1 = address(weth);
        vm.prank(op); vm.expectRevert(GuardedLP.NotUsdcPair.selector);
        g.mint(user, m);
    }

    // ---- L-1
    function test_L1_fundHedge_reverts_while_paused() public {
        MockAccount acc = _account(address(0xB0B));
        vm.prank(guardian); g.setPaused(true);
        vm.prank(op); vm.expectRevert(GuardedLP.IsPaused.selector);
        g.fundHedge(address(acc), 100 * U, _quote(100 * U));
        vm.prank(address(acc)); vm.expectRevert(GuardedLP.IsPaused.selector);
        g.fundHedge(address(acc), 100 * U, _quote(100 * U));
        vm.prank(op); g.payout(address(acc), address(usdc), 10 * U);              // the way out stays open
    }
    function test_L1_fee_bound_with_hedge_decimals_6_and_8() public {
        GuardedLP g8 = _deploy(8);
        MockAccount acc = new MockAccount(address(0xB0B));
        usdc.mint(address(acc), 1_000 * U);
        acc.run(address(usdc), abi.encodeWithSelector(usdc.approve.selector, address(g8), type(uint256).max));
        acc.run(address(g8), abi.encodeWithSelector(g8.authorize.selector, op, CAP));
        // 8 decimals: 299 USDC = 299e8; 296e8 is a 1.33% fee
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g8.fundHedge(address(acc), 300 * U, _quote(296e8));
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g8.fundHedge(address(acc), 300 * U, _quote(299 * U));                     // a 6-decimals quote read as 8 is far below the bound
        vm.prank(op); g8.fundHedge(address(acc), 300 * U, _quote(299e8));
        assertEq(spoke.lastOutAmt(), 299e8);
        // 6 decimals on the main gate
        MockAccount acc6 = _account(address(0xB0B));
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc6), 300 * U, _quote(296 * U));
        vm.prank(op); g.fundHedge(address(acc6), 300 * U, _quote(297 * U));       // exactly 1%: allowed
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc6), 300 * U, _quote(297 * U - 1));
    }
    function test_L1_fee_bound_with_18_and_below_6_decimals() public {
        GuardedLP g18 = _deploy(18);
        MockAccount acc = new MockAccount(address(0xB0B));
        usdc.mint(address(acc), 1_000 * U);
        acc.run(address(usdc), abi.encodeWithSelector(usdc.approve.selector, address(g18), type(uint256).max));
        acc.run(address(g18), abi.encodeWithSelector(g18.authorize.selector, op, CAP));
        vm.prank(op); g18.fundHedge(address(acc), 300 * U, _quote(299 ether));
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g18.fundHedge(address(acc), 300 * U, _quote(296 ether));
        GuardedLP g2 = _deploy(2);
        acc.run(address(usdc), abi.encodeWithSelector(usdc.approve.selector, address(g2), type(uint256).max));
        acc.run(address(g2), abi.encodeWithSelector(g2.authorize.selector, op, CAP));
        vm.prank(op); g2.fundHedge(address(acc), 300 * U, _quote(299 * 100));
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g2.fundHedge(address(acc), 300 * U, _quote(296 * 100));
    }

    // ---- L-2
    function test_L2_forget_by_exit_key_after_the_nft_moved_away() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(user); npm.transferFrom(user, thief, id);
        vm.prank(exitKey); g.forget(user, id);
        assertEq(g.positionsOf(user).length, 0); assertEq(g.posOwner(id), address(0));
        assertEq(g.posCost(id), 0); assertEq(g.costOf(user), 0);
        assertEq(_lost(), 400 * U);
    }
    function test_L2_forget_reverts_StillOwned_while_the_wallet_holds_the_nft() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(exitKey); vm.expectRevert(abi.encodeWithSelector(GuardedLP.StillOwned.selector, id));
        g.forget(user, id);
        vm.prank(user); vm.expectRevert(abi.encodeWithSelector(GuardedLP.StillOwned.selector, id));
        g.forget(user, id);
        assertEq(g.positionsOf(user).length, 1);
    }
    function test_L2_forget_access_and_untracked() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(user); npm.transferFrom(user, thief, id);
        vm.prank(op); vm.expectRevert(GuardedLP.NotOperator.selector); g.forget(user, id);
        vm.prank(thief); vm.expectRevert(GuardedLP.NotOperator.selector); g.forget(user, id);
        vm.prank(exitKey); vm.expectRevert(abi.encodeWithSelector(GuardedLP.NotYours.selector, 12345)); g.forget(user, 12345);
    }
    function test_L2_forget_when_nft_burned_outside() public {
        uint256 id = _mint(0, 100 * U);
        vm.startPrank(user);
        npm.decreaseLiquidity(_dec(id, _liq(id)));
        npm.collect(INPM.CollectParams(id, user, type(uint128).max, type(uint128).max));
        npm.burn(id);                                                              // mock: ownerOf -> 0 afterwards
        vm.stopPrank();
        vm.prank(exitKey); g.forget(user, id);
        assertEq(g.costOf(user), 0); assertEq(_lost(), 100 * U);
    }

    // ---- L-4
    function test_L4_route_with_srcReceiver_equal_to_the_account_is_rejected() public {
        MockAccount acc = _account(address(0xB0B));                              // a contract account, so the code check alone cannot be what rejects
        GuardedLP.SwapDescriptionV2 memory d;
        d.srcToken = address(usdc); d.dstToken = address(weth); d.dstReceiver = address(g); d.amount = 100 * U; d.minReturnAmount = 1;
        d.srcReceivers = new address[](1); d.srcAmounts = new uint256[](1);
        d.srcReceivers[0] = address(acc); d.srcAmounts[0] = 100 * U;
        GuardedLP.SwapExecutionParams memory p; p.callTarget = exe; p.desc = d;
        vm.prank(op); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(address(acc), address(weth), 100 * U, 1, abi.encodeWithSelector(0xe21fd0e9, p));
        // control: the same route naming the executor as receiver is fine
        d.srcReceivers[0] = exe; p.desc = d;
        vm.prank(op); g.buy(address(acc), address(weth), 100 * U, 1, abi.encodeWithSelector(0xe21fd0e9, p));
        // and the caller as receiver is rejected too
        d.srcReceivers[0] = address(this); p.desc = d;
        vm.prank(address(this)); acc.run(address(g), abi.encodeWithSelector(g.authorize.selector, address(this), CAP));
        vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(address(acc), address(weth), 100 * U, 1, abi.encodeWithSelector(0xe21fd0e9, p));
    }

    // ================================================================ operator model
    function test_operator_stranger_reverts_NotOperator() public {
        vm.startPrank(thief);
        vm.expectRevert(GuardedLP.NotOperator.selector); g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        vm.expectRevert(GuardedLP.NotOperator.selector); g.sell(user, address(weth), 1, 1, sellRoute(1, 1));
        vm.expectRevert(GuardedLP.NotOperator.selector); g.mint(user, mintSpec(0, 10 * U));
        vm.expectRevert(GuardedLP.NotOperator.selector); g.increase(user, GuardedLP.AddSpec(1, 0, 1, 0, 0));
        vm.expectRevert(GuardedLP.NotOperator.selector); g.decrease(user, 1, 1, 0, 0);
        vm.expectRevert(GuardedLP.NotOperator.selector); g.collect(user, 1);
        vm.expectRevert(GuardedLP.NotOperator.selector); g.burn(user, 1);
        vm.expectRevert(GuardedLP.NotOperator.selector); g.payout(user, address(usdc), 1);
        vm.expectRevert(GuardedLP.NotOperator.selector); g.fundHedge(user, 1, _quote(1));
        vm.stopPrank();
    }
    function test_operator_of_another_account_cannot_act_here() public {
        vm.prank(thief); g.authorize(address(0x1234), 1 * U);
        vm.prank(address(0x1234)); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
    }
    function test_operator_revoked_reverts_NotOperator() public {
        _buy(10 * U);
        vm.prank(user); g.authorize(address(0), 0);
        assertEq(g.operatorOf(user), address(0)); assertEq(g.capOf(user), 0);
        vm.prank(op); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        vm.prank(op); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.sell(user, address(weth), 1, 1, sellRoute(1, 1));
        // the zero address is not a way in
        vm.prank(address(0)); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        // and the wallet itself keeps working
        vm.prank(user); g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
    }
    function test_operator_replaced_old_one_loses_access() public {
        vm.prank(user); g.authorize(thief, CAP);
        vm.prank(op); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
    }
    function test_operator_over_cap_reverts_CapExceeded() public {
        vm.prank(user); g.authorize(op, 100 * U);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.CapExceeded.selector, 200 * U, 100 * U));
        g.buy(user, address(weth), 200 * U, 1, buyRoute(200 * U, 1));
        _buy(100 * U);                                               // exactly the cap: fine
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.CapExceeded.selector, 150 * U, 100 * U));
        g.buy(user, address(weth), 50 * U, 1, buyRoute(50 * U, 1));
    }
    function test_operator_over_cap_via_mint_reverts_CapExceeded() public {
        vm.prank(user); g.authorize(op, 250 * U);
        _buy(100 * U);                                               // cost 100
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.CapExceeded.selector, 300 * U, 250 * U));
        g.mint(user, mintSpec(0.05 ether, 200 * U));                 // +200 USDC cost, lot tokens move at no extra cost
        _mint(0.05 ether, 150 * U);                                  // 250 = cap
    }
    function test_operator_cap_zero_means_nothing_can_be_kept_out() public {
        vm.prank(user); g.authorize(op, 0);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.CapExceeded.selector, 10 * U, 0));
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
    }
    function test_account_itself_acts_without_cap() public {
        vm.prank(user); g.authorize(op, 100 * U);
        vm.prank(user); g.buy(user, address(weth), 400 * U, 1, buyRoute(400 * U, 1));
        assertEq(g.costOf(user), 400 * U);
        vm.prank(user); g.mint(user, mintSpec(0.1 ether, 100 * U));
        // yet the operator cannot add anything while over the cap
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.CapExceeded.selector, 510 * U, 100 * U));
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
    }
    function test_operator_can_still_reduce_exposure_over_cap() public {
        vm.prank(user); g.authorize(op, 100 * U);
        vm.prank(user); g.buy(user, address(weth), 400 * U, 1, buyRoute(400 * U, 1));
        _sell(0.1 ether);                                            // selling and withdrawing are never blocked by the cap
        assertEq(g.costOf(user), 200 * U);
    }
    function test_authorize_rejects_self_and_gate() public {
        vm.prank(user); vm.expectRevert(GuardedLP.NotOperator.selector); g.authorize(user, 1);
        vm.prank(user); vm.expectRevert(GuardedLP.NotOperator.selector); g.authorize(address(g), 1);
    }
    function test_account_zero_is_not_an_account() public {
        vm.prank(address(0)); vm.expectRevert(GuardedLP.NotOperator.selector);
        g.buy(address(0), address(weth), 1, 1, buyRoute(1, 1));
    }

    // ================================================================ beneficiaryOf
    function test_beneficiaryOf_eoa_is_itself() public view { assertEq(g.beneficiaryOf(user), user); }
    function test_beneficiaryOf_smart_account_is_its_owner() public {
        MockAccount acc = new MockAccount(address(0xB0B));
        assertEq(g.beneficiaryOf(address(acc)), address(0xB0B));
    }
    function test_beneficiaryOf_7702_delegated_eoa_is_itself() public {
        address eoa = address(0x7702);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(0xDEAD)));
        assertEq(eoa.code.length, 23);
        assertEq(g.beneficiaryOf(eoa), eoa);
        // payout refuses (a plain wallet holds its own money) and fundHedge goes to itself
        usdc.mint(eoa, 500 * U);
        vm.startPrank(eoa); usdc.approve(address(g), type(uint256).max); g.authorize(op, CAP); vm.stopPrank();
        vm.prank(op); vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.payout(eoa, address(usdc), 1 * U);
        vm.prank(op); g.fundHedge(eoa, 100 * U, _quote(100 * U));
        assertEq(spoke.lastRecipient(), eoa);
    }
    function test_beneficiaryOf_other_code_without_owner_reverts() public {
        vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.beneficiaryOf(address(spoke));
        // 23 bytes of code that do not start with the 7702 prefix are not a delegated EOA
        address odd = address(0x2323);
        vm.etch(odd, abi.encodePacked(hex"000000", address(0xDEAD)));   // STOP-prefixed, 23 bytes, not 0xef0100
        vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.beneficiaryOf(odd);
    }
    function test_beneficiaryOf_owner_zero_reverts() public {
        MockAccount acc = new MockAccount(address(0));
        vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.beneficiaryOf(address(acc));
    }

    // ================================================================ constructor
    function test_constructor_requires_contracts() public {
        GuardedLP.Venues memory v = GuardedLP.Venues(address(router), exe, address(npm), address(0xFAC), address(usdc), address(spoke), 1337, HC_USDC, 6);
        vm.expectRevert(GuardedLP.NotAContract.selector);
        new GuardedLP(v, guardian, exitKey, 24, U, U);
    }

    // ================================================================ fuzz: costOf == sum(lot usdcIn) + sum(posCost)
    function _checkInvariant() internal view {
        uint256 sum;
        (, uint256 lc) = g.lotOf(user, address(weth)); sum += lc;
        uint256[] memory ids = g.positionsOf(user);
        for (uint256 i = 0; i < ids.length; i++) sum += g.posCost(ids[i]);
        assertEq(g.costOf(user), sum, "costOf == lots + positions");
    }
    uint256 okMint; uint256 okDec; uint256 okSell; uint256 okBurn;
    /// the fuzz sequence is not vacuous: over many seeds every step kind succeeds at least sometimes
    function test_fuzz_sequence_reaches_every_step_kind() public {
        for (uint256 i = 0; i < 60; i++) testFuzz_cost_invariant(uint256(keccak256(abi.encode("seed", i))));
        assertGt(okMint, 0, "mint"); assertGt(okDec, 0, "decrease"); assertGt(okSell, 0, "sell"); assertGt(okBurn, 0, "burn");
        emit log_named_uint("ok mint", okMint); emit log_named_uint("ok decrease", okDec); emit log_named_uint("ok sell", okSell); emit log_named_uint("ok burn", okBurn);
    }
    function testFuzz_cost_invariant(uint256 seed) public {
        usdc.mint(user, 50_000 * U);
        uint256[5] memory dens = [uint256(2000), 1500, 2500, 800, 4000];
        for (uint256 step = 0; step < 14; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 act = seed % 9; uint256 r = (seed >> 8);
            if (step % 4 == 3) vm.warp(block.timestamp + 1 hours);   // fresh rate-limit windows
            if (act == 0 || act == 1) {
                uint256 amt = 1 * U + r % (300 * U);
                vm.prank(op); try g.buy(user, address(weth), amt, 1, buyRoute(amt, 1)) {} catch {}
            } else if (act == 2) {
                (uint256 lt,) = g.lotOf(user, address(weth));
                if (lt > 0) {
                    uint256 a0 = lt * (1 + r % 100) / 100; uint256 a1 = r % (200 * U);
                    if (a0 == 0 && a1 == 0) a1 = U;
                    vm.prank(op); try g.mint(user, mintSpec(a0, a1)) { okMint++; } catch {}
                }
            } else if (act == 3) {
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) {
                    uint256 id = ids[r % ids.length]; uint128 l = _liq(id);
                    uint128 take = (r >> 16) % 3 == 0 ? l : uint128(uint256(l) * (1 + (r >> 8) % 100) / 100);
                    vm.prank(op); try g.decrease(user, id, take, 0, 0) { okDec++; } catch {}
                }
            } else if (act == 4) {
                (uint256 lt,) = g.lotOf(user, address(weth));
                if (lt > 0) {
                    uint256 amt = lt * (1 + r % 100) / 100;
                    router.set(1e12, dens[(r >> 8) % 5]);
                    vm.prank(op); try g.sell(user, address(weth), amt, 1, sellRoute(amt, 1)) { okSell++; } catch {}
                    router.set(1e12, 2000);
                }
            } else if (act == 5) {
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) { npm.addFees(ids[r % ids.length], r % (1 ether / 100), r % (5 * U)); vm.prank(op); try g.collect(user, ids[r % ids.length]) {} catch {} }
            } else if (act == 6) {
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) {
                    uint256 id = ids[r % ids.length];
                    (,,,,,,,, uint256 hh0, uint256 hh1) = npm.pos(id);
                    npm.setHeld(id, hh0 * (r % 120) / 100, hh1 * ((r >> 8) % 120) / 100);
                }
            } else if (act == 7) {
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) {
                    uint256 id = ids[r % ids.length];
                    vm.prank(op); try g.increase(user, GuardedLP.AddSpec(id, 0, r % (100 * U), 0, 0)) {} catch {}
                }
            } else {
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) { uint256 id = ids[r % ids.length]; vm.prank(op); try g.burn(user, id) { okBurn++; } catch {} }
            }
            _checkInvariant();
        }
    }
    function _dec(uint256 id, uint128 l) internal view returns (INPM.DecreaseLiquidityParams memory) { return INPM.DecreaseLiquidityParams(id, l, 0, 0, block.timestamp); }
}
