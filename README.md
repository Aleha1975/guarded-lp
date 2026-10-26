# GuardedLP

One-purpose gate between a client's own account and two venues on Base: the Uniswap V3 position manager and the
KyberSwap router. The client signs ONE delegation (targets [gate], methods [gate functions]); the gate pins every
recipient in code, so no per-token or per-recipient permissions are needed. No owner, no upgrade, no funds held.

- `src/GuardedLP.sol` — the contract (rules in the header comment)
- `test/GuardedLP.t.sol` — unit tests on mocks (`forge test --no-match-contract Fork`)
- `test/Fork.t.sol` — real Base round trip: `python3 script/kyber_fixture.py && BASE_RPC=<url> forge test --match-contract Fork`
  (Kyber routes expire in minutes; fetch right before running)
