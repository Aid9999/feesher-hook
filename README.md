# Feesher Hook

A Uniswap v4 hook for one pool on Robinhood Chain (chain id 4663, an Arbitrum
Orbit L2 where Uniswap v2, v3, v4 and UniswapX are deployed).

The pool is native **ETH / FEESHER** on the canonical v4 PoolManager. Every swap
pays a flat trading fee **in native ETH**, which the hook hands to one address
with a single `poolManager.take` and forgets about. The pool itself is an
ordinary **0.3% fee tier**, so liquidity providers earn the pool fee exactly as
they would with no hook at all, and the protocol fee the PoolManager may switch
on applies to it untouched.

Site: https://feesherhook.xyz

## Deployed contracts (Robinhood Chain mainnet, 4663)

| Contract | Address |
| --- | --- |
| `FeeshFeeHook` (the hook) | `0x3d1F46aA87bbCdEcB3afb64Db6a84EAce32204cC` |
| `FeeshToken` — Feesher Hook, $FEESHER | `0xbD86E40099E38B4081eDC3CBf56ED201Cd533A9F` |
| `FeeshPond` (fee recipient) | `0xcB44F2b726cB01f952691f4F81051190E2C51207` |
| `FeeshSeeder` (liquidity, add-only) | `0x7EA5866E3642A0835194aC083ba77b5E57f66793` |
| `FeeshRouter` (the site's own swap entry point) | `0x6D7f16f7003783aE71562E7e257103e2c7Cff21e` |
| Feesher collection (ERC-721 + ERC-6551 wallets) | `0x16F0Bf3F63b7eC7A6B92b0a9F678ec0FBF90A581` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

Pool key: `currency0 = 0x0` (native ETH), `currency1 = FEESHER`, `fee = 3000`,
`tickSpacing = 60`, `hooks = 0x3d1F…04cC`.
Pool id: `0x17b9b94be423498fdf5a76f4b1cd108ab4b1ec6555099fbb75644d0920877898`.

Every contract is verified on Sourcify (exact match) and on the chain's
Blockscout instance. The hook address is not in the `0x91…` range; it carries
the permission flags `0x4CC`.

## The hook

`src/FeeshFeeHook.sol`. Flags encoded in the address: `BEFORE_SWAP`,
`AFTER_SWAP`, `BEFORE_SWAP_RETURNS_DELTA`, `AFTER_SWAP_RETURNS_DELTA`,
`AFTER_ADD_LIQUIDITY`.

### The fee

One rate, charged on the ETH leg of the swap, in all four swap shapes:

| swap | where the fee comes from | callback |
| --- | --- | --- |
| buy, exact input (ETH → FEESHER) | the ETH sent in | `beforeSwap` |
| sell, exact output (FEESHER → ETH) | added to the ETH owed | `beforeSwap` |
| sell, exact input (FEESHER → ETH) | the ETH paid out | `afterSwap` |
| buy, exact output (ETH → FEESHER) | added to the ETH sent in | `afterSwap` |

No swap shape is cheaper or more expensive than another, and there is no shape
that escapes the fee. Exact-output legs use `fee = x * bps / (10000 - bps)` so
the charge is the same share of the gross ETH amount as everywhere else.

The fee is paid out with one `poolManager.take` of native ETH inside the swap.
If the PoolManager holds no native float at that moment (which happens on a
pool's very first swaps, since settlement lands at the end of the unlock), the
hook mints itself an ERC-6909 claim instead and anyone can cash it out later
with the public `collectFees()`. The hook never holds a token balance and never
reads or calls any contract other than the PoolManager and its fee recipient.

### The schedule

* `openingFeeBps = 9000` at the instant `openTrading()` is called,
* decaying linearly to `baseFeeBps = 300` over `OPENING_PERIOD = 10 seconds`,
* then a flat **3%** forever.

Ten seconds of a high fee is the anti-snipe step: it makes the first block of a
launch unattractive and is over before an ordinary swapper arrives. Before
`openTrading()` every swap reverts with `TradingNotOpen`.

### What the owner can do, and what nobody can ever do

The owner has exactly three functions:

| function | effect | limit |
| --- | --- | --- |
| `openTrading()` | starts the schedule | **one way** — reverts with `AlreadyOpen` afterwards, and no other code path writes `tradingOpenedAt` |
| `setFeeSchedule(opening, base)` | changes the two rates | once trading is open, **neither value may increase**; `MAX_FEE_BPS = 9000` caps it before the open |
| `setFeeRecipient(address)` | changes where the ETH goes | does not touch the amount a swapper pays |

There is no other state-changing owner function in the contract. In particular
nobody, owner included, can:

* **re-close trading or pause the pool** — the one-way flag above;
* **raise the fee after the open** — so the schedule a swapper sees at the open
  is the worst case it can ever face;
* **blacklist, tax or limit an address** — no such code path exists in the hook
  or in the token;
* **touch liquidity, balances or the price** — the hook holds no balance and
  never calls `modifyLiquidity`, `donate` or `swap`;
* **withdraw the liquidity that seeded the pool** — `FeeshSeeder` has no removal
  path at all (see below);
* **upgrade anything** — the hook is deployed straight through the canonical
  CREATE2 factory, there is no proxy, no `delegatecall` and no upgrade hook, and
  `poolManager` and `feeshToken` are `immutable`;
* **mint more tokens** — the token has a fixed supply minted once in its
  constructor and no owner at all.

### Pool key check

Every callback validates the `PoolKey` it was handed (`onlySupportedPool`):
native ETH as `currency0`, FEESHER as `currency1`, `fee = 3000`,
`tickSpacing = 60`. A pool that someone else creates pointing at this hook
cannot borrow its fee logic or its deposit permits — it simply reverts with
`UnsupportedPool`.

### Routing

* `hookData` is always empty. The hook ignores the `bytes calldata` argument
  entirely; nothing has to be encoded for it.
* The pool is a plain static-fee pool. The hook never returns an LP fee
  override and never uses the dynamic-fee flag.
* Once trading is open the hook never reverts a routed swap.
* `test/UniswapRouterFork.t.sol` runs Uniswap's own **UniversalRouter**
  (`0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99`, the current deployment on 4663)
  and **V4Quoter** against the live deployment, on a mainnet fork, for all four
  swap shapes with empty hook data: exact-in buy, exact-in sell (via Permit2),
  exact-out sell and exact-out buy. Nothing is mocked and no calldata is
  special-cased.

## The token

`src/FeeshToken.sol` — "Feesher Hook", `$FEESHER`, fixed supply of 4,444,000
minted once to the deployer. **No owner, no mint, no burn, no pause, no transfer
tax, no blacklist, no per-wallet limit.** Wallet-to-wallet transfers, transfers
to any exchange, bridge, v2 or v3 pool are untouched.

The single restriction is the v4 deposit permit: a transfer **into the v4
PoolManager** calls `spendDepositPermit` on the hook, which reverts unless the
hook authorized that exact amount earlier in the same transaction. The hook
authorizes it in `afterSwap` and `afterAddLiquidity` of its own pool, so the
token can be deposited into that pool by anyone — including third-party
liquidity providers — but a rival v4 pool cannot be funded and the ETH fee
cannot be routed around inside v4. `configure` is one-shot; `disableGuard`
drops the restriction for good and cannot be undone.

## Liquidity

`FeeshSeeder` adds liquidity and can never remove it: the contract has no path
that passes a negative `liquidityDelta`, so both positions are permanent.

* **Ask side:** the whole supply minus the reserve, in one position reaching
  down to the lowest usable tick — the supply on offer never runs out and the
  price has no ceiling.
* **Bid side:** a few dollars of native ETH just above spot, so the pool quotes
  in both directions from the first block.
* **Reserve:** 1% of supply (44,440 FEESHER) stays with the deployer, visible on
  chain from the very first block. The deploy script refuses anything above 5%.

## What happens to the fee afterwards

Outside the swap, and irrelevant to routing: the recipient is `FeeshPond`, which
queues each fee and later raffles five sixths of it among the holders of the
Feesher NFT collection, one draw per trade, seeded by the hash of the block the
trade landed in. The remaining sixth is the protocol's. All of that happens in
separate transactions; inside a swap the pond does nothing but store the amount
and the block number. `src/FeeshPond.sol` is in this repository for
completeness.

## Build and test

```shell
forge build
forge test --match-path test/UniswapRouterFork.t.sol -vv   # UniversalRouter + Quoter, mainnet fork
forge test --match-path test/MainnetLive.t.sol -vv         # the whole mechanism on the live contracts
```

Both suites fork `https://rpc.mainnet.chain.robinhood.com` and run against the
deployed addresses.

## Deployment

```shell
# token + seeder + hook (CREATE2 salt for flags 0x4CC) + pool initialize
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 \
POND=0xcB44F2b726cB01f952691f4F81051190E2C51207 \
START_FDV_USD=20000 RESERVE_WEI=44440000000000000000000 \
forge script script/DeployStack.s.sol:DeployStack --rpc-url robinhood --broadcast --slow

# both sides of the book, in one transaction each
SEEDER=... FEESH_TOKEN=... HOOK=... SEED_ETH_WEI=912208793301831 \
forge script script/Seed.s.sol:Seed --rpc-url robinhood --broadcast --slow
```

`verify/submit.sh` posts the standard-json bundles to Blockscout; the same
bundles are what Sourcify verified.

## License

MIT.
