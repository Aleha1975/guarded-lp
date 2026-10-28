// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {GuardedLP} from "../src/GuardedLP.sol";

interface IERC20Like { function balanceOf(address) external view returns (uint256); function approve(address, uint256) external returns (bool); }
interface IFactoryLike { function getPool(address, address, uint24) external view returns (address); }
interface IPool { function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool); }
interface INPMLike { function setApprovalForAll(address, bool) external; function ownerOf(uint256) external view returns (address); function positions(uint256) external view returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128); }

/// Real Base: Uniswap V3 position manager, USDC, WETH, KyberSwap router with live route calldata from
/// test/fixtures/base_kyber.json (fetch with `python3 script/kyber_fixture.py` right before running: routes expire).
/// Run: BASE_RPC=<url> forge test --match-contract Fork
contract ForkTest is Test {
    address constant NPM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address constant EXECUTOR = 0x8F10B468b06c6FD214B65F87778827F7D113f996;
    address constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;    // WETH/USDC 0.05%
    address constant GATE = 0x1111111111111111111111111111111111111111;
    address constant SPOKE = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;   // Across SpokePool, Base
    address op = address(0x0907); address guardian = address(0xA11CE); address exitKey = address(0xE017); address user = address(0xBEEF);
    GuardedLP g; string fx; uint256 gw0; uint256 gu0;   // the gate address holds dust on mainnet; everything is measured against it

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC not set");
        fx = vm.readFile("test/fixtures/base_kyber.json");
        uint256 blk = vm.parseJsonUint(fx, ".block");
        vm.createSelectFork(rpc, blk);
        deployCodeTo("GuardedLP.sol:GuardedLP", abi.encode(GuardedLP.Venues(ROUTER, EXECUTOR, NPM, FACTORY, USDC, SPOKE, 1337, 0x2100000000000000000000000000000000000000, 6), guardian, exitKey, uint256(24), uint256(5_000e6), uint256(5_000e6)), GATE);
        g = GuardedLP(GATE);
        vm.prank(exitKey); g.allowToken(WETH);
        gw0 = IERC20Like(WETH).balanceOf(GATE); gu0 = IERC20Like(USDC).balanceOf(GATE);
        deal(USDC, user, 1_000e6);
        vm.startPrank(user);
        IERC20Like(USDC).approve(GATE, type(uint256).max);
        IERC20Like(WETH).approve(GATE, type(uint256).max);
        INPMLike(NPM).setApprovalForAll(GATE, true);
        g.authorize(op, 100_000e6);
        vm.stopPrank();
    }

    function test_real_base_round_trip() public {
        bytes memory buyData = vm.parseJsonBytes(fx, ".buy.data");
        uint256 buyIn = vm.parseJsonUint(fx, ".buy.amountIn");
        uint256 buyQuote = vm.parseJsonUint(fx, ".buy.amountOut");
        uint256 w0 = IERC20Like(WETH).balanceOf(user);                   // the address may hold dust on mainnet
        vm.startPrank(op);
        uint256 out = g.buy(user, WETH, buyIn, buyQuote * 97 / 100, buyData);
        assertGe(out, buyQuote * 97 / 100, "buy delivered");
        assertEq(IERC20Like(WETH).balanceOf(user) - w0, out, "WETH on the account");
        (uint256 lt, uint256 lu) = g.lotOf(user, WETH); assertEq(lt, out); assertEq(lu, buyIn);

        (, int24 tick,,,,,) = IPool(POOL).slot0();
        int24 lo = (tick - 600) / 10 * 10; int24 hi = (tick + 600) / 10 * 10;
        GuardedLP.MintSpec memory m = GuardedLP.MintSpec(WETH, USDC, 500, lo, hi, out, 100e6, 0, 0);
        (uint256 id, uint128 liq, uint256 a0, uint256 a1) = g.mint(user, m);
        assertEq(INPMLike(NPM).ownerOf(id), user, "NFT minted to the account");
        assertGt(liq, 0); assertGt(a0, 0); assertGt(a1, 0);
        assertEq(IERC20Like(WETH).balanceOf(GATE), gw0); assertEq(IERC20Like(USDC).balanceOf(GATE), gu0);
        assertEq(g.posCost(id), a1 + (out * 0 + buyIn), "cost = USDC in + the WETH cost share");
        emit log_named_uint("WETH into pool", a0); emit log_named_uint("USDC into pool", a1);

        (uint256 d0, uint256 d1) = g.decrease(user, id, liq, 0, 0);
        assertApproxEqRel(d0, a0, 1e15, "WETH back"); assertApproxEqRel(d1, a1, 1e15, "USDC back");
        assertEq(g.posCost(id), 0, "position cost moved back to the books");
        g.burn(user, id);
        assertEq(g.positionsOf(user).length, 0);

        bytes memory sellData = vm.parseJsonBytes(fx, ".sell.data");
        uint256 sellIn = vm.parseJsonUint(fx, ".sell.amountIn");
        uint256 sellQuote = vm.parseJsonUint(fx, ".sell.amountOut");
        uint256 before = IERC20Like(USDC).balanceOf(user);
        uint256 got = g.sell(user, WETH, sellIn, sellQuote * 97 / 100, sellData);
        assertGe(got, sellQuote * 97 / 100, "sale delivered");
        assertEq(IERC20Like(USDC).balanceOf(user) - before, got, "USDC on the account");
        assertEq(IERC20Like(WETH).balanceOf(GATE), gw0); assertEq(IERC20Like(USDC).balanceOf(GATE), gu0);
        vm.stopPrank();
    }

    function test_real_base_pool_exists_for_price_check() public view {
        assertTrue(IFactoryLike(FACTORY).getPool(WETH, USDC, 500) != address(0));
        assertTrue(IFactoryLike(FACTORY).getPool(WETH, USDC, 10000) != address(0));
        assertEq(IFactoryLike(FACTORY).getPool(WETH, USDC, 500), POOL);
    }

    function test_real_base_route_to_someone_else_is_refused() public {
        bytes memory buyData = vm.parseJsonBytes(fx, ".buy.data");
        uint256 buyIn = vm.parseJsonUint(fx, ".buy.amountIn");
        // flip one byte of the receiver inside the calldata: the decoded route no longer names the gate
        GuardedLP.SwapExecutionParams memory p = abi.decode(slice(buyData), (GuardedLP.SwapExecutionParams));
        p.desc.dstReceiver = address(0xBAD);
        vm.prank(op); vm.expectRevert(GuardedLP.BadRoute.selector);
        g.buy(user, WETH, buyIn, 1, abi.encodeWithSelector(0xe21fd0e9, p));
    }
    function slice(bytes memory d) internal pure returns (bytes memory r) {
        r = new bytes(d.length - 4);
        for (uint256 i = 0; i < r.length; i++) r[i] = d[i + 4];
    }
}
