// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GuardedLP v2
/// @notice A one-purpose gate between a client's own wallet and two venues: the Uniswap V3 position manager (NPM)
///         and the KyberSwap aggregator router. Funds never leave the client's wallet except into the client's own
///         position (minted to the wallet), through a checked swap paid back to the wallet, or to the wallet's own
///         account on the hedge venue. No owner, no upgrade, no funds kept between calls.
///
///         v2 account model (two confirmations for the client): the wallet sends ONE batch -- token approvals to
///         this gate, NPM.setApprovalForAll(this), and authorize(operator, cap) -- and from then on the operator (our
///         executor key) may call the functions below FOR that wallet. The wallet itself may always call them too,
///         and may revoke the operator at any time with authorize(address(0), 0).
///
///         Guards against a stolen operator key:
///         1. Allowlist. The pool's other side must be an allowed token (guardian proposes, usable after TOKEN_DELAY;
///            exit key allows at once; either revokes at once).
///         2. USDC pairs only, and only the lot. A position pairs USDC with one allowed token; the token side may only
///            take tokens this gate bought for the wallet (its lot), never other holdings (audit 1057 H-1, H-2, M-2).
///         3. Price sanity. Mint, increase and decrease require the pool's spot tick within MAX_TICK_DEV of its
///            TWAP_SECS time-weighted tick; a pool too young to answer that window is refused (audit 1057 H-1).
///         4. Cost follows the tokens. Every position carries the USDC cost put into it (USDC plus the cost share of
///            lot tokens). On withdrawal the returned USDC repays that cost first and the rest of the cost rides on the
///            returned tokens, so a later sale books the loss; a position that returns nothing books its cost as a loss
///            (audit 1057 M-1). Pool fees join at zero cost -- they are income paid by swappers.
///         5. Loss budget in USDC: losses on sales stay within BUDGET_BPS of the wallet's value at cost (capped by the
///            wallet's own cap), refilling over REFILL. Exit-key operations are outside it.
///         6. Caps: the operator can keep at most capOf[wallet] USDC at cost out (lots plus positions), plus hourly
///            limits on operations, USDC in and USDC out.
///         7. Keys off the executor's machine: the GUARDIAN pauses operator buys, sales, mints, increases and hedge
///            funding (max PAUSE_MAX, then cooldown); taking liquidity back is never paused. The EXIT key resets a
///            wallet's budget, allows/revokes tokens, replaces the guardian, and exits a wallet to USDC.
///         8. Residual by design: a sale's srcReceivers are chosen by the aggregator (bounded by the budget); a buy has
///            no price reference beyond the hourly USDC limit and the cap.
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
interface IFactory { function getPool(address, address, uint24) external view returns (address); }
interface IPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

