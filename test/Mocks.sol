// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GuardedLP, INPM} from "../src/GuardedLP.sol";

contract MockToken {
    string public name; uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, uint8 d) { name = n; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function burn(address from, uint256 a) external { balanceOf[from] -= a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "allowance"); allowance[f][msg.sender] = al - a; }
        require(balanceOf[f] >= a, "balance"); balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// Kyber-shaped router: swap(SwapExecutionParams) only; pulls srcToken from msg.sender, pays dstToken at a fixed rate
/// to dstReceiver (or to `payTo` when a test wants to misdirect the output).
contract MockRouter {
    uint256 public rateNum = 1; uint256 public rateDen = 1;   // out = in * num / den
    address public payTo; bool public pullLess; address public base;   // base = the USDC side; the other direction is the inverse rate
    address public executor;
    constructor() { executor = address(new Executor()); }
    function set(uint256 n, uint256 d) external { rateNum = n; rateDen = d; }
    function setPayTo(address a) external { payTo = a; }
    function setBase(address a) external { base = a; }
    function setPullLess(bool b) external { pullLess = b; }
    function swap(GuardedLP.SwapExecutionParams calldata p) external payable returns (uint256, uint256) {
        GuardedLP.SwapDescriptionV2 memory d = p.desc;
        uint256 take = pullLess ? d.amount / 2 : d.amount;
        MockToken(d.srcToken).transferFrom(msg.sender, address(this), take);
        uint256 out = d.srcToken == base ? take * rateNum / rateDen : take * rateDen / rateNum;
        address to = payTo != address(0) ? payTo : d.dstReceiver;
        MockToken(d.dstToken).mint(to, out);
        return (out, 0);
    }
}
contract Executor {}

/// Minimal Uniswap-V3-position-manager stand-in: liquidity = amount0 + amount1 (scaled), proportional withdrawals,
/// fees injected by the test, operator approvals as in ERC-721.
contract MockNPM {
    struct P { address token0; address token1; uint24 fee; int24 tl; int24 tu; uint128 liquidity; uint256 owed0; uint256 owed1; uint256 held0; uint256 held1; }
    mapping(uint256 => P) public pos;
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    uint256 public next = 1;
    uint256 public take0Bps = 10000; uint256 public take1Bps = 10000;   // share of the desired amounts the pool actually takes
    function setTake(uint256 b0, uint256 b1) external { take0Bps = b0; take1Bps = b1; }
    function setApprovalForAll(address op, bool ok) external { isApprovedForAll[msg.sender][op] = ok; }
    function _auth(uint256 id) internal view { address o = ownerOf[id]; require(msg.sender == o || isApprovedForAll[o][msg.sender], "Not approved"); }
    function positions(uint256 id) external view returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128) {
        P memory p = pos[id];
        return (0, address(0), p.token0, p.token1, p.fee, p.tl, p.tu, p.liquidity, 0, 0, uint128(p.owed0), uint128(p.owed1));
    }
    function mint(INPM.MintParams calldata m) external payable returns (uint256 id, uint128 liq, uint256 a0, uint256 a1) {
        a0 = m.amount0Desired * take0Bps / 10000; a1 = m.amount1Desired * take1Bps / 10000;
        require(a0 >= m.amount0Min && a1 >= m.amount1Min, "Price slippage check");
        if (a0 > 0) MockToken(m.token0).transferFrom(msg.sender, address(this), a0);
        if (a1 > 0) MockToken(m.token1).transferFrom(msg.sender, address(this), a1);
        id = next++; liq = uint128(a0 + a1);
        pos[id] = P(m.token0, m.token1, m.fee, m.tickLower, m.tickUpper, liq, 0, 0, a0, a1);
        ownerOf[id] = m.recipient;
    }
    function increaseLiquidity(INPM.IncreaseLiquidityParams calldata m) external payable returns (uint128 liq, uint256 a0, uint256 a1) {
        P storage p = pos[m.tokenId];
        a0 = m.amount0Desired * take0Bps / 10000; a1 = m.amount1Desired * take1Bps / 10000;
        if (a0 > 0) MockToken(p.token0).transferFrom(msg.sender, address(this), a0);
        if (a1 > 0) MockToken(p.token1).transferFrom(msg.sender, address(this), a1);
        liq = uint128(a0 + a1); p.liquidity += liq; p.held0 += a0; p.held1 += a1;
    }
    function decreaseLiquidity(INPM.DecreaseLiquidityParams calldata m) external payable returns (uint256 a0, uint256 a1) {
        _auth(m.tokenId);
        P storage p = pos[m.tokenId];
        require(m.liquidity <= p.liquidity, "liquidity");
        a0 = p.held0 * m.liquidity / p.liquidity; a1 = p.held1 * m.liquidity / p.liquidity;
        p.held0 -= a0; p.held1 -= a1; p.liquidity -= m.liquidity; p.owed0 += a0; p.owed1 += a1;
    }
    /// test hook: change what the pool holds for a position (impermanent loss, or a pool that returns less)
    function setHeld(uint256 id, uint256 h0, uint256 h1) external {
        P storage p = pos[id];
        if (h0 > p.held0) MockToken(p.token0).mint(address(this), h0 - p.held0);
        if (h1 > p.held1) MockToken(p.token1).mint(address(this), h1 - p.held1);
        p.held0 = h0; p.held1 = h1;
    }
    function addFees(uint256 id, uint256 f0, uint256 f1) external {
        P storage p = pos[id]; p.owed0 += f0; p.owed1 += f1;
        MockToken(p.token0).mint(address(this), f0); MockToken(p.token1).mint(address(this), f1);
    }
    function collect(INPM.CollectParams calldata m) external payable returns (uint256 a0, uint256 a1) {
        _auth(m.tokenId);
        P storage p = pos[m.tokenId];
        a0 = p.owed0 < m.amount0Max ? p.owed0 : m.amount0Max; a1 = p.owed1 < m.amount1Max ? p.owed1 : m.amount1Max;
        p.owed0 -= a0; p.owed1 -= a1;
        if (a0 > 0) MockToken(p.token0).transfer(m.recipient, a0);
        if (a1 > 0) MockToken(p.token1).transfer(m.recipient, a1);
    }
    function burn(uint256 id) external payable {
        _auth(id);
        P storage p = pos[id];
        require(p.liquidity == 0 && p.owed0 == 0 && p.owed1 == 0, "Not cleared");
        delete pos[id]; delete ownerOf[id];
    }
    function transferFrom(address from, address to, uint256 id) external { require(ownerOf[id] == from && msg.sender == from, "owner"); ownerOf[id] = to; }
}

