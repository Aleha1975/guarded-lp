// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardedLP
/// @notice A one-purpose gate between a client's own account and two venues: the Uniswap V3 position manager (NPM)
///         and the KyberSwap aggregator router. The account grants its executor the right to call THIS contract and
///         nothing else. Every token the gate moves ends up on the calling account: swaps are paid to the caller,
///         positions are minted to the caller, fees and withdrawn liquidity are collected to the caller. No owner, no
///         upgrade, no funds kept between calls. Anyone may call it; it can only ever pay the caller (or, for the exit
///         key, the account it acts for).
///
///         Why a gate and not ten delegations: a MetaMask delegation pins a recipient or a spender with one fixed calldata
///         word, and several such pins AND together, so every pinned value needed its own signature. Here the pins live
///         in code, so the client signs ONE delegation: targets [this], methods [the functions below], no ETH.
///
///         Guards on top of the recipient rule, because an executor key that is stolen could still trade badly:
///         1. Allowlist. A pool side that is not USDC must be an allowed token. The guardian proposes a token and it
///            becomes usable after TOKEN_DELAY; the exit key allows at once; either revokes at once. Without this a thief
///            would mint the account's USDC into a pool against a token he controls and buy the USDC out of it.
///         2. Loss budget, in USDC. Every buy and every USDC put into a position is recorded at cost. A sale that returns
///            less USDC than the cost of the tokens it gives up is a LOSS; losses per account must stay within BUDGET_BPS
///            of the account's value at cost (its USDC plus the cost it has out), refilling linearly over REFILL. USDC that
///            a position returns repays that position's cost first and then the paired token's cost, so income lowers the
///            floor and a sale at or above cost never touches the budget.
///         3. Only the lot. A sale covers at most the tokens this gate saw bought for the account (plus what its positions
///            returned); tokens that reached the account any other way are the owner's to sell directly. Positions are
///            only the ones this gate minted, and only while the account still owns them.
///         4. Rate limits per account and fixed hour window: operations, USDC into buys and positions, USDC out of sales.
///         5. Two keys kept off the executor's machine. The GUARDIAN pauses the executor's buys, sales and mints for at
///            most PAUSE_MAX, then a day of cooldown; it cannot move funds. Taking liquidity and fees back to the account is
///            never paused. The EXIT key (operator's cold key) can reset an account's loss budget, allow or revoke tokens,
///            replace the guardian, and run exit(): withdraw a position and sell to USDC on the account itself, outside the
///            budget and the limits, for the day the executor key is known to be compromised.
///         6. Only this call's funds. Balances are measured as deltas around every outside call; nothing sent to this
///            contract outside a call is swept or counted. The router calldata is decoded and must name the declared
///            tokens, the declared amount and this contract (or the caller) as receiver; its executor is pinned.
///         7. Residual, by design: a sale's srcReceivers are chosen by the aggregator and cannot be told from a planted
///            sink on chain -- bounded by the loss budget. A buy has no price reference beyond the hourly USDC budget. The
///            budget is relative to cost, not to the market. An account holding mostly USDC exposes its positions in full
///            to a stolen executor key within the budget; the bound is a share of the account, not of each position.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface INPM {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }
    struct IncreaseLiquidityParams { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct DecreaseLiquidityParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function mint(MintParams calldata) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata) external payable returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
    function positions(uint256 tokenId) external view returns (uint96 nonce, address operator, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1);
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract GuardedLP {
    // KyberSwap MetaAggregationRouterV2 calldata shape (decoded, never trusted blindly)
    struct SwapDescriptionV2 { address srcToken; address dstToken; address[] srcReceivers; uint256[] srcAmounts; address[] feeReceivers; uint256[] feeAmounts; address dstReceiver; uint256 amount; uint256 minReturnAmount; uint256 flags; bytes permit; }
    struct SwapExecutionParams { address callTarget; address approveTarget; bytes targetData; SwapDescriptionV2 desc; bytes clientData; }
    bytes4 private constant SEL_SWAP = 0xe21fd0e9;           // swap(SwapExecutionParams)
    bytes4 private constant SEL_OWNER = 0x8da5cb5b;          // owner()
    bytes4 private constant SEL_DEPOSIT_V3 = 0x7b939232;     // depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)
    uint256 private constant FLAGS_ALLOWED = 0x200;          // the one flag bit the router never dispatches on

    address public immutable ROUTER;
    address public immutable EXECUTOR;                // the router's aggregation executor the calldata must call
    address public immutable NPM;                     // Uniswap V3 NonfungiblePositionManager
    address public immutable USDC;                    // the account's unit of account; always allowed
    address public immutable EXIT_KEY;                // the operator's cold key
    address public immutable SPOKE;                   // Across SpokePool on this chain (hedge margin leaves through it)
    uint256 public immutable HEDGE_CHAIN_ID;          // Across destination for the hedge venue (HyperCore perps: 1337)
    address public immutable HEDGE_TOKEN;             // output token there (HyperCore USDC: 0x2100...0000)
    uint256 public constant BRIDGE_MAX_FEE_BPS = 100;  // a transfer may lose at most 1% on the way
    uint256 public constant BUDGET_BPS = 3000;        // losses may reach 30% of the account's value at cost...
    uint256 public constant REFILL = 7 days;          // ...and that room comes back linearly over a week
    uint256 public constant PAUSE_MAX = 7 days;
    uint256 public constant PAUSE_COOLDOWN = 1 days;
    uint256 public constant PENDING_TTL = 7 days;
    uint256 public constant TOKEN_DELAY = 1 days;     // a token the guardian proposes waits this long
    uint256 public constant MAX_RECEIVERS = 8;
    uint256 public constant MAX_UNLOCK = 64;
    uint256 public constant MAX_LOT = 1e40;
    uint256 public constant MAX_POSITIONS = 32;       // open positions per account this gate will track

    uint256 public immutable MAX_OPS_PER_HOUR;        // buys + sales + mints + increases per account and hour
    uint256 public immutable MAX_USDC_IN_PER_HOUR;    // USDC into buys and positions
    uint256 public immutable MAX_USDC_OUT_PER_HOUR;   // USDC out of sales

    struct Lot { uint256 tokens; uint256 usdcIn; }
    struct Loss { uint256 amount; uint64 at; }
    struct Window { uint64 hour; uint32 ops; uint256 usdcIn; uint256 usdcOut; }

    mapping(address => mapping(address => Lot)) public lot;    // account => token => what the gate bought, at cost
    mapping(address => uint256) public costOf;                 // account => USDC out at cost (lots + positions)
    mapping(address => Loss) public loss;                      // account => losses booked, decaying
    mapping(address => Window) private window_;
    mapping(address => uint256) public allowedFrom;            // token => timestamp it becomes usable (0 = not allowed)
    mapping(uint256 => address) public posOwner;               // tokenId => account the gate minted it for
    mapping(uint256 => uint256) public posUsdc;                // tokenId => USDC parked in it, at cost
    mapping(address => uint256[]) private positions_;          // account => tokenIds this gate tracks
    address public guardian;
    address public pendingGuardian;
    uint256 public pendingAt;
    uint256 public pausedAt;
    uint256 public pauseEndedAt;
    uint256 private _lock;

    event Bought(address indexed account, address indexed token, uint256 usdcIn, uint256 tokensOut);
    event Sold(address indexed account, address indexed token, uint256 tokensIn, uint256 usdcOut, uint256 lossAdded, bool exit);
    event Minted(address indexed account, uint256 indexed tokenId, address token0, address token1, uint256 amount0, uint256 amount1);
    event Increased(address indexed account, uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Decreased(address indexed account, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1, bool exit);
    event Collected(address indexed account, uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Burned(address indexed account, uint256 indexed tokenId);
    event TokenAllowed(address indexed token, uint256 from, address by);
    event TokenRevoked(address indexed token, address by);
    event Unlocked(address indexed account, uint256 lossCleared);
    event Paused(bool paused);
    event GuardianProposed(address indexed current, address indexed proposed);
    event GuardianChanged(address indexed previous, address indexed current);
    event PaidOut(address indexed account, address indexed to, address token, uint256 amount);
    event HedgeFunded(address indexed account, address indexed to, uint256 usdcIn, uint256 outputAmount);

    error Reentrancy();
    error ZeroAmount();
    error MinOutZero();
    error BelowMinOut(uint256 got, uint256 minOut);
    error BudgetExceeded(uint256 lossAfter, uint256 budget);
    error NotInLot(uint256 lot, uint256 asked);
    error NotAllowed(address token);
    error NotYours(uint256 tokenId);
    error RouterFailed(bytes reason);
    error TransferFailed();
    error IsPaused();
    error PauseCooldown();
    error NotGuardian();
    error NotExitKey();
    error BadGuardian();
    error RateLimited();
    error BadRoute();
    error NotAContract();
    error TooLarge();
    error TooMany();
    error NotPendingGuardian();
    error NoBeneficiary();
    error BridgeFee();
    error BridgeFailed(bytes reason);

    struct Venues { address router; address executor; address npm; address usdc; address spoke; uint256 hedgeChainId; address hedgeToken; }

    constructor(Venues memory v, address guardian_, address exitKey,
                uint256 maxOpsPerHour, uint256 maxUsdcInPerHour, uint256 maxUsdcOutPerHour) {
        if (v.router.code.length == 0 || v.executor.code.length == 0 || v.npm.code.length == 0 || v.usdc.code.length == 0 || v.spoke.code.length == 0) revert NotAContract();
        if (v.hedgeChainId == 0 || v.hedgeToken == address(0)) revert ZeroAmount();
        SPOKE = v.spoke; HEDGE_CHAIN_ID = v.hedgeChainId; HEDGE_TOKEN = v.hedgeToken;
        if (guardian_ == address(0) || guardian_ == address(this) || exitKey == address(0) || exitKey == address(this)) revert BadGuardian();
        if (maxOpsPerHour == 0 || maxUsdcInPerHour == 0 || maxUsdcOutPerHour == 0) revert ZeroAmount();
        ROUTER = v.router; EXECUTOR = v.executor; NPM = v.npm; USDC = v.usdc; guardian = guardian_; EXIT_KEY = exitKey;
        MAX_OPS_PER_HOUR = maxOpsPerHour; MAX_USDC_IN_PER_HOUR = maxUsdcInPerHour; MAX_USDC_OUT_PER_HOUR = maxUsdcOutPerHour;
    }

    modifier lock() { if (_lock != 0) revert Reentrancy(); _lock = 1; _; _lock = 0; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }
    modifier onlyExit() { if (msg.sender != EXIT_KEY) revert NotExitKey(); _; }

    // ---------------------------------------------------------------- keys
    function paused() public view returns (bool) { return pausedAt != 0 && block.timestamp < pausedAt + PAUSE_MAX; }

    function setPaused(bool p) external lock onlyGuardian {
        if (p) {
            if (paused()) return;
            if (pausedAt != 0 && block.timestamp < pausedAt + PAUSE_MAX + PAUSE_COOLDOWN) revert PauseCooldown();
            if (pauseEndedAt != 0 && block.timestamp < pauseEndedAt + PAUSE_COOLDOWN) revert PauseCooldown();
            pausedAt = block.timestamp;
        } else {
            if (!paused()) return;
            pausedAt = 0; pauseEndedAt = block.timestamp;
        }
        emit Paused(p);
    }
    function replaceGuardian(address next) external lock onlyExit {
        if (next == address(0) || next == address(this)) revert BadGuardian();
        emit GuardianChanged(guardian, next); guardian = next; pendingGuardian = address(0);
    }
    function proposeGuardian(address next) external lock onlyGuardian {
        if (next == address(0) || next == address(this)) revert BadGuardian();
        pendingGuardian = next; pendingAt = block.timestamp; emit GuardianProposed(guardian, next);
    }
    function acceptGuardian() external lock {
        if (msg.sender != pendingGuardian || block.timestamp > pendingAt + PENDING_TTL) revert NotPendingGuardian();
        emit GuardianChanged(guardian, msg.sender); guardian = msg.sender; pendingGuardian = address(0);
    }
    /// @notice The exit key clears booked losses after a crash that was the market and not a theft.
    function unlock(address[] calldata accounts) external lock onlyExit {
        if (accounts.length > MAX_UNLOCK) revert TooMany();
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 cleared = _decayed(accounts[i]);
            delete loss[accounts[i]];
            emit Unlocked(accounts[i], cleared);
        }
    }
    /// @notice Guardian: usable after TOKEN_DELAY. Exit key: usable at once. Neither can shorten a running delay.
    function allowToken(address token) external lock {
        if (token.code.length == 0) revert NotAContract();
        uint256 from;
        if (msg.sender == EXIT_KEY) from = block.timestamp;
        else if (msg.sender == guardian) { if (allowedFrom[token] != 0) return; from = block.timestamp + TOKEN_DELAY; }
        else revert NotGuardian();
        allowedFrom[token] = from; emit TokenAllowed(token, from, msg.sender);
    }
    function revokeToken(address token) external lock {
        if (msg.sender != EXIT_KEY && msg.sender != guardian) revert NotGuardian();
        allowedFrom[token] = 0; emit TokenRevoked(token, msg.sender);
    }
    function allowed(address token) public view returns (bool) {
        return token == USDC || (allowedFrom[token] != 0 && block.timestamp >= allowedFrom[token]);
    }

    // ---------------------------------------------------------------- limits and budget
    function _window(address account) private returns (Window storage w) {
        w = window_[account];
        uint64 h = uint64(block.timestamp / 1 hours);
        if (w.hour != h) { w.hour = h; w.ops = 0; w.usdcIn = 0; w.usdcOut = 0; }
    }
    function _countOp(address account) private { Window storage w = _window(account); if (w.ops + 1 > MAX_OPS_PER_HOUR) revert RateLimited(); w.ops += 1; }
    function _countIn(address account, uint256 usdc) private { Window storage w = _window(account); if (w.usdcIn + usdc > MAX_USDC_IN_PER_HOUR) revert RateLimited(); w.usdcIn += usdc; }
    function _countOut(address account, uint256 usdc) private { Window storage w = _window(account); if (w.usdcOut + usdc > MAX_USDC_OUT_PER_HOUR) revert RateLimited(); w.usdcOut += usdc; }

    function _ceil(uint256 a, uint256 b) private pure returns (uint256) { return (a + b - 1) / b; }
    /// @dev Value at cost: the USDC the account holds plus the USDC the gate has out for it (lots and positions).
    function _base(address account) private view returns (uint256) { return costOf[account] + IERC20(USDC).balanceOf(account); }
    function _budget(address account) private view returns (uint256) { return _base(account) * BUDGET_BPS / 10000; }
    function _decayed(address account) private view returns (uint256) {
        Loss memory l = loss[account];
        if (l.amount == 0) return 0;
        uint256 age = block.timestamp - l.at;
        if (age >= REFILL) return 0;
        return l.amount - l.amount * age / REFILL;
    }
    function budgetOf(address account) external view returns (uint256 lost, uint256 budget) { return (_decayed(account), _budget(account)); }

    /// @dev The lot never exceeds what the account holds: tokens the owner moved out leave it pro rata, as if sold at cost.
    function _trim(address account, address token) private returns (Lot storage b) {
        b = lot[account][token];
        if (b.tokens == 0) return b;
        (bool ok, uint256 bal) = _balanceOf(token, account);
        if (!ok || bal >= b.tokens) return b;                      // an unreadable balance keeps the last known lot
        uint256 keep = _ceil(b.usdcIn * bal, b.tokens);
        if (keep > b.usdcIn) keep = b.usdcIn;
        costOf[account] -= (b.usdcIn - keep);
        b.usdcIn = keep; b.tokens = bal;
    }

    // ---------------------------------------------------------------- swaps
    function _checkRoute(bytes calldata routerData, address tokenIn, address tokenOut, uint256 amount, uint256 minOut) private view {
        if (routerData.length < 4 || bytes4(routerData[:4]) != SEL_SWAP) revert BadRoute();
        SwapExecutionParams memory p = abi.decode(routerData[4:], (SwapExecutionParams)); SwapDescriptionV2 memory d = p.desc;
        if (p.callTarget != EXECUTOR) revert BadRoute();
        if (p.approveTarget != address(0) && p.approveTarget != EXECUTOR) revert BadRoute();
        if (d.flags & ~FLAGS_ALLOWED != 0) revert BadRoute();
        if (d.dstReceiver != address(this)) revert BadRoute();                        // paid here, forwarded after settlement
        if (d.feeReceivers.length != 0 || d.feeAmounts.length != 0) revert BadRoute();
        if (d.permit.length != 0) revert BadRoute();
        if (d.srcToken != tokenIn || d.dstToken != tokenOut) revert BadRoute();
        if (d.amount != amount) revert BadRoute();
        if (d.minReturnAmount < minOut) revert BadRoute();
        if (d.srcReceivers.length != d.srcAmounts.length || d.srcReceivers.length > MAX_RECEIVERS) revert BadRoute();
        uint256 sum;
        for (uint256 i = 0; i < d.srcReceivers.length; i++) {
            address r = d.srcReceivers[i];
            if (r.code.length == 0 || r == msg.sender || r == address(this) || r == tokenIn || r == tokenOut) revert BadRoute();
            sum += d.srcAmounts[i];
        }
        if (sum > amount) revert BadRoute();
    }

    /// @notice Spend `usdcIn` of the caller's USDC on `token` through the router. Output and unspent USDC go to the caller.
    function buy(address token, uint256 usdcIn, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (paused()) revert IsPaused();
        if (usdcIn == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token == USDC || !allowed(token)) revert NotAllowed(token);
        _countOp(msg.sender);
        Lot storage b = _trim(msg.sender, token);
        uint256 usdcBase = IERC20(USDC).balanceOf(address(this));
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        uint256 got = _pull(USDC, msg.sender, usdcIn);
        _checkRoute(routerData, USDC, token, got, minOut);
        (bool okB, uint256 before) = _balanceOf(token, msg.sender);
        if (!okB) revert BelowMinOut(0, minOut);
        _approveForRouter(USDC, got);
        _callRouter(routerData);
        _approveSoft(USDC, ROUTER, 0);
        _sweep(token, tokBase, msg.sender);
        (bool okA, uint256 after_) = _balanceOf(token, msg.sender);
        out = okA && after_ > before ? after_ - before : 0;
        if (out < minOut) revert BelowMinOut(out, minOut);
        uint256 left = IERC20(USDC).balanceOf(address(this)) - usdcBase;     // unspent input, returned last
        if (left > got) left = got;
        uint256 spent = got - left;
        if (spent == 0) revert ZeroAmount();
        _countIn(msg.sender, spent);
        b.usdcIn += spent; b.tokens += out; costOf[msg.sender] += spent;
        if (b.tokens > MAX_LOT) revert TooLarge();
        emit Bought(msg.sender, token, spent, out);
        if (left > 0) _send(USDC, msg.sender, left);
    }

    /// @notice Sell `amount` of `token` (at most the lot) for USDC through the router, within the loss budget.
    function sell(address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock returns (uint256 out) {
        if (paused()) revert IsPaused();
        _countOp(msg.sender);
        return _sale(msg.sender, token, amount, minOut, routerData, false);
    }
    /// @notice Exit key: sell on behalf of `account`, paid to `account`, outside the budget and the limits.
    function exitSell(address account, address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock onlyExit returns (uint256 out) {
        return _sale(account, token, amount, minOut, routerData, true);
    }

    struct SaleRun { uint256 sold; uint256 leftTok; uint256 out; }

    function _sale(address account, address token, uint256 amount, uint256 minOut, bytes calldata routerData, bool isExit) private returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token == USDC) revert NotAllowed(token);
        Lot storage b = _trim(account, token);
        if (amount > b.tokens) revert NotInLot(b.tokens, amount);
        SaleRun memory r = _swapOut(account, token, amount, minOut, routerData);
        out = r.out;
        uint256 lossAdded = _settleSale(account, b, amount, r, isExit);
        emit Sold(account, token, r.sold, r.out, lossAdded, isExit);
        if (r.leftTok > 0) _send(token, account, r.leftTok);
        _send(USDC, account, r.out);
    }
    /// @dev Pull the tokens from the account, run the checked route, measure what was sold and what came back.
    function _swapOut(address account, address token, uint256 amount, uint256 minOut, bytes calldata routerData) private returns (SaleRun memory r) {
        uint256 usdcBase = IERC20(USDC).balanceOf(address(this));
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        uint256 got = _pull(token, account, amount);
        _checkRoute(routerData, token, USDC, got, minOut);
        _approveForRouter(token, got);
        _callRouter(routerData);
        _approveSoft(token, ROUTER, 0);
        r.leftTok = IERC20(token).balanceOf(address(this)) - tokBase;     // what the route did not take goes back
        if (r.leftTok > got) r.leftTok = got;
        r.sold = got - r.leftTok;
        if (r.sold == 0) revert ZeroAmount();
        r.out = IERC20(USDC).balanceOf(address(this)) - usdcBase;
        if (r.out < minOut) revert BelowMinOut(r.out, minOut);
    }
    /// @dev Settle against cost, pro rata to the tokens given up; book the loss and check the budget unless exiting.
    function _settleSale(address account, Lot storage b, uint256 amount, SaleRun memory r, bool isExit) private returns (uint256 lossAdded) {
        amount;                                                            // the lot settles on what the route actually took
        uint256 budget = _budget(account);                                 // value at cost as the sale starts, before this sale moves it
        uint256 gone = r.sold < b.tokens ? r.sold : b.tokens;
        uint256 costPart = _ceil(b.usdcIn * gone, b.tokens);
        if (costPart > b.usdcIn) costPart = b.usdcIn;
        b.tokens -= gone;                                                  // tokens the route left behind go back and stay in the lot
        b.usdcIn -= costPart; costOf[account] -= costPart;
        if (r.out < costPart) {
            lossAdded = costPart - r.out;
            uint256 lossAfter = _decayed(account) + lossAdded;
            if (!isExit && lossAfter > budget) revert BudgetExceeded(lossAfter, budget);
            loss[account] = Loss(lossAfter, uint64(block.timestamp));
        }
        if (!isExit) _countOut(account, r.out);
    }

    // ---------------------------------------------------------------- positions
    struct MintSpec { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; }
    struct AddSpec { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; }
    struct Pulled { uint256 got0; uint256 got1; }

    /// @notice Open a position in the caller's name from the caller's own tokens. Leftovers go back to the caller.
    function mint(MintSpec calldata m) external lock returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (paused()) revert IsPaused();
        if (!allowed(m.token0) || !allowed(m.token1)) revert NotAllowed(allowed(m.token0) ? m.token1 : m.token0);
        if (m.amount0Desired == 0 && m.amount1Desired == 0) revert ZeroAmount();
        if (positions_[msg.sender].length >= MAX_POSITIONS) revert TooMany();
        _countOp(msg.sender);
        Pulled memory g = _pullBoth(m.token0, m.token1, m.amount0Desired, m.amount1Desired);
        (tokenId, liquidity, amount0, amount1) = INPM(NPM).mint(INPM.MintParams(m.token0, m.token1, m.fee, m.tickLower, m.tickUpper,
            g.got0, g.got1, m.amount0Min, m.amount1Min, msg.sender, block.timestamp));
        if (INPM(NPM).ownerOf(tokenId) != msg.sender) revert NotYours(tokenId);
        posOwner[tokenId] = msg.sender; positions_[msg.sender].push(tokenId);
        _settleIn(m.token0, m.token1, g, tokenId, amount0, amount1);
        emit Minted(msg.sender, tokenId, m.token0, m.token1, amount0, amount1);
    }

    /// @notice Add the caller's tokens to a position this gate opened for the caller.
    function increase(AddSpec calldata a) external lock returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (paused()) revert IsPaused();
        if (posOwner[a.tokenId] != msg.sender || INPM(NPM).ownerOf(a.tokenId) != msg.sender) revert NotYours(a.tokenId);
        if (a.amount0Desired == 0 && a.amount1Desired == 0) revert ZeroAmount();
        _countOp(msg.sender);
        (,, address token0, address token1,,,,,,,,) = INPM(NPM).positions(a.tokenId);
        if (!allowed(token0) || !allowed(token1)) revert NotAllowed(allowed(token0) ? token1 : token0);   // a revoked token blocks new money, not the way out
        Pulled memory g = _pullBoth(token0, token1, a.amount0Desired, a.amount1Desired);
        (liquidity, amount0, amount1) = INPM(NPM).increaseLiquidity(INPM.IncreaseLiquidityParams(a.tokenId, g.got0, g.got1, a.amount0Min, a.amount1Min, block.timestamp));
        _settleIn(token0, token1, g, a.tokenId, amount0, amount1);
        emit Increased(msg.sender, a.tokenId, amount0, amount1);
    }

    /// @dev Pull what the caller offers and let the manager take from it.
    function _pullBoth(address token0, address token1, uint256 want0, uint256 want1) private returns (Pulled memory g) {
        g.got0 = want0 > 0 ? _pull(token0, msg.sender, want0) : 0;
        g.got1 = want1 > 0 ? _pull(token1, msg.sender, want1) : 0;
        if (g.got0 > 0) _approveFor(token0, NPM, g.got0);
        if (g.got1 > 0) _approveFor(token1, NPM, g.got1);
    }
    /// @dev After the manager took its share: approvals back to zero, books updated, leftovers returned to the caller.
    function _settleIn(address token0, address token1, Pulled memory g, uint256 tokenId, uint256 used0, uint256 used1) private {
        if (g.got0 > 0) _approveSoft(token0, NPM, 0);
        if (g.got1 > 0) _approveSoft(token1, NPM, 0);
        if (used0 > g.got0 || used1 > g.got1) revert TransferFailed();
        _bookIn(msg.sender, tokenId, token0, used0);
        _bookIn(msg.sender, tokenId, token1, used1);
        if (g.got0 > used0) _send(token0, msg.sender, g.got0 - used0);
        if (g.got1 > used1) _send(token1, msg.sender, g.got1 - used1);
    }

    /// @notice Take `liquidity` out of the caller's position and collect everything owed to the caller. Never paused.
    function decrease(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min) external lock returns (uint256 amount0, uint256 amount1) {
        return _decrease(msg.sender, tokenId, liquidity, amount0Min, amount1Min, false);
    }
    /// @notice Exit key: withdraw a position in full to `account`.
    function exitDecrease(address account, uint256 tokenId, uint256 amount0Min, uint256 amount1Min) external lock onlyExit returns (uint256 amount0, uint256 amount1) {
        (,,,,,,, uint128 liq,,,,) = INPM(NPM).positions(tokenId);
        return _decrease(account, tokenId, liq, amount0Min, amount1Min, true);
    }
    /// @notice Collect the fees owed to the caller's position. Never paused.
    function collect(uint256 tokenId) external lock returns (uint256 amount0, uint256 amount1) {
        if (posOwner[tokenId] != msg.sender || INPM(NPM).ownerOf(tokenId) != msg.sender) revert NotYours(tokenId);
        (,, address token0, address token1,,,,,,,,) = INPM(NPM).positions(tokenId);
        (amount0, amount1) = INPM(NPM).collect(INPM.CollectParams(tokenId, msg.sender, type(uint128).max, type(uint128).max));
        _bookOut(msg.sender, tokenId, token0, token1, amount0, amount1);
        emit Collected(msg.sender, tokenId, amount0, amount1);
    }
    /// @notice Burn an emptied position and forget it.
    function burn(uint256 tokenId) external lock {
        if (posOwner[tokenId] != msg.sender || INPM(NPM).ownerOf(tokenId) != msg.sender) revert NotYours(tokenId);
        INPM(NPM).burn(tokenId);                                  // the manager refuses unless liquidity and owed are zero
        _forget(msg.sender, tokenId);
        emit Burned(msg.sender, tokenId);
    }

    function _decrease(address account, uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, bool isExit) private returns (uint256 amount0, uint256 amount1) {
        if (posOwner[tokenId] != account || INPM(NPM).ownerOf(tokenId) != account) revert NotYours(tokenId);
        (,, address token0, address token1,,,,,,,,) = INPM(NPM).positions(tokenId);
        if (liquidity > 0) INPM(NPM).decreaseLiquidity(INPM.DecreaseLiquidityParams(tokenId, liquidity, amount0Min, amount1Min, block.timestamp));
        (amount0, amount1) = INPM(NPM).collect(INPM.CollectParams(tokenId, account, type(uint128).max, type(uint128).max));
        _bookOut(account, tokenId, token0, token1, amount0, amount1);
        emit Decreased(account, tokenId, liquidity, amount0, amount1, isExit);
    }

    /// @dev Money into a position: USDC is parked on the position at cost; another token leaves the lot but keeps its cost.
    function _bookIn(address account, uint256 tokenId, address token, uint256 amount) private {
        if (amount == 0) return;
        if (token == USDC) { posUsdc[tokenId] += amount; costOf[account] += amount; _countIn(account, amount); return; }
        Lot storage b = lot[account][token];
        b.tokens = b.tokens > amount ? b.tokens - amount : 0;
    }
    /// @dev Money out of a position, paid to the account: USDC repays the position's cost, then the paired token's cost;
    ///      another token joins its lot at zero added cost (its cost never left).
    function _bookOut(address account, uint256 tokenId, address token0, address token1, uint256 amount0, uint256 amount1) private {
        address other = token0 == USDC ? token1 : token0;
        uint256 usdc = token0 == USDC ? amount0 : (token1 == USDC ? amount1 : 0);
        if (usdc > 0) {
            uint256 repay = usdc < posUsdc[tokenId] ? usdc : posUsdc[tokenId];
            posUsdc[tokenId] -= repay; costOf[account] -= repay;
            uint256 extra = usdc - repay;
            if (extra > 0 && other != USDC) {
                Lot storage ob = lot[account][other];
                uint256 cut = extra < ob.usdcIn ? extra : ob.usdcIn;
                ob.usdcIn -= cut; costOf[account] -= cut;
            }
        }
        if (token0 != USDC && amount0 > 0) { Lot storage b0 = lot[account][token0]; b0.tokens += amount0; if (b0.tokens > MAX_LOT) revert TooLarge(); }
        if (token1 != USDC && amount1 > 0) { Lot storage b1 = lot[account][token1]; b1.tokens += amount1; if (b1.tokens > MAX_LOT) revert TooLarge(); }
    }
    function _forget(address account, uint256 tokenId) private {
        uint256 parked = posUsdc[tokenId];
        if (parked > 0) { posUsdc[tokenId] = 0; costOf[account] -= parked; }   // a burned position has returned everything it will
        delete posOwner[tokenId];
        uint256[] storage arr = positions_[account];
        for (uint256 i = 0; i < arr.length; i++) if (arr[i] == tokenId) { arr[i] = arr[arr.length - 1]; arr.pop(); break; }
    }

    // ---------------------------------------------------------------- views
    function positionsOf(address account) external view returns (uint256[] memory) { return positions_[account]; }
    function lotOf(address account, address token) external view returns (uint256 tokens, uint256 usdcIn) { Lot memory b = lot[account][token]; return (b.tokens, b.usdcIn); }

    // ---------------------------------------------------------------- money back to the owner
    /// @dev The account is a MetaMask smart account whose `owner()` is the client's wallet. That is the only place
    ///      `payout` and `fundHedge` can send to, so neither needs a pinned recipient in the delegation.
    function beneficiaryOf(address account) public view returns (address to) {
        (bool ok, bytes memory r) = account.staticcall(abi.encodeWithSelector(SEL_OWNER));
        if (!ok || r.length < 32) revert NoBeneficiary();
        to = abi.decode(r, (address));
        if (to == address(0) || to == account || to == address(this)) revert NoBeneficiary();
    }
    /// @notice Move `amount` of `token` from the calling account to its owner's wallet. Any token: it is the owner's
    ///         money going to the owner. Never paused, no limits -- this is the way out.
    function payout(address token, uint256 amount) external lock {
        if (amount == 0) revert ZeroAmount();
        address to = beneficiaryOf(msg.sender);
        uint256 got = _pull(token, msg.sender, amount);
        _send(token, to, got);
        emit PaidOut(msg.sender, to, token, got);
    }
    /// @notice Send USDC from the calling account to the owner's account on the hedge venue through Across. The
    ///         depositor is the owner's wallet (an unfilled deposit refunds there), the recipient is the same wallet
    ///         on HEDGE_CHAIN_ID. Fee capped at BRIDGE_MAX_FEE_BPS; counted against the hourly USDC-out window.
    struct BridgeQuote { uint256 outputAmount; address exclusiveRelayer; uint32 quoteTimestamp; uint32 fillDeadline; uint32 exclusivityDeadline; }
    function fundHedge(uint256 usdcIn, BridgeQuote calldata q) external lock {
        if (usdcIn == 0) revert ZeroAmount();
        if (q.outputAmount + usdcIn * BRIDGE_MAX_FEE_BPS / 10000 < usdcIn) revert BridgeFee();
        address to = beneficiaryOf(msg.sender);
        _countOp(msg.sender); _countOut(msg.sender, usdcIn);
        uint256 got = _pull(USDC, msg.sender, usdcIn);
        _approveFor(USDC, SPOKE, got);
        _deposit(to, got, q);
        _approveSoft(USDC, SPOKE, 0);
        emit HedgeFunded(msg.sender, to, got, q.outputAmount);
    }
    function _deposit(address to, uint256 got, BridgeQuote calldata q) private {
        // depositV3 has 12 parameters, the last an empty `bytes`: head offset 12 words (0x180), then length 0.
        bytes memory head = abi.encode(to, to, USDC, HEDGE_TOKEN, got, q.outputAmount);
        bytes memory tail = abi.encode(HEDGE_CHAIN_ID, q.exclusiveRelayer, q.quoteTimestamp, q.fillDeadline, q.exclusivityDeadline, uint256(0x180), uint256(0));
        (bool ok, bytes memory err) = SPOKE.call(bytes.concat(SEL_DEPOSIT_V3, head, tail));
        if (!ok) revert BridgeFailed(err);
    }

    // ---------------------------------------------------------------- plumbing
    function _callRouter(bytes calldata data) private {
        (bool ok, bytes memory err) = ROUTER.call(data);
        if (!ok) revert RouterFailed(err);
    }
    /// @dev What this call added to the contract's `token` balance (above `base`) goes to `to`.
    function _sweep(address token, uint256 base, address to) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 held = bal > base ? bal - base : 0;
        if (held > 0) _send(token, to, held);
    }
    function _balanceOf(address token, address who) private view returns (bool ok, uint256 bal) {
        (bool s_, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (!s_ || r.length < 32) return (false, 0);
        return (true, abi.decode(r, (uint256)));
    }
    function _pull(address token, address from, uint256 amount) private returns (uint256 got) {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
        got = IERC20(token).balanceOf(address(this)) - before;
        if (got == 0) revert ZeroAmount();
    }
    function _send(address token, address to, uint256 amount) private {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }
    function _approveTry(address token, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        return ok && (r.length == 0 || abi.decode(r, (bool)));
    }
    function _approveFor(address token, address spender, uint256 amount) private {
        if (_approveTry(token, spender, amount)) return;
        _approveSoft(token, spender, 0);
        if (!_approveTry(token, spender, amount)) revert TransferFailed();
    }
    function _approveForRouter(address token, uint256 amount) private { _approveFor(token, ROUTER, amount); }
    function _approveSoft(address token, address spender, uint256 amount) private {
        (bool ok, ) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount)); ok;
    }
}
