> **v2 (this commit).** The account is the client's own wallet (an EOA, an EIP-7702 delegated EOA, or a smart account).
> The wallet sends one batch: token approvals to the gate, `NPM.setApprovalForAll(gate, true)` and `authorize(operator, cap)`.
> The operator then calls every entry point with the wallet as `account`; the wallet can revoke with `authorize(address(0), 0)`.
> Changes against v1 (audit job 1057): USDC pairs only and the token side only from the lot (H-1, H-2, M-2); spot tick within
> 150 ticks of the 300 s TWAP on mint, increase and decrease (H-1); cost follows tokens through positions and an unrecovered
> cost is booked as a loss (M-1); `fundHedge` paused with the rest and fee compared in value (L-1); `forget` for positions
> changed outside the gate (L-2); allowToken comment (L-3); account excluded as a route receiver (L-4). Sections below
> describe v1 where they differ.

# GuardedLP — design (Base only, 24.10.2026)

## Why
The LVR flow asked the client for 10 EIP-712 delegations per pool set (swap, approve_swap, approve_lp, lp_mint,
lp_collect, lp_adjust, withdraw, native, approve_bridge, bridge) plus a smart-account deploy, a USDC transfer, a
Hyperliquid agent approval and a margin deposit: 12–15 signatures on first entry, 8–10 more per new set. The reason is
structural: a MetaMask delegation pins a recipient or spender with ONE fixed calldata word, and several pins AND
together, so every pinned value needs its own delegation. GuardedLP moves every pin into contract code.

## What the client signs
| Step | Today | With GuardedLP + EIP-7702 batch |
| --- | --- | --- |
| Account | deploy Hybrid smart account (1 tx) | none: the EOA itself is upgraded inside the first batch (MetaMask 7702, Base supported, ≤10 calls) |
| Funding | USDC transfer to the smart account (1 tx) | none: USDC stays in the client's wallet; the gate pulls up to the approved cap |
| Permissions | 8–10 delegations | 1 batch (`approve USDC → gate` cap, `approve <pool tokens> → gate`, `NPM.setApprovalForAll(gate)`) + 1 delegation (targets [gate], methods [buy, sell, mint, increase, decrease, collect, burn], valueLte 0, timestamp) |
| Hedge | approveAgent (1) + deposit (1 tx, Arbitrum USDC) | approveAgent (1); the margin deposit is one more call in the same Base batch: Across `depositV3` to HyperCore perps (verified 24.10: 131 USDC → 130.983, $0.017, ~0 s) |
| **Entry total** | **12–15** | **3** (batch, delegation, agent) |
| Add money | approve + /add (0–2) | 0 (within the approved cap) or 1 batch to raise the cap |
| Exit, pool side | 0 (withdraw delegation) | 0: the executor closes to USDC on the client's own address |
| Exit, hedge side | withdraw3 (1) → USDC lands on Arbitrum | 1 (`sendToEvmWithData`, destination Base) — removed later by a HyperEVM vault (phase B) |