contract GuardedLP {
    struct SwapDescriptionV2 { address srcToken; address dstToken; address[] srcReceivers; uint256[] srcAmounts; address[] feeReceivers; uint256[] feeAmounts; address dstReceiver; uint256 amount; uint256 minReturnAmount; uint256 flags; bytes permit; }
    struct SwapExecutionParams { address callTarget; address approveTarget; bytes targetData; SwapDescriptionV2 desc; bytes clientData; }
    bytes4 private constant SEL_SWAP = 0xe21fd0e9;
    bytes4 private constant SEL_OWNER = 0x8da5cb5b;
    bytes4 private constant SEL_DEPOSIT_V3 = 0x7b939232;
    uint256 private constant FLAGS_ALLOWED = 0x200;

    address public immutable ROUTER;
    address public immutable EXECUTOR;
    address public immutable NPM;
    address public immutable FACTORY;                 // the NPM's pool factory (price checks)
    address public immutable USDC;
    address public immutable EXIT_KEY;
    address public immutable SPOKE;
    uint256 public immutable HEDGE_CHAIN_ID;
    address public immutable HEDGE_TOKEN;
    uint8 public immutable HEDGE_DECIMALS;            // decimals of HEDGE_TOKEN, so the fee bound compares value
    uint256 public constant BRIDGE_MAX_FEE_BPS = 100;
    uint256 public constant BUDGET_BPS = 3000;
    uint256 public constant REFILL = 7 days;
    uint256 public constant PAUSE_MAX = 7 days;
    uint256 public constant PAUSE_COOLDOWN = 1 days;
    uint256 public constant PENDING_TTL = 7 days;
    uint256 public constant TOKEN_DELAY = 1 days;
    uint256 public constant MAX_RECEIVERS = 8;
    uint256 public constant MAX_UNLOCK = 64;
    uint256 public constant MAX_LOT = 1e40;
    uint256 public constant MAX_POSITIONS = 32;
    uint32 public constant TWAP_SECS = 300;
    int24 public constant MAX_TICK_DEV = 150;         // ~1.5%

    uint256 public immutable MAX_OPS_PER_HOUR;
    uint256 public immutable MAX_USDC_IN_PER_HOUR;
    uint256 public immutable MAX_USDC_OUT_PER_HOUR;

    struct Lot { uint256 tokens; uint256 usdcIn; }
    struct Loss { uint256 amount; uint64 at; }
    struct Window { uint64 hour; uint32 ops; uint256 usdcIn; uint256 usdcOut; }

    mapping(address => mapping(address => Lot)) public lot;
    mapping(address => uint256) public costOf;
    mapping(address => Loss) public loss;
    mapping(address => Window) private window_;
    mapping(address => uint256) public allowedFrom;
    mapping(uint256 => address) public posOwner;
    mapping(uint256 => uint256) public posCost;               // tokenId => USDC at cost carried by the position
    mapping(address => uint256[]) private positions_;
    mapping(address => address) public operatorOf;            // wallet => key allowed to act for it
    mapping(address => uint256) public capOf;                 // wallet => max USDC at cost the operator may keep out
    address public guardian;
    address public pendingGuardian;
    uint256 public pendingAt;
    uint256 public pausedAt;
    uint256 public pauseEndedAt;
    uint256 private _lock;

    event Authorized(address indexed account, address indexed operator, uint256 cap);
    event Bought(address indexed account, address indexed token, uint256 usdcIn, uint256 tokensOut);
    event Sold(address indexed account, address indexed token, uint256 tokensIn, uint256 usdcOut, uint256 lossAdded, bool exit);
    event Minted(address indexed account, uint256 indexed tokenId, address token0, address token1, uint256 amount0, uint256 amount1);
    event Increased(address indexed account, uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Decreased(address indexed account, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1, bool exit);
    event Collected(address indexed account, uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Burned(address indexed account, uint256 indexed tokenId, uint256 lossBooked);
    event Forgotten(address indexed account, uint256 indexed tokenId, uint256 lossBooked);
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
    error NotOperator();
    error CapExceeded(uint256 cost, uint256 cap);
    error NotUsdcPair();
    error BadPool();
    error PriceOff(int24 tick, int24 twap);
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
    error StillOwned(uint256 tokenId);

    struct Venues { address router; address executor; address npm; address factory; address usdc; address spoke; uint256 hedgeChainId; address hedgeToken; uint8 hedgeDecimals; }

    constructor(Venues memory v, address guardian_, address exitKey,
                uint256 maxOpsPerHour, uint256 maxUsdcInPerHour, uint256 maxUsdcOutPerHour) {
        if (v.router.code.length == 0 || v.executor.code.length == 0 || v.npm.code.length == 0 || v.factory.code.length == 0
            || v.usdc.code.length == 0 || v.spoke.code.length == 0) revert NotAContract();
        if (v.hedgeChainId == 0 || v.hedgeToken == address(0)) revert ZeroAmount();
        if (guardian_ == address(0) || guardian_ == address(this) || exitKey == address(0) || exitKey == address(this)) revert BadGuardian();
        if (maxOpsPerHour == 0 || maxUsdcInPerHour == 0 || maxUsdcOutPerHour == 0) revert ZeroAmount();
        ROUTER = v.router; EXECUTOR = v.executor; NPM = v.npm; FACTORY = v.factory; USDC = v.usdc;
        SPOKE = v.spoke; HEDGE_CHAIN_ID = v.hedgeChainId; HEDGE_TOKEN = v.hedgeToken; HEDGE_DECIMALS = v.hedgeDecimals;
        guardian = guardian_; EXIT_KEY = exitKey;
        MAX_OPS_PER_HOUR = maxOpsPerHour; MAX_USDC_IN_PER_HOUR = maxUsdcInPerHour; MAX_USDC_OUT_PER_HOUR = maxUsdcOutPerHour;
    }

    modifier lock() { _enter(); _; _lock = 0; }
    modifier onlyGuardian() { _onlyGuardian(); _; }
    modifier onlyExit() { _onlyExit(); _; }
    /// @dev The wallet itself, or the operator it authorized.
    modifier forAccount(address account) { _forAccount(account); _; }
    function _enter() private { if (_lock != 0) revert Reentrancy(); _lock = 1; }
    function _onlyGuardian() private view { if (msg.sender != guardian) revert NotGuardian(); }
    function _onlyExit() private view { if (msg.sender != EXIT_KEY) revert NotExitKey(); }
    function _forAccount(address account) private view {
        if (account == address(0) || (msg.sender != account && (operatorOf[account] == address(0) || msg.sender != operatorOf[account]))) revert NotOperator();
    }

    // ---------------------------------------------------------------- the wallet's own switch
    /// @notice Called by the wallet: let `operator` act for it, keeping at most `cap` USDC at cost out. Zero revokes.
    function authorize(address operator, uint256 cap) external lock {
        if (operator == msg.sender || operator == address(this)) revert NotOperator();
        operatorOf[msg.sender] = operator; capOf[msg.sender] = operator == address(0) ? 0 : cap;
        emit Authorized(msg.sender, operator, capOf[msg.sender]);
    }

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
        if (next == address(0) || next == address(this) || next == EXIT_KEY) revert BadGuardian();
        emit GuardianChanged(guardian, next); guardian = next; pendingGuardian = address(0);
    }
    function proposeGuardian(address next) external lock onlyGuardian {
        if (next == address(0) || next == address(this) || next == EXIT_KEY) revert BadGuardian();
        pendingGuardian = next; pendingAt = block.timestamp; emit GuardianProposed(guardian, next);
    }
    function acceptGuardian() external lock {
        if (msg.sender != pendingGuardian || block.timestamp > pendingAt + PENDING_TTL) revert NotPendingGuardian();
        emit GuardianChanged(guardian, msg.sender); guardian = msg.sender; pendingGuardian = address(0);
    }
    function unlock(address[] calldata accounts) external lock onlyExit {
        if (accounts.length > MAX_UNLOCK) revert TooMany();
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 cleared = _decayed(accounts[i]);
            delete loss[accounts[i]];
            emit Unlocked(accounts[i], cleared);
        }
    }
    /// @notice Guardian: a token becomes usable after TOKEN_DELAY and the guardian cannot shorten that. The exit key
    ///         allows at once, which also overrides a running guardian delay (audit 1057 L-3: by design).
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
    /// @dev The operator may not keep more than the wallet's cap out at cost. The wallet acting itself is not capped.
    function _checkCap(address account) private view {
        if (msg.sender != account && costOf[account] > capOf[account]) revert CapExceeded(costOf[account], capOf[account]);
    }

    function _ceil(uint256 a, uint256 b) private pure returns (uint256) { return (a + b - 1) / b; }
    /// @dev Value at cost: the wallet's USDC plus the gate's cost out for it, never above the wallet's cap when set.
    function _base(address account) private view returns (uint256 b) {
        b = costOf[account] + IERC20(USDC).balanceOf(account);
        uint256 cap = capOf[account];
        if (cap != 0 && b > cap) b = cap;
    }
    function _budget(address account) private view returns (uint256) { return _base(account) * BUDGET_BPS / 10000; }
    function _decayed(address account) private view returns (uint256) {
        Loss memory l = loss[account];
        if (l.amount == 0) return 0;
        uint256 age = block.timestamp - l.at;
        if (age >= REFILL) return 0;
        return l.amount - l.amount * age / REFILL;
    }
    function budgetOf(address account) external view returns (uint256 lost, uint256 budget) { return (_decayed(account), _budget(account)); }
    /// @dev Record a loss without enforcing the budget (used where refusing would block the way out).
    function _bookLoss(address account, uint256 amount) private {
        if (amount == 0) return;
        loss[account] = Loss(_decayed(account) + amount, uint64(block.timestamp));
    }

    function _trim(address account, address token) private returns (Lot storage b) {
        b = lot[account][token];
        if (b.tokens == 0) return b;
        (bool ok, uint256 bal) = _balanceOf(token, account);
        if (!ok || bal >= b.tokens) return b;
        uint256 keep = _ceil(b.usdcIn * bal, b.tokens);
        if (keep > b.usdcIn) keep = b.usdcIn;
        costOf[account] -= (b.usdcIn - keep);
        b.usdcIn = keep; b.tokens = bal;
    }

    // ---------------------------------------------------------------- swaps
    function _checkRoute(address account, bytes calldata routerData, address tokenIn, address tokenOut, uint256 amount, uint256 minOut) private view {
        if (routerData.length < 4 || bytes4(routerData[:4]) != SEL_SWAP) revert BadRoute();
        SwapExecutionParams memory p = abi.decode(routerData[4:], (SwapExecutionParams)); SwapDescriptionV2 memory d = p.desc;
        if (p.callTarget != EXECUTOR) revert BadRoute();
        if (p.approveTarget != address(0) && p.approveTarget != EXECUTOR) revert BadRoute();
        if (d.flags & ~FLAGS_ALLOWED != 0) revert BadRoute();
        if (d.dstReceiver != address(this)) revert BadRoute();
        if (d.feeReceivers.length != 0 || d.feeAmounts.length != 0) revert BadRoute();
        if (d.permit.length != 0) revert BadRoute();
        if (d.srcToken != tokenIn || d.dstToken != tokenOut) revert BadRoute();
        if (d.amount != amount) revert BadRoute();
        if (d.minReturnAmount < minOut) revert BadRoute();
        if (d.srcReceivers.length != d.srcAmounts.length || d.srcReceivers.length > MAX_RECEIVERS) revert BadRoute();
        uint256 sum;
        for (uint256 i = 0; i < d.srcReceivers.length; i++) {
            address r = d.srcReceivers[i];
            // neither the caller nor the wallet it acts for may be a receiver (audit 1057 L-4)
            if (r.code.length == 0 || r == msg.sender || r == account || r == address(this) || r == tokenIn || r == tokenOut) revert BadRoute();
            sum += d.srcAmounts[i];
        }
        if (sum > amount) revert BadRoute();
    }

    struct BuyRun { uint256 usdcBase; uint256 tokBase; uint256 got; uint256 before; }
    /// @dev The swap leg of a buy (kept apart from buy() for stack depth; behaviour unchanged).
    function _buyRun(address account, address token, uint256 usdcIn, uint256 minOut, bytes calldata routerData) private returns (uint256 out, uint256 spent, uint256 left) {
        BuyRun memory r;
        r.usdcBase = IERC20(USDC).balanceOf(address(this));
        r.tokBase = IERC20(token).balanceOf(address(this));
        r.got = _pull(USDC, account, usdcIn);
        _checkRoute(account, routerData, USDC, token, r.got, minOut);
        bool okB; (okB, r.before) = _balanceOf(token, account);
        if (!okB) revert BelowMinOut(0, minOut);
        _approveFor(USDC, ROUTER, r.got);
        _callRouter(routerData);
        _approveSoft(USDC, ROUTER, 0);
        _sweep(token, r.tokBase, account);
        (bool okA, uint256 after_) = _balanceOf(token, account);
        out = okA && after_ > r.before ? after_ - r.before : 0;
        if (out < minOut) revert BelowMinOut(out, minOut);
        left = IERC20(USDC).balanceOf(address(this)) - r.usdcBase;
        if (left > r.got) left = r.got;
        spent = r.got - left;
        if (spent == 0) revert ZeroAmount();
    }

    /// @notice Spend `usdcIn` of the wallet's USDC on `token`. Output and unspent USDC go to the wallet.
    function buy(address account, address token, uint256 usdcIn, uint256 minOut, bytes calldata routerData) external lock forAccount(account) returns (uint256 out) {
        if (paused()) revert IsPaused();
        if (usdcIn == 0) revert ZeroAmount();
        if (minOut == 0) revert MinOutZero();
        if (token == USDC || !allowed(token)) revert NotAllowed(token);
        _countOp(account);
        Lot storage b = _trim(account, token);
        uint256 spent; uint256 left;
        (out, spent, left) = _buyRun(account, token, usdcIn, minOut, routerData);
        _countIn(account, spent);
        b.usdcIn += spent; b.tokens += out; costOf[account] += spent;
        if (b.tokens > MAX_LOT) revert TooLarge();
        _checkCap(account);
        emit Bought(account, token, spent, out);
        if (left > 0) _send(USDC, account, left);
    }

    /// @notice Sell `amount` of `token` (at most the lot) for USDC to the wallet, within the loss budget.
    function sell(address account, address token, uint256 amount, uint256 minOut, bytes calldata routerData) external lock forAccount(account) returns (uint256 out) {
        if (paused()) revert IsPaused();
        _countOp(account);
        return _sale(account, token, amount, minOut, routerData, false);
    }
    /// @notice Exit key: sell for `account`, paid to `account`, outside the budget and the limits.
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
        uint256 lossAdded = _settleSale(account, b, r, isExit);
        emit Sold(account, token, r.sold, r.out, lossAdded, isExit);
        if (r.leftTok > 0) _send(token, account, r.leftTok);
        _send(USDC, account, r.out);
    }
    function _swapOut(address account, address token, uint256 amount, uint256 minOut, bytes calldata routerData) private returns (SaleRun memory r) {
        uint256 usdcBase = IERC20(USDC).balanceOf(address(this));
        uint256 tokBase = IERC20(token).balanceOf(address(this));
        uint256 got = _pull(token, account, amount);
        _checkRoute(account, routerData, token, USDC, got, minOut);
        _approveFor(token, ROUTER, got);
        _callRouter(routerData);
        _approveSoft(token, ROUTER, 0);
        r.leftTok = IERC20(token).balanceOf(address(this)) - tokBase;
        if (r.leftTok > got) r.leftTok = got;
        r.sold = got - r.leftTok;
        if (r.sold == 0) revert ZeroAmount();
        r.out = IERC20(USDC).balanceOf(address(this)) - usdcBase;
        if (r.out < minOut) revert BelowMinOut(r.out, minOut);
    }
    function _settleSale(address account, Lot storage b, SaleRun memory r, bool isExit) private returns (uint256 lossAdded) {
        uint256 budget = _budget(account);
        uint256 gone = r.sold < b.tokens ? r.sold : b.tokens;
        uint256 costPart = _ceil(b.usdcIn * gone, b.tokens);
        if (costPart > b.usdcIn) costPart = b.usdcIn;
        b.tokens -= gone;
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

    /// @dev The four fields of NPM.positions() the gate reads (one decode of the 12-value tuple, for code size).
    function _posInfo(uint256 tokenId) private view returns (address token0, address token1, uint24 fee, uint128 liquidity) {
        (,, token0, token1, fee,,, liquidity,,,,) = INPM(NPM).positions(tokenId);
    }
    /// @dev Spot tick within MAX_TICK_DEV of the TWAP_SECS average. observe() reverts for a pool that cannot answer the
    ///      window (too young or too few observations), so a pool created and priced in the same block is refused.
    function _checkPrice(address token0, address token1, uint24 fee) private view {
        address pool = IFactory(FACTORY).getPool(token0, token1, fee);
        if (pool == address(0) || pool.code.length == 0) revert BadPool();
        (, int24 tick,,,,,) = IPool(pool).slot0();
        uint32[] memory ago = new uint32[](2); ago[0] = TWAP_SECS; ago[1] = 0;
        (int56[] memory c,) = IPool(pool).observe(ago);
        int56 d = c[1] - c[0];
        int24 twap = int24(d / int56(uint56(TWAP_SECS)));
        if (d < 0 && (d % int56(uint56(TWAP_SECS)) != 0)) twap--;
        if (tick > twap + MAX_TICK_DEV || tick < twap - MAX_TICK_DEV) revert PriceOff(tick, twap);
    }
    /// @dev The pair must be USDC plus one allowed token.
    function _pair(address token0, address token1) private view returns (address other) {
        if (token0 == USDC) other = token1; else if (token1 == USDC) other = token0; else revert NotUsdcPair();
        if (other == USDC || !allowed(other)) revert NotAllowed(other);
    }

    /// @notice Open a position in the wallet's name: USDC from the wallet, the other side only from its lot.
    function mint(address account, MintSpec calldata m) external lock forAccount(account) returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (paused()) revert IsPaused();
        _pair(m.token0, m.token1);
        if (m.amount0Desired == 0 && m.amount1Desired == 0) revert ZeroAmount();
        if (positions_[account].length >= MAX_POSITIONS) revert TooMany();
        _checkPrice(m.token0, m.token1, m.fee);
        _countOp(account);
        Pulled memory g = _pullBoth(account, m.token0, m.token1, m.amount0Desired, m.amount1Desired);
        (tokenId, liquidity, amount0, amount1) = INPM(NPM).mint(INPM.MintParams(m.token0, m.token1, m.fee, m.tickLower, m.tickUpper,
            g.got0, g.got1, m.amount0Min, m.amount1Min, account, block.timestamp));
        if (INPM(NPM).ownerOf(tokenId) != account) revert NotYours(tokenId);
        posOwner[tokenId] = account; positions_[account].push(tokenId);
        _settleIn(account, m.token0, m.token1, g, tokenId, amount0, amount1);
        emit Minted(account, tokenId, m.token0, m.token1, amount0, amount1);
    }

    /// @notice Add to a position this gate opened for the wallet, under the same rules as mint.
    function increase(address account, AddSpec calldata a) external lock forAccount(account) returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (paused()) revert IsPaused();
        if (posOwner[a.tokenId] != account || INPM(NPM).ownerOf(a.tokenId) != account) revert NotYours(a.tokenId);
        if (a.amount0Desired == 0 && a.amount1Desired == 0) revert ZeroAmount();
        (address token0, address token1, uint24 fee,) = _posInfo(a.tokenId);
        _pair(token0, token1);
        _checkPrice(token0, token1, fee);
        _countOp(account);
        Pulled memory g = _pullBoth(account, token0, token1, a.amount0Desired, a.amount1Desired);
        (liquidity, amount0, amount1) = INPM(NPM).increaseLiquidity(INPM.IncreaseLiquidityParams(a.tokenId, g.got0, g.got1, a.amount0Min, a.amount1Min, block.timestamp));
        _settleIn(account, token0, token1, g, a.tokenId, amount0, amount1);
        emit Increased(account, a.tokenId, amount0, amount1);
    }

    /// @dev Pull what is offered: USDC from the wallet, the other token only up to the wallet's lot.
    function _pullBoth(address account, address token0, address token1, uint256 want0, uint256 want1) private returns (Pulled memory g) {
        if (token0 != USDC && want0 > 0) { Lot storage b0 = _trim(account, token0); if (want0 > b0.tokens) revert NotInLot(b0.tokens, want0); }
        if (token1 != USDC && want1 > 0) { Lot storage b1 = _trim(account, token1); if (want1 > b1.tokens) revert NotInLot(b1.tokens, want1); }
        g.got0 = want0 > 0 ? _pull(token0, account, want0) : 0;
        g.got1 = want1 > 0 ? _pull(token1, account, want1) : 0;
        if (g.got0 > 0) _approveFor(token0, NPM, g.got0);
        if (g.got1 > 0) _approveFor(token1, NPM, g.got1);
    }
    function _settleIn(address account, address token0, address token1, Pulled memory g, uint256 tokenId, uint256 used0, uint256 used1) private {
        if (g.got0 > 0) _approveSoft(token0, NPM, 0);
        if (g.got1 > 0) _approveSoft(token1, NPM, 0);
        if (used0 > g.got0 || used1 > g.got1) revert TransferFailed();
        _bookIn(account, tokenId, token0, used0);
        _bookIn(account, tokenId, token1, used1);
        _checkCap(account);
        if (g.got0 > used0) _send(token0, account, g.got0 - used0);
        if (g.got1 > used1) _send(token1, account, g.got1 - used1);
    }
    /// @dev Into a position: USDC adds its amount to the position's cost (and to the wallet's cost out); lot tokens
    ///      leave the lot together with their cost share, which moves onto the position (costOf unchanged).
    function _bookIn(address account, uint256 tokenId, address token, uint256 amount) private {
        if (amount == 0) return;
        if (token == USDC) { posCost[tokenId] += amount; costOf[account] += amount; _countIn(account, amount); return; }
        Lot storage b = lot[account][token];
        if (amount > b.tokens) revert NotInLot(b.tokens, amount);
        uint256 costPart = _ceil(b.usdcIn * amount, b.tokens);
        if (costPart > b.usdcIn) costPart = b.usdcIn;
        b.tokens -= amount; b.usdcIn -= costPart; posCost[tokenId] += costPart;
    }

    /// @notice Withdraw `liquidity` from the wallet's position; everything owed goes to the wallet. Never paused.
    function decrease(address account, uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min) external lock forAccount(account) returns (uint256 amount0, uint256 amount1) {
        return _decrease(account, tokenId, liquidity, amount0Min, amount1Min, false);
    }
    /// @notice Exit key: withdraw a position in full to `account`, without the price check.
    function exitDecrease(address account, uint256 tokenId, uint256 amount0Min, uint256 amount1Min) external lock onlyExit returns (uint256 amount0, uint256 amount1) {
        (,,, uint128 liq) = _posInfo(tokenId);
        return _decrease(account, tokenId, liq, amount0Min, amount1Min, true);
    }
    /// @notice Collect the fees owed to the wallet's position. Fees join at zero cost. Never paused.
    function collect(address account, uint256 tokenId) external lock forAccount(account) returns (uint256 amount0, uint256 amount1) {
        if (posOwner[tokenId] != account || INPM(NPM).ownerOf(tokenId) != account) revert NotYours(tokenId);
        (address token0, address token1,,) = _posInfo(tokenId);
        (amount0, amount1) = INPM(NPM).collect(INPM.CollectParams(tokenId, account, type(uint128).max, type(uint128).max));
        _addFees(account, token0, token1, amount0, amount1);
        emit Collected(account, tokenId, amount0, amount1);
    }
    /// @notice Burn an emptied position; any cost it still carries is booked as a loss.
    function burn(address account, uint256 tokenId) external lock forAccount(account) {
        if (posOwner[tokenId] != account || INPM(NPM).ownerOf(tokenId) != account) revert NotYours(tokenId);
        INPM(NPM).burn(tokenId);
        uint256 lost = _forget(account, tokenId);
        emit Burned(account, tokenId, lost);
    }
    /// @notice Exit key or the wallet: forget a tracked position the wallet no longer owns (changed outside the gate).
    ///         Its remaining cost is booked as a loss (audit 1057 L-2).
    function forget(address account, uint256 tokenId) external lock {
        if (msg.sender != EXIT_KEY && msg.sender != account) revert NotOperator();
        if (posOwner[tokenId] != account) revert NotYours(tokenId);
        (bool ok, bytes memory r) = NPM.staticcall(abi.encodeWithSelector(INPM.ownerOf.selector, tokenId));
        if (ok && r.length >= 32 && abi.decode(r, (address)) == account) revert StillOwned(tokenId);
        uint256 lost = _forget(account, tokenId);
        emit Forgotten(account, tokenId, lost);
    }

    struct Dec { address token0; address token1; uint24 fee; uint128 liqBefore; uint256 p0; uint256 p1; }

    function _decrease(address account, uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, bool isExit) private returns (uint256 amount0, uint256 amount1) {
        if (posOwner[tokenId] != account || INPM(NPM).ownerOf(tokenId) != account) revert NotYours(tokenId);
        Dec memory d;
        (d.token0, d.token1, d.fee, d.liqBefore) = _posInfo(tokenId);
        if (!isExit && liquidity > 0) _checkPrice(d.token0, d.token1, d.fee);
        if (liquidity > 0) (d.p0, d.p1) = INPM(NPM).decreaseLiquidity(INPM.DecreaseLiquidityParams(tokenId, liquidity, amount0Min, amount1Min, block.timestamp));
        (amount0, amount1) = INPM(NPM).collect(INPM.CollectParams(tokenId, account, type(uint128).max, type(uint128).max));
        _bookOut(account, tokenId, d, liquidity, amount0, amount1);
        emit Decreased(account, tokenId, liquidity, amount0, amount1, isExit);
    }
    /// @dev Out of a position. The principal carries the cost share of the liquidity taken: returned USDC repays it
    ///      first, the rest of the cost rides on the returned token (so a later sale books any loss); with no token
    ///      returned the unrecovered cost is a loss now. Anything collected beyond the principal is fees, at zero cost.
    function _bookOut(address account, uint256 tokenId, Dec memory d, uint128 liquidity, uint256 amount0, uint256 amount1) private {
        address other = d.token0 == USDC ? d.token1 : d.token0;
        bool usdcIs0 = d.token0 == USDC;
        uint256 pU = usdcIs0 ? d.p0 : d.p1; uint256 pT = usdcIs0 ? d.p1 : d.p0;
        uint256 share = (liquidity == 0 || d.liqBefore == 0) ? 0
            : (liquidity >= d.liqBefore ? posCost[tokenId] : posCost[tokenId] * liquidity / d.liqBefore);
        posCost[tokenId] -= share;
        uint256 repay = pU < share ? pU : share;
        costOf[account] -= repay;
        uint256 rest = share - repay;
        if (rest > 0) {
            if (pT > 0) { _lotAdd(lot[account][other], pT, rest); pT = 0; }
            else { costOf[account] -= rest; _bookLoss(account, rest); }
        }
        if (pT > 0) _lotAdd(lot[account][other], pT, 0);
        uint256 fee0 = amount0 > d.p0 ? amount0 - d.p0 : 0;
        uint256 fee1 = amount1 > d.p1 ? amount1 - d.p1 : 0;
        _addFees(account, d.token0, d.token1, fee0, fee1);
    }
    function _lotAdd(Lot storage b, uint256 tokens, uint256 cost) private {
        b.tokens += tokens; b.usdcIn += cost;
        if (b.tokens > MAX_LOT) revert TooLarge();
    }
    function _addFees(address account, address token0, address token1, uint256 f0, uint256 f1) private {
        if (token0 != USDC && f0 > 0) _lotAdd(lot[account][token0], f0, 0);
        if (token1 != USDC && f1 > 0) _lotAdd(lot[account][token1], f1, 0);
    }
    function _forget(address account, uint256 tokenId) private returns (uint256 lost) {
        lost = posCost[tokenId];
        if (lost > 0) { posCost[tokenId] = 0; costOf[account] -= lost; _bookLoss(account, lost); }
        delete posOwner[tokenId];
        uint256[] storage arr = positions_[account];
        for (uint256 i = 0; i < arr.length; i++) if (arr[i] == tokenId) { arr[i] = arr[arr.length - 1]; arr.pop(); break; }
    }

    // ---------------------------------------------------------------- views
    function positionsOf(address account) external view returns (uint256[] memory) { return positions_[account]; }
    function lotOf(address account, address token) external view returns (uint256 tokens, uint256 usdcIn) { Lot memory b = lot[account][token]; return (b.tokens, b.usdcIn); }

    // ---------------------------------------------------------------- money to the owner
    /// @dev A plain wallet (no code, or an EIP-7702 delegated EOA) is its own beneficiary; a smart account pays its owner().
    function beneficiaryOf(address account) public view returns (address to) {
        bytes memory code = account.code;
        if (code.length == 0 || (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00)) return account;
        (bool ok, bytes memory r) = account.staticcall(abi.encodeWithSelector(SEL_OWNER));
        if (!ok || r.length < 32) revert NoBeneficiary();
        to = abi.decode(r, (address));
        if (to == address(0) || to == account || to == address(this)) revert NoBeneficiary();
    }
    /// @notice Move `amount` of `token` from the account to its beneficiary. The way out: never paused, no limits.
    function payout(address account, address token, uint256 amount) external lock forAccount(account) {
        if (amount == 0) revert ZeroAmount();
        address to = beneficiaryOf(account);
        if (to == account) revert NoBeneficiary();               // a plain wallet already holds its money
        uint256 got = _pull(token, account, amount);
        _send(token, to, got);
        emit PaidOut(account, to, token, got);
    }
    /// @notice Send USDC from the account to the beneficiary's own account on the hedge venue through Across.
    ///         Paused with the rest of the operator's actions (audit 1057 L-1); the fee bound compares value.
    struct BridgeQuote { uint256 outputAmount; address exclusiveRelayer; uint32 quoteTimestamp; uint32 fillDeadline; uint32 exclusivityDeadline; }
    function fundHedge(address account, uint256 usdcIn, BridgeQuote calldata q) external lock forAccount(account) {
        if (paused()) revert IsPaused();
        if (usdcIn == 0) revert ZeroAmount();
        uint256 outIn6 = HEDGE_DECIMALS >= 6 ? q.outputAmount / (10 ** (HEDGE_DECIMALS - 6)) : q.outputAmount * (10 ** (6 - HEDGE_DECIMALS));
        if (outIn6 + usdcIn * BRIDGE_MAX_FEE_BPS / 10000 < usdcIn) revert BridgeFee();
        address to = beneficiaryOf(account);
        _countOp(account); _countOut(account, usdcIn);
        uint256 got = _pull(USDC, account, usdcIn);
        _approveFor(USDC, SPOKE, got);
        _deposit(to, got, q);
        _approveSoft(USDC, SPOKE, 0);
        emit HedgeFunded(account, to, got, q.outputAmount);
    }
    function _deposit(address to, uint256 got, BridgeQuote calldata q) private {
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
    function _approveSoft(address token, address spender, uint256 amount) private {
        (bool ok, ) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount)); ok;
    }
}