/// CCTP v2 TokenMessengerV2 stand-in: pulls `amount` of burnToken from msg.sender and records every argument.
contract MockTokenMessenger {
    uint256 public amount; uint32 public destinationDomain; bytes32 public mintRecipient; address public burnToken;
    bytes32 public destinationCaller; uint256 public maxFee; uint32 public minFinalityThreshold; bytes public hookData; uint256 public calls;
    function depositForBurnWithHook(uint256 amount_, uint32 domain_, bytes32 mintRecipient_, address burnToken_, bytes32 caller_,
                                    uint256 maxFee_, uint32 finality_, bytes calldata hook_) external {
        MockToken(burnToken_).transferFrom(msg.sender, address(this), amount_);
        amount = amount_; destinationDomain = domain_; mintRecipient = mintRecipient_; burnToken = burnToken_;
        destinationCaller = caller_; maxFee = maxFee_; minFinalityThreshold = finality_; hookData = hook_; calls++;
    }
}
/// MetaMask-smart-account stand-in: has owner() and lets a test act as the account.
contract MockAccount {
    address public owner;
    constructor(address o) { owner = o; }
    function run(address target, bytes calldata data) external returns (bytes memory r) {
        bool ok; (ok, r) = target.call(data); require(ok, "account call failed");
    }
}

/// Uniswap-V3-factory stand-in: getPool(token0, token1, fee) from a settable map (either argument order).
contract MockFactory {
    mapping(bytes32 => address) public pools;
    function setPool(address a, address b, uint24 fee, address pool) external { pools[keccak256(abi.encode(a, b, fee))] = pool; pools[keccak256(abi.encode(b, a, fee))] = pool; }
    function getPool(address a, address b, uint24 fee) external view returns (address) { return pools[keccak256(abi.encode(a, b, fee))]; }
}
/// Pool stand-in: spot tick and a TWAP tick settable apart; observe([300,0]) yields cumulatives whose average is the
/// TWAP tick. A switch makes observe revert like Uniswap's "OLD" for a pool too young for the window.
contract MockPool {
    int24 public spot; int24 public twap; bool public young;
    /// sqrtPriceX96 reported by slot0; default = 2000 USDC (6 dec) per WETH (18 dec) with WETH as token0 (price1/0 = 2e-9)
    uint160 public sqrtP;
    constructor() { uint256 r = _isqrt(2000e6 * (uint256(1) << 192) / 1e18); sqrtP = uint160(r + r / 1e7); }   // +1e-7: the exact price floors one unit short
    function setSqrt(uint160 s) external { sqrtP = s; }
    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x; uint256 z = (x + 1) / 2;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        if (y * y < x) y += 1;   // round up so a fair valuation at spot never falls a unit short
    }
    function setSpot(int24 t) external { spot = t; }
    function setTwap(int24 t) external { twap = t; }
    function setYoung(bool y) external { young = y; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) { return (sqrtP, spot, 0, 1, 1, 0, true); }
    function observe(uint32[] calldata ago) external view returns (int56[] memory c, uint160[] memory s) {
        require(!young, "OLD");
        c = new int56[](ago.length); s = new uint160[](ago.length);
        // cumulative(now - ago) = twap * (T - ago) for an arbitrary T = 10_000: the average over [300, 0] is exactly twap
        for (uint256 i = 0; i < ago.length; i++) c[i] = int56(twap) * (10_000 - int56(uint56(ago[i])));
    }
}