Unverified until the owner tries it on his phone: (a) MetaMask mobile signs an ERC-7710 delegation for a 7702-upgraded
EOA via `eth_signTypedData_v4` (the DelegationManager verifies it through the 7702 delegator's EIP-1271); (b) the
`wallet_sendCalls` path through the `metamask.app.link` deep link. Both are cheap to test with a $1 batch.

## The contract
`src/GuardedLP.sol`, no owner, no upgrade, holds nothing between calls. Everything it moves lands on `msg.sender`
(the account) or, for the exit key, on the named account.

Functions the executor may call through the delegation (always as the account):
- `buy(token, usdcIn, minOut, routerData)` — USDC → token via Kyber; route decoded and checked (pinned executor, declared
  tokens and amount, receiver = gate, no fees/permit, no flag the router dispatches on); output and unspent USDC to the account.
- `sell(token, amount, minOut, routerData)` — token → USDC, at most the lot, within the loss budget.
- `mint(MintSpec)` / `increase(AddSpec)` — pulls the account's tokens, NPM mints/increases **with recipient = account**,
  leftovers returned; both pool sides must be allowed tokens.
- `decrease(tokenId, liquidity, min0, min1)`, `collect(tokenId)`, `burn(tokenId)` — only positions this gate minted and the
  account still owns; proceeds collected straight to the account. Never paused.

Guards: allowlist (guardian proposes +24 h, exit key at once, both revoke at once); loss budget 30 % of value at cost
with a 7-day linear refill (losses measured in USDC against the lot's cost; USDC a position returns repays the position's
cost, then the paired token's cost); lot rule (only tokens the gate bought or positions returned); per-account hourly
limits (ops, USDC in, USDC out); guardian pause ≤7 days + 1 day cooldown (does not touch decrease/collect); exit key
`unlock`, `exitSell`, `exitDecrease`, `replaceGuardian`.

Residuals (documented, as in GuardedSwap): sale srcReceivers chosen by the aggregator; buys have no price reference
beyond the hourly USDC cap; budget is relative to cost, not market; an account mostly in USDC exposes its positions in
full within the budget.

## Tests
- 17 unit tests on mocks (`forge test --no-match-contract Fork`): books across buy→mint→collect→decrease→burn→sell,
  route pins, misdirected router output, lot rule, budget + exit key, trim on owner withdrawals, allowlist delay/revoke,
  pause semantics, NFT transferred away, rate limits, leftovers, nothing sticks to the gate.
- Fork test on real Base (block 53037148): Kyber buy 100 USDC → 0.0432 WETH, Uniswap V3 mint WETH/USDC 0.05 % with
  recipient = account (0.0432 WETH + 99.27 USDC), decrease, burn, Kyber sell 0.01 WETH → 23.1 USDC; route with a foreign
  receiver refused. Gate balances unchanged throughout.

## Owner payout and hedge margin (26.10)
The account is a MetaMask Hybrid smart account whose `owner()` is the client's wallet. The gate reads it, so two
more functions need no pinned recipient: `payout(token, amount)` sends from the account to `owner()`; `fundHedge(usdcIn,
quote)` pulls USDC from the account and calls Across `depositV3` with depositor = recipient = `owner()`, destination
HEDGE_CHAIN_ID (HyperCore perps, 1337), output HEDGE_TOKEN (0x2100…0000), fee capped at 1%, counted in the USDC-out
window. Both are reachable only by the account itself (or whoever holds its `gate` delegation).

Signature count with the smart-account model (no 7702 needed): entry = 1 deposit tx + `gate` + `approve_gate` + the
Hyperliquid agent approval = 4; exit = 0 on Base (`decrease` → `sell` → `payout`), 1 on Hyperliquid (withdraw) or 0
if the margin stays. `approve_gate` is one delegation because `approve(spender)` and `setApprovalForAll(operator)` both
carry the gate's address in calldata word 0.

Executor integration (`/opt/mprhedged/exec`, 26.10): `gate.mjs` (ABI, selectors, translation of NPM/transfer calls into
gate calls), `delegations.mjs` kinds `gate` and `approve_gate`, `exec.mjs`: `use_gate` flag per account (POST /account
{gate:true}), `requiredKinds` → the two kinds, `act()` translates lp_mint/lp_adjust/lp_collect/withdraw, `swap()` →
`gateSwap` (Kyber route built with sender = recipient = gate), `fundHedgeViaGate`, `/start {fund_margin:true}` sends the
margin share through the gate first. Accounts without the flag run the old path untouched.

Test deployment on Base, 26.10: `0xcc665073bee3fb857afd6c973ffa86a99ed66316` (tx 0xcb1a3223…), guardian = Dispatch
guardian 0x5550C8E4…, EXIT key = executor (TEST ONLY: lets `allowToken` skip the 24 h delay), limits 24 ops / $5 000 in /
$5 000 out per hour; allowed WETH, LINK, VVV, VIRTUAL. The production gate is a fresh deployment after the audit with
the owner's cold key as EXIT.

## Integration plan (executor + app)
1. Deploy on Base from the executor key (constructor: Kyber router `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5`,
   executor `0x8F10B468b06c6FD214B65F87778827F7D113f996`, NPM `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1`,
   USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, guardian = watcher key, exit key = owner's cold key,
   limits 24 ops / $5 000 in / $5 000 out per hour), Sourcify verify, allow the Base pool tokens.
2. `exec.mjs` behind `GATE_ADDR`: new permission kind `gate` (one delegation); `act()` routes swap/mint/increase/
   decrease/collect/burn through the gate for accounts that hold it; the account address = owner EOA when the owner
   is 7702-upgraded, Hybrid smart account otherwise (same code path, different delegator).
3. App: `wallet_getCapabilities` → one `wallet_sendCalls` batch (approvals + optional Across deposit to HyperCore) →
   one `eth_signTypedData_v4` delegation → `approveAgent`. Fallback for wallets without 5792: sequential transactions.
4. Watcher: gate events vs executor journal (as Dispatch), pause on a foreign event.
5. External audit rounds before client money (One Dollar Audit, as for GuardedSwap).

Phase B (later): HedgeVault on HyperEVM (CoreWriter) removes the Hyperliquid signatures entirely.
