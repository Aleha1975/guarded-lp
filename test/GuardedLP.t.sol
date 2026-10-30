// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {GuardedLP, INPM} from "../src/GuardedLP.sol";
import {MockToken, MockRouter, MockNPM, MockTokenMessenger, MockAccount, MockFactory, MockPool} from "./Mocks.sol";

contract GuardedLPTest is Test {
    GuardedLP g;
    MockTokenMessenger tm; address constant FWD = 0xb21D281DEdb17AE5B501F6AA8256fe38C4e45757;
    MockToken usdc; MockToken weth; MockRouter router; MockNPM npm; MockFactory factory; MockPool pool; address exe;
    address guardian = address(0xA11CE); address exitKey = address(0xE017); address user = address(0xBEEF); address thief = address(0xBAD);
    address op = address(0x0907);
    uint256 constant U = 1e6; uint256 constant W = 1e18;
    uint256 constant CAP = 100_000 * 1e6;

    function _deploy() internal returns (GuardedLP) {
        return new GuardedLP(GuardedLP.Venues(address(router), router.executor(), address(npm), address(factory), address(usdc), address(tm), FWD),
            guardian, exitKey, 24, 5_000 * U, 5_000 * U);
    }

    function setUp() public {
        usdc = new MockToken("USDC", 6); weth = new MockToken("WETH", 18);
        router = new MockRouter(); npm = new MockNPM(); exe = router.executor();
        tm = new MockTokenMessenger(); factory = new MockFactory(); pool = new MockPool();
        factory.setPool(address(weth), address(usdc), 500, address(pool));
        g = _deploy();
        router.set(1e12, 2000); router.setBase(address(usdc));   // 2000 USDC (6 dec) per WETH (18 dec): buy out = in * 1e12 / 2000, sell the inverse
        vm.startPrank(exitKey); g.allowToken(address(weth)); g.allowToken(address(pool)); vm.stopPrank();
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
    function _lot(address a) internal view returns (uint256 t, uint256 c) { return g.lot(a, address(weth)); }
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
    function _hook(address to, uint32 dex) internal pure returns (bytes memory) {
        return bytes.concat(bytes24("cctp-forward"), bytes4(0), bytes4(uint32(24)), bytes20(to), bytes4(dex));
    }

    function test_fundHedge_perps_burns_through_cctp_forwarder() public {
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        vm.prank(op); g.fundHedge(address(acc), 300 * U, 520_000, true, false);
        assertEq(tm.calls(), 1);
        assertEq(tm.amount(), 300 * U); assertEq(tm.burnToken(), address(usdc));
        assertEq(tm.destinationDomain(), 19);
        assertEq(tm.mintRecipient(), bytes32(uint256(uint160(FWD))));
        assertEq(tm.destinationCaller(), bytes32(uint256(uint160(FWD))));
        assertEq(tm.maxFee(), 520_000); assertEq(tm.minFinalityThreshold(), 1000);
        bytes memory h = tm.hookData();
        assertEq(h.length, 56);
        assertEq(h, hex"636374702d666f72776172640000000000000000" hex"00000000" hex"00000000" hex"00000018" hex"0000000000000000000000000000000000000b0b" hex"00000000");
        assertEq(h, _hook(wallet, 0), "recipient is the owner wallet, perps dex");
        assertEq(usdc.balanceOf(address(tm)), 300 * U);
        assertEq(usdc.balanceOf(address(acc)), 700 * U); assertEq(usdc.balanceOf(address(g)), 0);
        assertEq(usdc.allowance(address(g), address(tm)), 0, "approval cleared");
    }
    function test_fundHedge_spot_standard_finality() public {
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        vm.prank(op); g.fundHedge(address(acc), 300 * U, 500_000, false, true);
        assertEq(tm.minFinalityThreshold(), 2000);
        assertEq(tm.hookData(), _hook(wallet, type(uint32).max));
        bytes memory h = tm.hookData();
        assertEq(uint8(h[52]), 0xff); assertEq(uint8(h[55]), 0xff);
    }
    function test_fundHedge_caller_cannot_choose_recipient() public {
        // the account itself calls (as forAccount allows): the hook still carries beneficiaryOf(account)
        address wallet = address(0xB0B);
        MockAccount acc = _account(wallet);
        vm.prank(address(acc)); g.fundHedge(address(acc), 10 * U, 500_000, true, false);
        assertEq(tm.hookData(), _hook(wallet, 0));
        vm.prank(op); g.fundHedge(address(acc), 10 * U, 500_000, true, false);
        assertEq(tm.hookData(), _hook(wallet, 0));
        // no parameter carries a recipient: ABI is (address,uint256,uint256,bool,bool)
        assertEq(g.fundHedge.selector, bytes4(keccak256("fundHedge(address,uint256,uint256,bool,bool)")));
    }
    function test_fundHedge_constants_and_immutables() public view {
        assertEq(g.DEST_DOMAIN(), 19); assertEq(g.TOKEN_MESSENGER(), address(tm)); assertEq(g.FORWARDER(), FWD);
        assertEq(g.FORWARD_FEE_CAP(), 1_000_000); assertEq(g.BRIDGE_MAX_FEE_BPS(), 100);
    }
    function test_fundHedge_fee_bound_edges() public {
        MockAccount acc = _account(address(0xB0B));
        // 300 USDC: 1% = 3 USDC + 1 USDC allowance = 4 USDC
        vm.prank(op); g.fundHedge(address(acc), 300 * U, 4 * U, true, false);
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc), 300 * U, 4 * U + 1, true, false);
        // maxFee must be below the amount even when the allowance would cover it
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc), 1 * U, 1 * U, true, false);
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc), 1 * U, 2 * U, true, false);
        vm.prank(op); g.fundHedge(address(acc), 1 * U, 1 * U - 1, true, false);
        // the floor: below Circle's forwarding fee the deposit could stall
        vm.prank(op); g.fundHedge(address(acc), 5 * U, 500_000, false, false);
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc), 5 * U, 499_999, false, false);
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector);
        g.fundHedge(address(acc), 5 * U, 0, false, false);
    }
    function test_fundHedge_plain_eoa_funds_itself() public {
        vm.prank(op); g.fundHedge(user, 10 * U, 500_000, true, false);
        assertEq(tm.hookData(), _hook(user, 0));
        assertEq(usdc.balanceOf(address(tm)), 10 * U);
    }
    function test_fundHedge_zero_amount_reverts() public {
        MockAccount acc = _account(address(0xB0B));
        vm.prank(op); vm.expectRevert(GuardedLP.ZeroAmount.selector);
        g.fundHedge(address(acc), 0, 0, true, false);
    }
    function test_fundHedge_bridge_failure_bubbles() public {
        MockAccount acc = _account(address(0xB0B));
        vm.etch(address(tm), hex"fd");    // always reverts
        vm.prank(op); vm.expectRevert();
        g.fundHedge(address(acc), 10 * U, 0, true, false);
    }
    function test_fundHedge_counts_against_usdc_out_limit() public {
        MockAccount acc = _account(address(0xB0B));
        usdc.mint(address(acc), 10_000 * U);
        vm.startPrank(op);
        g.fundHedge(address(acc), 4_000 * U, 10 * U, true, false);
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.fundHedge(address(acc), 2_000 * U, 5 * U, true, false);
        vm.stopPrank();
    }

    // ================================================================ audit 1057 regressions
    // ---- H-1: price check, young pools, lot bound
    function test_H1_mint_at_manipulated_price_reverts_PriceOff() public {
        _buy(200 * U);
        pool.setSpot(400);                                           // twap 0, spot 400 ticks away (> 50)
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(400), int24(0)));
        g.mint(user, mintSpec(0.1 ether, 200 * U));
        pool.setSpot(-400);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(-400), int24(0)));
        g.mint(user, mintSpec(0.1 ether, 200 * U));
        pool.setSpot(50);                                            // exactly at the bound: allowed
        _mint(0.1 ether, 200 * U);
    }
    function test_H1_mint_with_negative_twap_rounds_down() public {
        _buy(200 * U);
        pool.setTwap(-1000); pool.setSpot(-1000);
        _mint(0.1 ether, 100 * U);
        pool.setSpot(-1000 + 51);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(-949), int24(-1000)));
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
        // audit 1077 M-1: the operator's burn is budget-checked (loss 400 > 30% of the pre-exit base 1200 = 360); the wallet's own is not
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 400 * U, 360 * U));
        g.burn(user, id);
        vm.prank(user); g.burn(user, id);
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
        g.fundHedge(address(acc), 100 * U, 0, true, false);
        // 1079 L-4: the wallet acting itself is not paused (see test_1079_L4_*)
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

    // ================================================================ audit 1077 regressions
    function _evilPool(uint24 fee, int24 tick) internal returns (MockPool p2) {
        p2 = new MockPool(); p2.setSpot(tick); p2.setTwap(tick);       // attacker-initialised, idle: TWAP == fake spot
        factory.setPool(address(weth), address(usdc), fee, address(p2));
    }
    function _spec3000(uint256 a0, uint256 a1) internal view returns (GuardedLP.MintSpec memory m) { m = mintSpec(a0, a1); m.fee = 3000; }

    // ---- H-1: the pool must be allowlisted
    function test_1077_H1_allowed_token_in_unlisted_pool_reverts_BadPool_on_mint() public {
        _buy(200 * U);
        _evilPool(3000, 5000);
        vm.prank(op); vm.expectRevert(GuardedLP.BadPool.selector);
        g.mint(user, _spec3000(0.1 ether, 200 * U));
    }
    function test_1077_H1_unlisted_pool_reverts_BadPool_on_increase() public {
        _buy(200 * U);
        MockPool p2 = _evilPool(3000, 5000);
        vm.prank(exitKey); g.allowToken(address(p2));
        vm.prank(op); (uint256 id,,,) = g.mint(user, _spec3000(0.05 ether, 100 * U));
        vm.prank(exitKey); g.revokeToken(address(p2));                     // pool no longer listed
        vm.prank(op); vm.expectRevert(GuardedLP.BadPool.selector);
        g.increase(user, GuardedLP.AddSpec(id, 0, 50 * U, 0, 0));
        vm.prank(exitKey); g.allowToken(address(p2));                      // listed again: works
        vm.prank(op); g.increase(user, GuardedLP.AddSpec(id, 0, 50 * U, 0, 0));
    }
    function test_1077_H1_allowlisted_pool_works() public {
        assertTrue(g.allowed(address(pool)));
        _buy(200 * U);
        _mint(0.1 ether, 200 * U);
    }
    function test_1077_H1_revoked_pool_blocks_new_mints_but_not_the_way_out() public {
        _buy(400 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        uint256 id2 = _mint(0.1 ether, 200 * U);
        vm.prank(guardian); g.revokeToken(address(pool));
        assertFalse(g.allowed(address(pool)));
        vm.prank(op); vm.expectRevert(GuardedLP.BadPool.selector);
        g.mint(user, mintSpec(0.05 ether, 100 * U));
        uint128 l1 = _liq(id);
        vm.prank(user); (uint256 d0,) = g.decrease(user, id, l1, 0, 0);   // the wallet leaves
        assertEq(d0, 0.1 ether);
        vm.prank(exitKey); g.exitDecrease(user, id2, 0, 0);                      // the cold key leaves
        assertEq(g.posCost(id), 0); assertEq(g.posCost(id2), 0);
        vm.prank(op); g.collect(user, id);                                       // collect needs no price check either
    }
    function test_1077_H1_guardian_proposed_pool_usable_only_after_token_delay() public {
        _buy(200 * U);
        MockPool p2 = _evilPool(3000, 0);
        vm.prank(guardian); g.allowToken(address(p2));
        vm.prank(op); vm.expectRevert(GuardedLP.BadPool.selector);
        g.mint(user, _spec3000(0.05 ether, 100 * U));
        vm.warp(block.timestamp + g.TOKEN_DELAY() - 1);
        vm.prank(op); vm.expectRevert(GuardedLP.BadPool.selector);
        g.mint(user, _spec3000(0.05 ether, 100 * U));
        vm.warp(block.timestamp + 1);
        vm.prank(op); g.mint(user, _spec3000(0.05 ether, 100 * U));
    }

    // ---- M-1: tick band 50 and position losses budget-checked for the operator
    function test_1077_M1_max_tick_dev_is_50_boundaries() public {
        assertEq(int256(g.MAX_TICK_DEV()), 50);
        _buy(400 * U);
        pool.setSpot(51);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(51), int24(0)));
        g.mint(user, mintSpec(0.05 ether, 100 * U));
        pool.setSpot(-51);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(-51), int24(0)));
        g.mint(user, mintSpec(0.05 ether, 100 * U));
        pool.setSpot(-50); uint256 id = _mint(0.05 ether, 100 * U);
        pool.setSpot(50);  vm.prank(op); g.increase(user, GuardedLP.AddSpec(id, 0, 10 * U, 0, 0));
        pool.setSpot(51);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(51), int24(0)));
        g.increase(user, GuardedLP.AddSpec(id, 0, 10 * U, 0, 0));
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(51), int24(0)));
        g.decrease(user, id, 1, 0, 0);
        pool.setSpot(50);
        vm.prank(op); g.decrease(user, id, 1, 0, 0);
    }
    /// a USDC-only position of the whole balance that the pool returns nothing for: loss 1000 against a 300 budget
    function _wipedPosition() internal returns (uint256 id) {
        vm.prank(op); (id,,,) = g.mint(user, mintSpec(0, 1_000 * U));
        npm.setHeld(id, 0, 0);
    }
    function test_1077_M1_operator_decrease_over_budget_reverts() public {
        uint256 id = _wipedPosition();
        uint128 l = _liq(id);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 1_000 * U, 300 * U));
        g.decrease(user, id, l, 0, 0);
        assertEq(g.posCost(id), 1_000 * U, "nothing changed"); assertEq(_lost(), 0);
    }
    function test_1077_M1_operator_decrease_within_budget_books() public {
        vm.prank(op); (uint256 id,,,) = g.mint(user, mintSpec(0, 200 * U));
        npm.setHeld(id, 0, 120 * U);
        _decreaseAll(id);
        assertEq(_lost(), 80 * U);
    }
    function test_1077_M1_wallet_decrease_same_withdrawal_succeeds_and_books() public {
        uint256 id = _wipedPosition();
        uint128 l = _liq(id);
        vm.prank(user); g.decrease(user, id, l, 0, 0);
        assertEq(_lost(), 1_000 * U); assertEq(g.costOf(user), 0); assertEq(g.posCost(id), 0);
    }
    function test_1077_M1_exitDecrease_same_withdrawal_succeeds_and_books() public {
        uint256 id = _wipedPosition();
        vm.prank(exitKey); g.exitDecrease(user, id, 0, 0);
        assertEq(_lost(), 1_000 * U); assertEq(g.costOf(user), 0); assertEq(g.posCost(id), 0);
    }
    function test_1077_M1_operator_burn_with_large_leftover_cost_reverts_wallet_burn_books() public {
        uint256 id = _wipedPosition();
        vm.startPrank(user);
        npm.decreaseLiquidity(_dec(id, _liq(id)));
        npm.collect(INPM.CollectParams(id, user, type(uint128).max, type(uint128).max));
        vm.stopPrank();
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 1_000 * U, 300 * U));
        g.burn(user, id);
        assertEq(g.posCost(id), 1_000 * U);
        vm.prank(user); g.burn(user, id);
        assertEq(_lost(), 1_000 * U); assertEq(g.costOf(user), 0);
    }
    function test_1077_M1_forget_never_enforces_the_budget() public {
        uint256 id = _wipedPosition();
        vm.prank(user); npm.transferFrom(user, thief, id);
        vm.prank(exitKey); g.forget(user, id);
        assertEq(_lost(), 1_000 * U);
        // and the wallet itself
        usdc.mint(user, 500 * U);
        vm.prank(op); (uint256 id2,,,) = g.mint(user, mintSpec(0, 500 * U));
        vm.prank(user); npm.transferFrom(user, thief, id2);
        vm.prank(user); g.forget(user, id2);
        assertEq(_lost(), 1_500 * U);
        assertEq(g.costOf(user), 0);
    }

    // ---- L-1: the wallet itself is never price-gated on decrease
    function test_1077_L1_wallet_decrease_ignores_manipulated_spot_operator_does_not() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        pool.setSpot(900);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.PriceOff.selector, int24(900), int24(0)));
        g.decrease(user, id, 1, 0, 0);
        uint128 l1 = _liq(id);
        vm.prank(user); (uint256 d0,) = g.decrease(user, id, l1, 0, 0);
        assertEq(d0, 0.1 ether);
    }
    function test_1077_L1_wallet_decrease_works_when_observe_reverts_operator_does_not() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        pool.setYoung(true);
        vm.prank(op); vm.expectRevert(bytes("OLD"));
        g.decrease(user, id, 1, 0, 0);
        uint128 l1 = _liq(id);
        vm.prank(user); g.decrease(user, id, l1, 0, 0);
        assertEq(g.posCost(id), 0);
    }

    // ---- L-3: cap bounds the base whenever an operator is set
    function test_1077_L3_cap_zero_operator_cannot_sell_at_any_loss_wallet_can() public {
        vm.prank(user); g.buy(user, address(weth), 200 * U, 1, buyRoute(200 * U, 1));   // 0.1 WETH at cost 200
        vm.prank(user); g.authorize(op, 0);
        (, uint256 budget) = g.budgetOf(user); assertEq(budget, 0, "cap 0 => base 0 => budget 0");
        router.set(1e12, 1999);                                                          // sells for 199.9: loss 0.1 USDC
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 0.05e6, 0));
        g.sell(user, address(weth), 0.05 ether, 1, sellRoute(0.05 ether, 1));
        vm.prank(user); g.sell(user, address(weth), 0.05 ether, 1, sellRoute(0.05 ether, 1));
        assertEq(_lost(), 0.05e6, "wallet's own sale booked, not blocked");
        router.set(1e12, 2000);                                                          // at no loss the operator may still sell
        _sell(0.05 ether);
    }
    function test_1077_L3_revoking_the_operator_removes_the_cap_from_base() public {
        _buy(200 * U);                                                                   // costOf 200 + 800 USDC
        vm.prank(user); g.authorize(op, 100 * U);
        (, uint256 b) = g.budgetOf(user); assertEq(b, 30 * U, "capped at 100");
        vm.prank(user); g.authorize(address(0), 0);
        (, b) = g.budgetOf(user); assertEq(b, 300 * U, "uncapped base 1000");
        vm.prank(user); g.authorize(op, CAP);
        (, b) = g.budgetOf(user); assertEq(b, 300 * U, "cap above base changes nothing");
    }
    function test_1077_L3_wallet_sale_over_budget_with_operator_set_succeeds_exit_too() public {
        _buy(800 * U);
        router.set(1e12, 500);                                                           // 0.4 WETH -> 200, loss 600 > budget 300
        vm.prank(user); g.sell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        assertEq(_lost(), 300 * U);
        vm.prank(user); g.sell(user, address(weth), 0.2 ether, 1, sellRoute(0.2 ether, 1));
        assertEq(_lost(), 600 * U);
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
        vm.expectRevert(GuardedLP.NotOperator.selector); g.fundHedge(user, 1, 0, true, false);
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
        // fundHedge goes to itself
        usdc.mint(eoa, 500 * U);
        vm.startPrank(eoa); usdc.approve(address(g), type(uint256).max); g.authorize(op, CAP); vm.stopPrank();
        vm.prank(op); g.fundHedge(eoa, 100 * U, 500_000, true, false);
        assertEq(tm.hookData(), _hook(eoa, 0), "7702 EOA funds itself");
    }
    function test_beneficiaryOf_other_code_without_owner_reverts() public {
        vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.beneficiaryOf(address(tm));
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
        GuardedLP.Venues memory v = GuardedLP.Venues(address(router), exe, address(npm), address(0xFAC), address(usdc), address(tm), FWD);
        vm.expectRevert(GuardedLP.NotAContract.selector);
        new GuardedLP(v, guardian, exitKey, 24, U, U);
    }

    // ================================================================ audit 1079 regressions
    // sqrtPriceX96 at ticks (price1/0 of 2000 USDC per WETH; WETH = token0: tick -200312, USDC = token0: tick +200311)
    int24 constant T_W = -200312; uint160 constant SQ_W = 3543049682531703600807384; uint160 constant SQ_W_UP = 3550142517731957613354948; uint160 constant SQ_W_DN = 3535971018117812864267793;
    int24 constant T_U = 200311;  uint160 constant SQ_U = 1771577727172025373304338615273324; uint160 constant SQ_U_UP = 1775124250644508264018171251566048; uint160 constant SQ_U_DN = 1768038289304246663365738393952978;
    uint256 constant TOL = 1 * U;   // valuation at a tick price is within 0.01% of 2000: far less than 1 USDC on these sizes

    function _spot(MockPool p, int24 twap, int24 spot, uint160 sq) internal { p.setTwap(twap); p.setSpot(spot); p.setSqrt(sq); }
    /// WETH-token0 pool (fee 500): the operator holds cost 400 in a position (0.1 WETH + 200 USDC), wallet keeps 600 USDC.
    /// An accomplice has moved spot 40 ticks up (inside the 50-tick band); the pool then returns `heldWeth` and no USDC.
    function _trappedW(uint256 heldWeth) internal returns (uint256 id) {
        _buy(200 * U);
        id = _mint(0.1 ether, 200 * U);
        assertEq(g.costOf(user), 400 * U);
        _spot(pool, T_W, T_W + 40, SQ_W_UP);
        npm.setHeld(id, heldWeth, 0);
    }
    /// USDC-token0 pool (fee 3000), same economics.
    function _trappedU(uint256 heldWeth) internal returns (uint256 id, MockPool p2) {
        p2 = new MockPool(); factory.setPool(address(usdc), address(weth), 3000, address(p2));
        vm.prank(exitKey); g.allowToken(address(p2));
        _spot(p2, T_U, T_U + 40, SQ_U_UP);           // WETH is cheaper in USDC when price1/0 is higher
        _buy(200 * U);
        GuardedLP.MintSpec memory m = mintSpec(0, 0); m.token0 = address(usdc); m.token1 = address(weth); m.fee = 3000; m.amount0Desired = 200 * U; m.amount1Desired = 0.1 ether;
        vm.prank(op); (id,,,) = g.mint(user, m);
        assertEq(g.costOf(user), 400 * U);
        npm.setHeld(id, 0, heldWeth);
    }
    function _lotCost() internal view returns (uint256 c) { (, c) = _lot(user); }

    function test_1079_M1_operator_decrease_books_shortfall_weth_token0() public {
        uint256 id = _trappedW(0.1 ether);                  // 0.1 WETH at ~2008 = ~200.8 against cost 400
        uint256 v = 0.1 ether * 2008 / 1e12;
        uint256 l = _liq(id); vm.prank(op); g.decrease(user, id, uint128(l), 0, 0);
        assertApproxEqAbs(_lost(), 400 * U - v, TOL, "shortfall booked as loss");
        assertApproxEqAbs(g.costOf(user), v, TOL, "costOf reduced to the value");
        assertEq(g.costOf(user), _lotCost(), "lot cost = costOf");
        (uint256 lt,) = _lot(user); assertEq(lt, 0.1 ether);
        assertEq(g.posCost(id), 0);
        _checkInvariant();
    }
    function test_1079_M1_operator_decrease_books_shortfall_usdc_token0() public {
        (uint256 id,) = _trappedU(0.1 ether);               // 0.1 WETH at ~1992 (price1/0 +0.4%) against cost 400
        uint256 v = 0.1 ether * 1992 / 1e12;
        uint128 l = _liq(id); vm.prank(op); g.decrease(user, id, l, 0, 0);
        assertApproxEqAbs(_lost(), 400 * U - v, TOL);
        assertApproxEqAbs(g.costOf(user), v, TOL);
        assertEq(g.costOf(user), _lotCost());
        _checkInvariant();
    }
    function test_1079_M1_shortfall_over_budget_reverts_weth_token0() public {
        uint256 id = _trappedW(0.04 ether);                 // value ~80, shortfall ~320 > budget 300 (30% of the pre-exit base 1000)
        uint128 l = _liq(id);
        vm.prank(op); vm.expectPartialRevert(GuardedLP.BudgetExceeded.selector);
        g.decrease(user, id, l, 0, 0);
        assertEq(g.posCost(id), 400 * U, "nothing changed"); assertEq(_lost(), 0); assertEq(g.costOf(user), 400 * U);
    }
    function test_1079_M1_shortfall_over_budget_reverts_usdc_token0() public {
        (uint256 id,) = _trappedU(0.05 ether);
        uint128 l = _liq(id);
        vm.prank(op); vm.expectPartialRevert(GuardedLP.BudgetExceeded.selector);
        g.decrease(user, id, l, 0, 0);
        assertEq(g.posCost(id), 400 * U); assertEq(_lost(), 0); assertEq(g.costOf(user), 400 * U);
    }
    function test_1079_M1_reranging_in_a_falling_market_is_not_blocked() public {
        // the wallet's whole 1000 USDC (setUp) goes into one position: the budget after deploying would be ~0
        vm.prank(op); (uint256 id,,,) = g.mint(user, mintSpec(0, 1_000 * U));
        assertEq(g.costOf(user), 1_000 * U); assertEq(usdc.balanceOf(user), 0);
        npm.setHeld(id, 0.45 ether, 0);                     // price fell through the range: 0.45 WETH at 2000 = 900, 10% under cost
        uint128 l = _liq(id);
        vm.prank(op); g.decrease(user, id, l, 0, 0);
        assertApproxEqAbs(_lost(), 100 * U, TOL, "~10% shortfall booked, inside 30% of the pre-exit base");
        assertApproxEqAbs(g.costOf(user), 900 * U, TOL);
        assertEq(g.costOf(user), _lotCost());
        (uint256 lt,) = _lot(user); assertEq(lt, 0.45 ether);
        assertEq(g.posCost(id), 0);
        _checkInvariant();
    }
    function test_1079_M1_wallet_withdrawal_keeps_the_cost_on_the_tokens() public {
        uint256 id = _trappedW(0.05 ether);
        uint128 l = _liq(id); vm.prank(user); g.decrease(user, id, l, 0, 0);
        assertEq(_lost(), 0); assertEq(g.costOf(user), 400 * U); assertEq(_lotCost(), 400 * U);
        (uint256 lt,) = _lot(user); assertEq(lt, 0.05 ether);
    }
    function test_1079_M1_exitDecrease_keeps_the_cost_on_the_tokens() public {
        (uint256 id,) = _trappedU(0.05 ether);
        vm.prank(exitKey); g.exitDecrease(user, id, 0, 0);
        assertEq(_lost(), 0); assertEq(g.costOf(user), 400 * U); assertEq(_lotCost(), 400 * U);
    }
    function test_1079_M1_fair_decrease_books_nothing() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);             // cost 400
        _spot(pool, T_W, T_W + 40, SQ_W_UP);                // 0.1 WETH is worth ~200.8 >= the 200 left after USDC repays 200
        _decreaseAll(id);
        assertEq(_lost(), 0); assertEq(g.costOf(user), 200 * U); assertEq(_lotCost(), 200 * U);
    }
    function test_1079_M1_fair_decrease_books_nothing_usdc_token0() public {
        (uint256 id,) = _trappedU(0.1 ether);
        npm.setHeld(id, 200 * U, 0.1 ether);                // unchanged principal; price1/0 low => WETH worth ~2008
        _spot(MockPool(factory.getPool(address(usdc), address(weth), 3000)), T_U, T_U - 40, SQ_U_DN);
        _decreaseAll(id);
        assertEq(_lost(), 0); assertEq(g.costOf(user), 200 * U); assertEq(_lotCost(), 200 * U);
    }
    function test_1079_M1_value_just_below_rest_books_only_the_difference() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        _spot(pool, T_W, T_W - 40, SQ_W_DN);                // 0.1 WETH worth ~199.2 < 200
        _decreaseAll(id);
        assertApproxEqAbs(_lost(), 8e5, 3e5, "~0.8 USDC");
        assertEq(g.costOf(user), _lotCost());
        assertApproxEqAbs(_lotCost(), 199_200_000, TOL);
    }

    // ---- L-1: no add-back
    function test_1079_L1_budget_is_exactly_30_percent_of_the_base() public {
        usdc.mint(user, 300 * U);                           // 1300: a USDC-only position of all of it
        vm.prank(op); (uint256 id,,,) = g.mint(user, mintSpec(0, 1_300 * U));
        npm.setHeld(id, 0, 910 * U);                        // returns 910: loss 390 = 30% of the pre-operation base 1300 exactly
        uint256 snap = vm.snapshotState();
        _decreaseAll(id);
        assertEq(_lost(), 390 * U);
        vm.revertToState(snap);
        npm.setHeld(id, 0, 910 * U - 1);                    // one unit less: loss 390.000001 > 390
        uint128 l = _liq(id);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 390 * U + 1, 1_300 * U * 3000 / 10000));
        g.decrease(user, id, l, 0, 0);
    }
    function test_1079_L1_sale_budget_has_no_add_back() public {
        _buy(800 * U);                                      // base 1000, budget 300
        router.set(1e12, 500);
        vm.prank(op); vm.expectRevert(abi.encodeWithSelector(GuardedLP.BudgetExceeded.selector, 600 * U, 300 * U));
        g.sell(user, address(weth), 0.4 ether, 1, sellRoute(0.4 ether, 1));
    }

    // ---- L-3
    function test_1079_L3_min_forward_fee() public {
        assertEq(g.MIN_FORWARD_FEE(), 500_000);
        vm.prank(op); vm.expectRevert(GuardedLP.BridgeFee.selector); g.fundHedge(user, 100 * U, 499_999, true, false);
        vm.prank(op); g.fundHedge(user, 100 * U, 500_000, true, false);
        assertEq(tm.maxFee(), 500_000);
    }

    // ---- L-4
    function test_1079_L4_paused_wallet_acts_operator_cannot() public {
        _buy(200 * U);
        uint256 id = _mint(0.1 ether, 200 * U);
        vm.prank(guardian); g.setPaused(true);
        vm.startPrank(op);
        vm.expectRevert(GuardedLP.IsPaused.selector); g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.sell(user, address(weth), 1, 1, sellRoute(1, 1));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.mint(user, mintSpec(0, 10 * U));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.increase(user, GuardedLP.AddSpec(id, 0, 10 * U, 0, 0));
        vm.expectRevert(GuardedLP.IsPaused.selector); g.fundHedge(user, 10 * U, 500_000, true, false);
        vm.stopPrank();
        vm.startPrank(user);
        g.buy(user, address(weth), 10 * U, 1, buyRoute(10 * U, 1));
        g.sell(user, address(weth), 0.001 ether, 1, sellRoute(0.001 ether, 1));
        g.mint(user, mintSpec(0, 10 * U));
        g.increase(user, GuardedLP.AddSpec(id, 0, 10 * U, 0, 0));
        g.fundHedge(user, 10 * U, 500_000, true, false);
        vm.stopPrank();
        assertEq(tm.calls(), 1);
    }
    function test_1079_L4_wallet_calls_do_not_consume_the_operators_limits() public {
        usdc.mint(user, 40_000 * U);
        vm.startPrank(user);
        for (uint256 i = 0; i < 30; i++) g.buy(user, address(weth), 1 * U, 1, buyRoute(1 * U, 1));      // 30 ops > 24
        g.buy(user, address(weth), 6_000 * U, 1, buyRoute(6_000 * U, 1));                              // 6000 in > 5000
        g.fundHedge(user, 6_000 * U, 500_000, true, false);                                            // 6000 out > 5000
        vm.stopPrank();
        vm.startPrank(op);
        g.fundHedge(user, 4_000 * U, 500_000, true, false);                                            // op's own out budget is untouched
        for (uint256 i = 0; i < 23; i++) g.buy(user, address(weth), 1 * U, 1, buyRoute(1 * U, 1));     // 24 ops used with fundHedge
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.buy(user, address(weth), 1 * U, 1, buyRoute(1 * U, 1));
        vm.warp(block.timestamp + 1 hours);
        g.buy(user, address(weth), 4_999 * U, 1, buyRoute(4_999 * U, 1));
        vm.expectRevert(GuardedLP.RateLimited.selector);
        g.buy(user, address(weth), 2 * U, 1, buyRoute(2 * U, 1));
        vm.stopPrank();
    }

    // ---- L-6
    function test_1079_L6_smart_account_owned_by_a_contract_has_no_beneficiary() public {
        MockAccount inner = new MockAccount(address(0xB0B));
        MockAccount acc = _account(address(0xB0B)); // placeholder to get funded wiring
        MockAccount outer = new MockAccount(address(inner));
        usdc.mint(address(outer), 500 * U);
        outer.run(address(usdc), abi.encodeWithSelector(usdc.approve.selector, address(g), type(uint256).max));
        outer.run(address(g), abi.encodeWithSelector(g.authorize.selector, op, CAP));
        vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.beneficiaryOf(address(outer));
        vm.prank(op); vm.expectRevert(GuardedLP.NoBeneficiary.selector);
        g.fundHedge(address(outer), 10 * U, 500_000, true, false);
        assertEq(g.beneficiaryOf(address(acc)), address(0xB0B));
    }
    function test_1079_L6_owner_plain_or_7702_is_fine() public {
        MockAccount a = new MockAccount(address(0xB0B));
        assertEq(g.beneficiaryOf(address(a)), address(0xB0B));
        address del = address(0x7702); vm.etch(del, abi.encodePacked(hex"ef0100", address(0xDEAD)));
        MockAccount b = new MockAccount(del);
        assertEq(g.beneficiaryOf(address(b)), del);
        address other = address(0xC0DE); vm.etch(other, abi.encodePacked(hex"600100", address(0xDEAD)));   // 23 bytes but not a designator: a contract
        MockAccount c = new MockAccount(other);
        vm.expectRevert(GuardedLP.NoBeneficiary.selector); g.beneficiaryOf(address(c));
    }

    // ================================================================ fuzz: costOf == sum(lot usdcIn) + sum(posCost)
    function _checkInvariant() internal view {
        uint256 sum;
        (, uint256 lc) = g.lot(user, address(weth)); sum += lc;
        uint256[] memory ids = g.positionsOf(user);
        for (uint256 i = 0; i < ids.length; i++) sum += g.posCost(ids[i]);
        assertEq(g.costOf(user), sum, "costOf == lots + positions");
    }
    uint256 budgetReverts; uint256 shortfalls; uint256 okMint; uint256 okDec; uint256 okSell; uint256 okBurn;
    /// the fuzz sequence is not vacuous: over many seeds every step kind succeeds at least sometimes
    function test_fuzz_sequence_reaches_every_step_kind() public {
        for (uint256 i = 0; i < 60; i++) testFuzz_cost_invariant(uint256(keccak256(abi.encode("seed", i))));
        assertGt(okMint, 0, "mint"); assertGt(okDec, 0, "decrease"); assertGt(okSell, 0, "sell"); assertGt(okBurn, 0, "burn"); assertGt(budgetReverts, 0, "operator decrease hit BudgetExceeded"); assertGt(shortfalls, 0, "operator decrease booked a loss");
        emit log_named_uint("ok mint", okMint); emit log_named_uint("ok decrease", okDec); emit log_named_uint("ok sell", okSell); emit log_named_uint("ok burn", okBurn); emit log_named_uint("op decrease booked loss", shortfalls);
    }
    function testFuzz_cost_invariant(uint256 seed) public {
        usdc.mint(user, 50_000 * U);
        uint256[5] memory dens = [uint256(2000), 1500, 2500, 800, 4000];
        for (uint256 step = 0; step < 14; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 act = seed % 11; uint256 r = (seed >> 8);
            if (step % 4 == 3) vm.warp(block.timestamp + 1 hours);   // fresh rate-limit windows
            if (act == 0 || act == 1) {
                uint256 amt = 1 * U + r % (300 * U);
                vm.prank(op); try g.buy(user, address(weth), amt, 1, buyRoute(amt, 1)) {} catch {}
            } else if (act == 2) {
                (uint256 lt,) = g.lot(user, address(weth));
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
                (uint256 lt,) = g.lot(user, address(weth));
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
            } else if (act == 9) {
                // operator decrease after the pool shrank what it holds: may revert BudgetExceeded, skipped like any revert
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) {
                    uint256 id = ids[r % ids.length];
                    (,,,,,,,, uint256 hh0, uint256 hh1) = npm.pos(id);
                    npm.setHeld(id, hh0 * (r % 40) / 100, hh1 * ((r >> 8) % 40) / 100);
                    if ((r >> 16) % 3 == 0) { uint256 bal = usdc.balanceOf(user); if (bal > U) { vm.prank(user); usdc.transfer(address(0xdead), bal - U); } }   // the wallet spent its cash: small base
                    uint128 lq = _liq(id);
                    pool.setSqrt(uint160(uint256(pool.sqrtP()) * (9_000 + (r >> 24) % 2_000) / 10_000));   // spot (and so the value of the returned WETH) drifts +-10%: 1079 M-1 shortfall path
                    uint256 lostBefore = _lost();
                    vm.prank(op); try g.decrease(user, id, lq, 0, 0) { okDec++; if (_lost() > lostBefore) shortfalls++; } catch (bytes memory err) { if (bytes4(err) == GuardedLP.BudgetExceeded.selector) budgetReverts++; }
                }
            } else if (act == 10) {
                uint256[] memory ids = g.positionsOf(user);   // the wallet itself withdraws: never price- or budget-gated
                if (ids.length > 0) { uint256 id = ids[r % ids.length]; uint128 wl = uint128(uint256(_liq(id)) * (1 + (r >> 8) % 100) / 100); vm.prank(user); try g.decrease(user, id, wl, 0, 0) { okDec++; } catch {} }
            } else {
                uint256[] memory ids = g.positionsOf(user);
                if (ids.length > 0) { uint256 id = ids[r % ids.length]; vm.prank(op); try g.burn(user, id) { okBurn++; } catch {} }
            }
            _checkInvariant();
        }
    }
    function _dec(uint256 id, uint128 l) internal view returns (INPM.DecreaseLiquidityParams memory) { return INPM.DecreaseLiquidityParams(id, l, 0, 0, block.timestamp); }
}
