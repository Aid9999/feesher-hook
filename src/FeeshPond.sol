// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface IFeesherCollection {
    function walletAddress(uint256 tokenId) external view returns (address);
    function ownerOf(uint256 id) external view returns (address);
    function levelOf(uint256 id) external view returns (uint8);
}

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IV3Slot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title FeeshPond
/// @notice Holds the trading fee collected by the pool hook and books it to the
///         feeshers that catch it.
///
/// The hook does nothing but send the fee here in native ETH, so no collection
/// state is read and no value is moved while a swap is executing. All this
/// contract does inside a swap is write one word: the fee that arrived and the
/// block it arrived in, at the end of a queue.
///
/// A feesher that was never activated is simply not in these lists and cannot
/// be drawn at all. One whose holder has since dropped below the bar is found
/// by the draw itself: it is taken out of the lists on the spot and the share
/// is drawn again, so a wallet that sold its tokens stops taking chances away
/// from the holders who kept theirs, without anyone having to notice.
///
/// Changing hands ends an activation too: it was the old holder who put up the
/// tokens, and the new one has not agreed to anything. The pond cannot be told
/// about a transfer, so it notices at the first moment it looks the owner up —
/// a `pull`, a `deactivate` — and clears the entry then. The new holder
/// activates it themselves, on the terms of its level.
///
/// Activation: a feesher only fishes once its holder has activated it, and
/// activating asks that the holder keep a minimum amount of the token —
/// `usdTargetE6` per level, priced from the pool itself, doubling with each
/// level just as the ticket weight does. Nothing is charged and nothing is
/// locked: the tokens stay in the holder's wallet, and one balance covers any
/// number of feeshers of that level. The same balance is checked again when a
/// catch is pulled, so selling the tokens stops the payouts.
///
/// One trade, one draw: every queued fee is settled on its own, as
/// SHARES_PER_FEE independent ticket-weighted chances over the active feeshers,
/// however many trades pile up before anyone settles them. `fish` walks the
/// queue and can settle many trades in one transaction, which is what makes
/// running the draws cheap; nothing is ever merged and no trade is skipped.
///
/// The seed of a trade is the hash of the block that trade landed in. It does
/// not exist while the trade executes, so the trader cannot pick it, and it is
/// fixed the moment the block closes, so whoever settles it cannot pick it
/// either. A trade left unsettled past the 256-block window the chain keeps
/// hashes for is re-stamped to the current block and drawn from a later hash —
/// again one nobody can see yet.
///
/// Money rests at three points and never has to be moved on:
///   1. the queue   - a trade's fee, waiting for its draw;
///   2. the catch   - `caught[tokenId]`, what a feesher has been drawn for and
///                    has not pulled out yet. It adds up over any number of
///                    trades;
///   3. the feesher's own ERC-6551 wallet - where `pull` puts the catch, and
///      where it adds up until the holder sweeps it with the collection's own
///      batch `collect(uint256[])`.
///
/// Gas: the pond pays for its own distribution, out of the pool's own share.
/// `gasFundBps` of the five sixths being handed out is set aside in `gasFund`.
/// A call from `roller` — the wallet whose job is to run the draws — is topped
/// back up to `rollerTargetWei`, so that wallet simply stays funded instead of
/// having to be refilled by hand; any other caller is paid back exactly what
/// its call burned. The protocol's sixth is never touched by any of this.
///
/// Dust: a fee smaller than `minFeeWei` does not get a draw of its own — it
/// waits in `crumbs` and rides along with the next fee. Without that floor a
/// trade too small to be worth distributing would cost more gas to hand out
/// than it carries.
///
/// Split of one trade's fee: `amount / PROTOCOL_SHARE_DIVISOR` is booked to
/// `protocolOwed`, which only the protocol can move. The remaining five sixths
/// are cut into SHARES_PER_FEE equal shares, each booked by its own draw (with
/// replacement, so one feesher can take several shares of the same trade). A
/// level-N token holds W_N tenths of a ticket (level 1..4 -> 10, 21, 43, 87),
/// so one uniform number in [0, 10*n1 + 21*n2 + 43*n3 + 87*n4) maps to exactly
/// one live token. With no live feesher the whole fee is the protocol's.
contract FeeshPond is Ownable {
    IFeesherCollection public immutable nft;

    address public protocolRecipient;

    /// Queued trade fees: queue[i] = amount << 64 | block number it arrived in.
    mapping(uint256 => uint256) public queue;
    /// Next entry to settle, and next slot to write.
    uint128 public head;
    uint128 public tail;
    /// ETH sitting in unsettled queue entries, plus `crumbs`.
    uint256 public queued;
    /// Fees too small for a draw of their own, waiting for the next one.
    uint256 public crumbs;
    /// Smallest fee that gets its own draw.
    uint256 public minFeeWei;
    /// Set aside from the pool's share to pay whoever runs the draws.
    uint256 public gasFund;
    uint16 public gasFundBps = 300;
    uint16 public constant HARD_GAS_FUND_BPS = 1000;
    /// The wallet that runs the draws, and the float the pond keeps it at.
    address public roller;
    uint256 public rollerTargetWei;
    /// Draws and activation are off while this is set.
    bool public paused;
    /// Booked to feeshers and not pulled yet, plus anything held by `owed`.
    uint256 public reserved;
    /// The protocol's share, waiting for `withdrawProtocol`.
    uint256 public protocolOwed;
    uint256 public drawNonce;

    /// The protocol keeps amount / PROTOCOL_SHARE_DIVISOR of every trade's fee.
    uint256 public constant PROTOCOL_SHARE_DIVISOR = 6;
    /// Number of equal shares (and independent draws, with replacement) per trade.
    uint256 public constant SHARES_PER_FEE = 5;
    /// Ticket weights per level, in tenths: W(n+1) = 2 * W(n) + 1.
    uint256 public constant W1 = 10;
    uint256 public constant W2 = 21;
    uint256 public constant W3 = 43;
    uint256 public constant W4 = 87;
    /// Trades one `fish()` settles when no limit is given.
    uint256 public constant DEFAULT_BATCH = 25;
    /// How many times one share is re-drawn past feeshers that no longer qualify.
    uint256 public constant DRAW_TRIES = 4;

    /// Largest gas refund one call may take.
    uint256 public maxRefundWei = 0.01 ether;
    /// Gas the refund itself costs beyond what gasleft() can see, including the
    /// 21000 the sender paid to get here.
    uint256 internal constant REFUND_OVERHEAD = 40_000;

    // -------------------------------------------------------- activation

    uint8 public constant MAX_LEVEL = 4;
    /// The token a holder has to keep, and where its price is read from.
    address public feeshToken;
    IExtsload public poolManager;
    bytes32 public poolId;
    /// Uniswap v3 WETH/USDG pool (WETH = token0, USDG 6 decimals); zero uses the override.
    address public ethUsdPool;
    uint256 public ethUsdOverrideE6;
    /// Dollars (1e6) a holder must keep per level of the feesher being activated.
    uint256[5] public usdTargetE6 = [0, 5e6, 10e6, 20e6, 40e6];

    /// Active feeshers per level, and where each one sits in its list.
    mapping(uint8 => uint256[]) internal _active;
    mapping(uint256 => uint256) internal _posPlus1;
    /// Level a feesher is registered under; zero means it is not fishing.
    mapping(uint256 => uint8) public activeLevel;
    /// The wallet that activated it, whose holding the draw checks. Kept here
    /// rather than asked of the collection, because ERC721A's ownerOf walks
    /// back through a batch mint and would cost more than the draw itself.
    mapping(uint256 => address) public activeHolder;

    /// What a feesher has caught and not pulled out yet.
    mapping(uint256 => uint256) public caught;
    /// Payouts that could not be pushed, held for `withdrawOwed`.
    mapping(address => uint256) public owed;

    uint256 private _entered;

    event FeeQueued(uint256 indexed index, uint256 amount, uint256 blockNumber);
    event TradeSettled(uint256 indexed index, uint256 amount, uint256 tickets);
    event TradeRestamped(uint256 indexed index, uint256 blockNumber);
    event Caught(uint256 indexed tokenId, uint256 amount);
    event Activated(uint256 indexed tokenId, address indexed holder, uint8 level);
    event Deactivated(uint256 indexed tokenId, uint8 level);
    event PriceSourceSet(address token, address poolManager, bytes32 poolId, address ethUsdPool, uint256 ethUsdOverrideE6);
    event UsdTargetsSet(uint256 l1, uint256 l2, uint256 l3, uint256 l4);
    event Pulled(uint256 indexed tokenId, address indexed wallet, uint256 amount);
    event PaidOut(address indexed to, uint256 amount);
    event PayoutDeferred(address indexed to, uint256 amount);
    event ProtocolBooked(uint256 amount, uint256 total);
    event ProtocolWithdrawn(address indexed to, uint256 amount);
    event PotRescued(address indexed to, uint256 amount);
    event GasRefunded(address indexed to, uint256 amount);
    event RefundCapSet(uint256 maxWei);
    event MinFeeSet(uint256 minFeeWei);
    event GasFundSet(uint16 bps);
    event RollerSet(address roller, uint256 targetWei);
    event PausedSet(bool paused);
    event Drained(address indexed to, uint256 amount);
    event CrumbsHeld(uint256 amount, uint256 total);

    error NothingToDo();
    error NothingOwed();
    error NothingToPull();
    error PotEmpty();
    error NotProtocol();
    error TokenAlive(uint256 tokenId);
    error NotHolder(uint256 tokenId);
    error NotEnoughHeld(uint256 tokenId, uint256 needed, uint256 held);
    error PriceUnknown();
    error StillActive(uint256 tokenId);
    error CapTooHigh();
    error Paused();
    error NotPaused();
    error Reentrancy();

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(IFeesherCollection nft_, address recipient, address owner_) Ownable(owner_) {
        nft = nft_;
        protocolRecipient = recipient;
    }

    /// The fee of one trade, arriving from the hook: queued for its own draw.
    /// This is the only thing that happens inside a swap.
    receive() external payable {
        uint256 amount = msg.value;
        if (amount == 0) return;
        queued += amount;
        uint256 total = crumbs + amount;
        if (total < minFeeWei) {
            // too small to be worth a draw of its own: it rides with the next one
            crumbs = total;
            emit CrumbsHeld(amount, total);
            return;
        }
        if (crumbs != 0) crumbs = 0;
        uint256 i = tail;
        queue[i] = (total << 64) | uint64(block.number);
        tail = uint128(i + 1);
        emit FeeQueued(i, total, block.number);
    }

    // ------------------------------------------------------------------ views

    /// @notice Trades waiting for their draw.
    function pending() public view returns (uint256) {
        return tail - head;
    }

    /// @notice Fees that belong to no one yet: not queued, not booked, not the
    ///         protocol's. Only ever a rounding crumb or a direct donation.
    function pot() public view returns (uint256) {
        uint256 held = queued + reserved + protocolOwed + gasFund;
        uint256 bal = address(this).balance;
        return bal > held ? bal - held : 0;
    }

    /// @notice True when `fish()` would settle at least one trade right now.
    function fishable() external view returns (bool) {
        if (head >= tail) return false;
        return block.number > uint64(queue[head]);
    }

    /// @notice What these feeshers have caught and not pulled out yet.
    function caughtBatch(uint256[] calldata ids) external view returns (uint256[] memory out) {
        out = new uint256[](ids.length);
        for (uint256 i; i < ids.length; i++) out[i] = caught[ids[i]];
    }

    /// @notice Active feeshers per level.
    function activeCounts() public view returns (uint256 n1, uint256 n2, uint256 n3, uint256 n4) {
        return (_active[1].length, _active[2].length, _active[3].length, _active[4].length);
    }

    /// @notice Total tickets currently in the draw.
    function tickets() public view returns (uint256) {
        (uint256 n1, uint256 n2, uint256 n3, uint256 n4) = activeCounts();
        return W1 * n1 + W2 * n2 + W3 * n3 + W4 * n4;
    }

    /// @notice The active feesher at `index` of `level`'s list.
    function activeTokenAt(uint8 level, uint256 index) external view returns (uint256) {
        return _active[level][index];
    }

    /// @notice Whether each of these feeshers is fishing, as the level it is
    ///         registered under; zero means it is not.
    function activeLevels(uint256[] calldata ids) external view returns (uint8[] memory out) {
        out = new uint8[](ids.length);
        for (uint256 i; i < ids.length; i++) out[i] = activeLevel[ids[i]];
    }

    /// @notice The wallet each of these activations is standing on. A feesher
    ///         that has changed hands since still reads its old holder here,
    ///         which is what tells the site it needs activating again.
    function activeHolders(uint256[] calldata ids) external view returns (address[] memory out) {
        out = new address[](ids.length);
        for (uint256 i; i < ids.length; i++) out[i] = activeHolder[ids[i]];
    }

    /// @notice What a holder must keep for each level, in one read.
    function holdTable() external view returns (uint256 l1, uint256 l2, uint256 l3, uint256 l4) {
        uint256[5] memory need = _holdTable();
        return (need[1], need[2], need[3], need[4]);
    }

    // ------------------------------------------------------------ activation

    /// @notice FEESH per ETH, read from the pool's own current price.
    function feeshPerEth() public view returns (uint256) {
        if (address(poolManager) == address(0)) return 0;
        bytes32 raw = poolManager.extsload(keccak256(abi.encode(poolId, uint256(6))));
        uint256 sqrtP = uint160(uint256(raw));
        return (sqrtP * sqrtP) >> 192; // price = token1/token0 = FEESH per ETH
    }

    /// @notice ETH in dollars (1e6), from the chain's WETH/USDG pool or the override.
    function ethUsdE6() public view returns (uint256) {
        if (ethUsdOverrideE6 != 0) return ethUsdOverrideE6;
        if (ethUsdPool == address(0)) return 0;
        (uint160 sq,,,,,,) = IV3Slot0(ethUsdPool).slot0();
        return (uint256(sq) * uint256(sq) * 1e18) >> 192;
    }

    /// @notice FEESH a holder must keep to activate, and keep fishing, a feesher
    ///         of this level. Zero level or an unreadable price means nothing
    ///         can be activated rather than everything.
    function requiredHold(uint8 level) public view returns (uint256) {
        if (level == 0 || level > MAX_LEVEL) revert PriceUnknown();
        uint256 usd = usdTargetE6[level];
        if (usd == 0) return 0;
        uint256 perEth = feeshPerEth();
        uint256 usdPerEth = ethUsdE6();
        if (perEth == 0 || usdPerEth == 0) revert PriceUnknown();
        return (usd * perEth * 1e18) / usdPerEth;
    }

    /// The four thresholds at once, so a batch reads the price only once.
    /// With every target at zero the requirement is off and no price is needed.
    function _holdTable() internal view returns (uint256[5] memory need) {
        if (usdTargetE6[1] == 0 && usdTargetE6[2] == 0 && usdTargetE6[3] == 0 && usdTargetE6[4] == 0) return need;
        uint256 perEth = feeshPerEth();
        uint256 usdPerEth = ethUsdE6();
        if (perEth == 0 || usdPerEth == 0) revert PriceUnknown();
        for (uint8 l = 1; l <= MAX_LEVEL; l++) {
            need[l] = (usdTargetE6[l] * perEth * 1e18) / usdPerEth;
        }
    }

    /// @notice Puts these feeshers into the draw. The caller must hold them and
    ///         must be keeping at least `requiredHold` of the token — one
    ///         balance covers any number of feeshers of that level, and nothing
    ///         is taken or locked.
    function activate(uint256[] calldata ids) external nonReentrant {
        if (paused) revert Paused();
        uint256[5] memory need = _holdTable();
        // with no holding asked for, the token does not even have to be wired
        uint256 held = need[1] | need[2] | need[3] | need[4] == 0
            ? 0
            : IERC20Balance(feeshToken).balanceOf(msg.sender);
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (nft.ownerOf(id) != msg.sender) revert NotHolder(id);
            uint8 level = nft.levelOf(id);
            if (held < need[level]) revert NotEnoughHeld(id, need[level], held);
            _setActive(id, level);
        }
    }

    /// @notice Takes a feesher out of the draw. Its holder may always do this;
    ///         anyone may do it for one that has been burned, or whose holder
    ///         no longer keeps enough of the token.
    function deactivate(uint256 id) external nonReentrant {
        uint8 level = activeLevel[id];
        if (level == 0) revert StillActive(id);
        address owner_ = _ownerOrZero(id);
        // a burned feesher always goes, and so does one that has changed hands;
        // otherwise only its holder, or anyone once that holder has stopped
        // keeping what the level asks for
        if (owner_ != address(0) && msg.sender != owner_ && activeHolder[id] == owner_) {
            uint256[5] memory need = _holdTable();
            if (_qualifies(id, need)) revert StillActive(id);
        }
        _clearActive(id, level);
    }

    /// @notice Takes several feeshers out of the draw at once, under the same
    ///         rules as `deactivate`. Cleaning out holders who no longer keep
    ///         the token costs one call, not one per feesher.
    function deactivateMany(uint256[] calldata ids) external nonReentrant {
        uint256[5] memory need = _holdTable();
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            uint8 level = activeLevel[id];
            if (level == 0) continue;
            // a forge changed the level: the old entry is stale and goes,
            // whoever asks. The new level has to be activated on its own terms.
            address owner_ = _ownerOrZero(id);
            // burned, changed hands, forged to another level, or fell short
            if (owner_ != address(0) && activeHolder[id] == owner_ && nft.levelOf(id) == level
                && msg.sender != owner_ && _qualifies(id, need)) continue;
            _clearActive(id, level);
        }
    }

    /// @notice Takes a feesher out of the draw once a forge has changed its
    ///         level. A new level is a new bar, so it is never carried over
    ///         quietly: the holder activates it again at the higher level, and
    ///         sees what that level asks for. Callable by anyone.
    function syncLevel(uint256 id) external nonReentrant {
        uint8 level = activeLevel[id];
        if (level == 0) revert StillActive(id);
        if (nft.levelOf(id) == level) return;
        _clearActive(id, level);
    }

    function _setActive(uint256 id, uint8 level) internal {
        uint8 was = activeLevel[id];
        if (was == level) return;
        if (was != 0) _clearActive(id, was);
        _active[level].push(id);
        _posPlus1[id] = _active[level].length;
        activeLevel[id] = level;
        address holder = nft.ownerOf(id);
        activeHolder[id] = holder;
        emit Activated(id, holder, level);
    }

    function _clearActive(uint256 id, uint8 level) internal {
        uint256 pos = _posPlus1[id] - 1;
        uint256[] storage list = _active[level];
        uint256 last = list.length - 1;
        if (pos != last) {
            uint256 moved = list[last];
            list[pos] = moved;
            _posPlus1[moved] = pos + 1;
        }
        list.pop();
        delete _posPlus1[id];
        delete activeLevel[id];
        delete activeHolder[id];
        emit Deactivated(id, level);
    }

    // ----------------------------------------------------------------- draws

    /// @notice Settles up to DEFAULT_BATCH queued trades, each with its own
    ///         draws, and refunds the caller's gas out of the protocol's share.
    function fish() external nonReentrant returns (uint256 settled) {
        if (paused) revert Paused();
        uint256 gasStart = gasleft();
        bool touched;
        (settled, touched) = _settle(DEFAULT_BATCH);
        if (!touched) revert NothingToDo();
        _refundGas(gasStart);
    }

    /// @notice The same, bounded by hand for a long queue.
    function fishUpTo(uint256 maxTrades) external nonReentrant returns (uint256 settled) {
        if (paused) revert Paused();
        uint256 gasStart = gasleft();
        bool touched;
        (settled, touched) = _settle(maxTrades);
        if (!touched) revert NothingToDo();
        _refundGas(gasStart);
    }

    /// Walks the queue from the oldest trade. Stops at one that is too fresh to
    /// have a block hash yet, and re-stamps one whose hash has aged out.
    /// Returns what it settled, and whether it did anything at all: re-stamping
    /// a stale trade is work too, and must not be thrown away by a revert.
    function _settle(uint256 maxTrades) internal returns (uint256 settled, bool touched) {
        uint256 h = head;
        uint256 t = tail;
        if (h >= t || maxTrades == 0) return (0, false);

        // the active lists and the holding bar are read once for the whole batch
        (uint256 n1, uint256 n2, uint256 n3, uint256 n4) = activeCounts();
        uint256 total = W1 * n1 + W2 * n2 + W3 * n3 + W4 * n4;
        uint256[5] memory need = _holdTable();

        uint256 booked;
        uint256 creatorTotal;
        uint256 gasTotal;
        uint256 done;
        uint256 fund = gasFund;
        while (h < t && done < maxTrades) {
            uint256 e = queue[h];
            uint256 at = uint64(e);
            if (block.number <= at) break; // this block's hash does not exist yet
            uint256 amount = e >> 64;
            bytes32 seed = blockhash(at);
            if (seed == bytes32(0)) {
                // Older than the window the chain keeps hashes for. It goes to
                // the back of the queue with a fresh block to be drawn from —
                // still one nobody can see yet — and the walk carries on, so a
                // backlog that fell behind does not block everything after it.
                delete queue[h];
                queue[t] = (amount << 64) | uint64(block.number);
                emit TradeRestamped(h, block.number);
                unchecked { h++; t++; done++; }
                touched = true;
                continue;
            }
            delete queue[h];
            emit TradeSettled(h, amount, total);
            unchecked { h++; done++; }
            settled += amount;

            if (total == 0) {
                creatorTotal += amount; // no live feesher: the whole fee is the protocol's
                continue;
            }
            uint256 creatorCut = amount / PROTOCOL_SHARE_DIVISOR;
            creatorTotal += creatorCut;
            uint256 raffle = amount - creatorCut;
            // the cost of handing this out is carried by the share being handed
            // out, never by the protocol's sixth, and only until the fund is full
            uint256 gasCut = (raffle * gasFundBps) / 10_000;
            if (gasCut != 0) {
                raffle -= gasCut;
                gasTotal += gasCut;
            }
            booked += raffle;
            uint256 share = raffle / SHARES_PER_FEE;
            for (uint256 i = 1; i <= SHARES_PER_FEE; i++) {
                // the rounding remainder rides on the last share
                uint256 cut = i == SHARES_PER_FEE ? raffle - share * (SHARES_PER_FEE - 1) : share;
                uint256 tokenId;
                // up to a few tries: each one that no longer qualifies is taken
                // out of the lists and the share is drawn again
                for (uint256 t2 = 0; t2 < DRAW_TRIES && total != 0; t2++) {
                    uint256 pick = _pickToken(seed, total, n1, n2, n3);
                    if (_qualifies(pick, need)) { tokenId = pick; break; }
                    _clearActive(pick, activeLevel[pick]);
                    (n1, n2, n3, n4) = activeCounts();
                    total = W1 * n1 + W2 * n2 + W3 * n3 + W4 * n4;
                }
                if (tokenId == 0) {
                    // nobody left who qualifies: the share is the protocol's
                    creatorTotal += cut;
                    booked -= cut;
                    continue;
                }
                caught[tokenId] += cut;
                emit Caught(tokenId, cut);
            }
        }
        if (t != tail) tail = uint128(t); // entries sent to the back of the queue
        if (settled == 0) {
            if (touched) head = uint128(h);
            return (0, touched);
        }
        touched = true;
        head = uint128(h);
        queued -= settled;
        if (booked != 0) reserved += booked;
        if (gasTotal != 0) gasFund = fund + gasTotal;
        _bookProtocol(creatorTotal);
    }

    /// Maps r = keccak(seed, nonce) % total to a (level, index) in the pond's
    /// own per-level lists of active feeshers. No external call: the lists live
    /// here, which is what makes a draw cheap.
    function _pickToken(bytes32 seed, uint256 total, uint256 n1, uint256 n2, uint256 n3)
        internal
        returns (uint256 tokenId)
    {
        uint256 r = uint256(keccak256(abi.encodePacked(seed, drawNonce++))) % total;
        uint256 level;
        uint256 index;
        if (r < W1 * n1) {
            (level, index) = (1, r / W1);
        } else if ((r -= W1 * n1) < W2 * n2) {
            (level, index) = (2, r / W2);
        } else if ((r -= W2 * n2) < W3 * n3) {
            (level, index) = (3, r / W3);
        } else {
            (level, index) = (4, (r - W3 * n3) / W4);
        }
        return _active[uint8(level)][index];
    }

    /// Whether this feesher's holder still keeps what its level asks for. A
    /// burned one, or one whose wallet fell short, does not qualify.
    function _qualifies(uint256 id, uint256[5] memory need) internal view returns (bool) {
        uint8 level = activeLevel[id];
        if (level == 0) return false;
        if (need[level] == 0) return true; // nothing asked for at this level
        address holder = activeHolder[id];
        if (holder == address(0)) return false;
        return IERC20Balance(feeshToken).balanceOf(holder) >= need[level];
    }

    /// Pays the caller out of `gasFund` — money the pool set aside from its own
    /// share for exactly this. The roller is topped back up to its float, so it
    /// never has to be refilled by hand; anyone else is paid what the call
    /// burned. The protocol's sixth is never touched, and an empty fund never
    /// reverts the settlement.
    function _refundGas(uint256 gasStart) internal {
        uint256 cost = (gasStart - gasleft() + REFUND_OVERHEAD) * tx.gasprice;
        if (msg.sender == roller && rollerTargetWei != 0) {
            // Keep the roller at its float rather than paying it per call. Its
            // balance still holds the gas of this very call (the EVM charges at
            // the end), so the float is measured against `have - cost`: it ends
            // the call at the float, never above it and never drifting up.
            uint256 have = msg.sender.balance;
            uint256 room = rollerTargetWei + cost > have ? rollerTargetWei + cost - have : 0;
            cost = room;
        } else if (cost > maxRefundWei) {
            cost = maxRefundWei;
        }
        if (cost == 0) return;
        uint256 fund = gasFund;
        if (cost > fund) cost = fund;
        if (cost == 0) return;
        gasFund = fund - cost;
        (bool ok, ) = msg.sender.call{value: cost, gas: 30_000}("");
        if (ok) emit GasRefunded(msg.sender, cost);
        else gasFund = fund; // put it back; the settlement still stands
    }

    // ---------------------------------------------------------------- payouts

    /// @notice Moves what these feeshers have caught into their own wallets,
    ///         settling queued trades on the way so the queue keeps moving.
    ///         Callable by anyone: the money can only ever go to the wallet of
    ///         the feesher it was drawn for. Feeshers with an empty catch are
    ///         skipped, so a whole collection can be passed at once.
    function pull(uint256[] calldata ids) external nonReentrant returns (uint256 total) {
        uint256 gasStart = gasleft();
        // a pull still works while the draws are off: what is already booked to
        // a feesher stays reachable by its holder
        (uint256 settled, bool touched) = paused ? (uint256(0), false) : _settle(DEFAULT_BATCH);
        settled; // the refund comes from the gas fund, not from what was settled
        uint256[5] memory need = _holdTable();
        address lastHolder;
        uint256 lastHeld;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = caught[id];
            if (amount == 0) continue;
            // The catch only comes out while its holder still keeps the token,
            // priced at the feesher's REAL level — a forged feesher that was
            // never re-activated must not be let out at its old, cheaper bar.
            uint8 level = nft.levelOf(id);
            address holder = _ownerOrZero(id);
            if (holder == address(0)) continue;
            // the owner is in hand anyway: if it is not the wallet this
            // activation was made on, the activation is over
            uint8 was = activeLevel[id];
            if (was != 0 && activeHolder[id] != holder) {
                _clearActive(id, was);
                touched = true; // ending a stale activation is work: do not revert it away
            }
            if (holder != lastHolder) {
                lastHolder = holder;
                lastHeld = IERC20Balance(feeshToken).balanceOf(holder);
            }
            if (lastHeld < need[level]) continue;
            caught[id] = 0;
            reserved -= amount;
            total += amount;
            address wallet = nft.walletAddress(id);
            emit Pulled(id, wallet, amount);
            _pay(wallet, amount);
        }
        // settling is work in its own right: a pull that only moved the queue
        // must not be reverted, or that work would be thrown away
        if (total == 0 && !touched) revert NothingToPull();
        if (settled != 0) _refundGas(gasStart);
    }

    /// @notice Books the catch of a token that no longer exists (the collection
    ///         burns one token per forge) to the protocol, so it is not stuck.
    ///         Pull before forging to keep it. Callable by anyone.
    function sweepBurned(uint256 id) external nonReentrant {
        if (_alive(id)) revert TokenAlive(id);
        uint256 amount = caught[id];
        if (amount == 0) revert NothingToPull();
        caught[id] = 0;
        reserved -= amount;
        _bookProtocol(amount);
    }

    function _bookProtocol(uint256 amount) internal {
        if (amount == 0) return;
        protocolOwed += amount;
        emit ProtocolBooked(amount, protocolOwed);
    }

    /// @notice Pays the protocol's booked share to `protocolRecipient`. Only the
    ///         recipient or the owner can move it, and it can never touch what
    ///         the draws booked to the feeshers.
    function withdrawProtocol() external nonReentrant returns (uint256 amount) {
        if (msg.sender != protocolRecipient && msg.sender != owner()) revert NotProtocol();
        amount = protocolOwed;
        if (amount == 0) revert NothingOwed();
        protocolOwed = 0;
        (bool ok, ) = protocolRecipient.call{value: amount}("");
        require(ok, "send");
        emit ProtocolWithdrawn(protocolRecipient, amount);
    }

    /// @notice Owner's hand pump for fees that belong to no one: anything in the
    ///         contract that is not queued for a draw, not booked to a feesher,
    ///         not held by `owed` and not the protocol's. A queued trade and a
    ///         booked catch are out of reach.
    function rescuePot(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        amount = pot();
        if (amount == 0) revert PotEmpty();
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "send");
        emit PotRescued(to, amount);
    }

    /// @notice Pays out a deferred payout. Callable by anyone.
    function withdrawOwed(address to) external nonReentrant {
        uint256 amount = owed[to];
        if (amount == 0) revert NothingOwed();
        owed[to] = 0;
        reserved -= amount;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "send");
        emit PaidOut(to, amount);
    }

    /// A push that never reverts the call: a recipient that rejects ETH or runs
    /// out of the stipend is credited for `withdrawOwed` instead. A feesher
    /// wallet is an ERC-6551 account with a plain payable receive, and is often
    /// not deployed yet, so the stipend is ample.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount, gas: 30_000}("");
        if (ok) {
            emit PaidOut(to, amount);
        } else {
            owed[to] += amount;
            reserved += amount;
            emit PayoutDeferred(to, amount);
        }
    }

    function _alive(uint256 id) internal view returns (bool) {
        return _ownerOrZero(id) != address(0);
    }

    /// The holder, or zero if the feesher has been burned.
    function _ownerOrZero(uint256 id) internal view returns (address) {
        try nft.ownerOf(id) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    // ---------------------------------------------------------------- control

    function setProtocolRecipient(address r) external onlyOwner {
        protocolRecipient = r;
    }

    /// @notice Where the token and its price are read from. `ethUsdOverrideE6`
    ///         wins over `ethUsdPool` and is what a network without a WETH/USDG
    ///         pool uses.
    function setPriceSource(
        address token,
        address manager,
        bytes32 poolId_,
        address ethUsdPool_,
        uint256 ethUsdOverrideE6_
    ) external onlyOwner {
        feeshToken = token;
        poolManager = IExtsload(manager);
        poolId = poolId_;
        ethUsdPool = ethUsdPool_;
        ethUsdOverrideE6 = ethUsdOverrideE6_;
        emit PriceSourceSet(token, manager, poolId_, ethUsdPool_, ethUsdOverrideE6_);
    }

    /// @notice Dollars (1e6) a holder must keep, per level of the feesher.
    function setUsdTargets(uint256 l1, uint256 l2, uint256 l3, uint256 l4) external onlyOwner {
        usdTargetE6[1] = l1;
        usdTargetE6[2] = l2;
        usdTargetE6[3] = l3;
        usdTargetE6[4] = l4;
        emit UsdTargetsSet(l1, l2, l3, l4);
    }

    /// @notice Ceiling on a single gas refund.
    function setRefundCap(uint256 maxWei) external onlyOwner {
        maxRefundWei = maxWei;
        emit RefundCapSet(maxWei);
    }

    /// @notice Smallest fee that gets a draw of its own. Anything below it waits
    ///         in `crumbs` and rides with the next fee, so a trade too small to
    ///         be worth handing out cannot cost more gas than it carries.
    function setMinFee(uint256 minFeeWei_) external onlyOwner {
        minFeeWei = minFeeWei_;
        emit MinFeeSet(minFeeWei_);
    }

    /// @notice How much of the pool's share is set aside to pay for the draws.
    function setGasFund(uint16 bps) external onlyOwner {
        if (bps > HARD_GAS_FUND_BPS) revert CapTooHigh();
        gasFundBps = bps;
        emit GasFundSet(bps);
    }

    /// @notice The wallet that runs the draws and the float the pond keeps it
    ///         at. Setting the float to zero pays it per call like anyone else.
    function setRoller(address roller_, uint256 targetWei) external onlyOwner {
        roller = roller_;
        rollerTargetWei = targetWei;
        emit RollerSet(roller_, targetWei);
    }

    /// @notice Stops the draws and activation. Holders can still pull what is
    ///         already booked to their feeshers.
    function setPaused(bool v) external onlyOwner {
        paused = v;
        emit PausedSet(v);
    }

    /// @notice Empties the pond. Deliberately two steps — the draws have to be
    ///         stopped first — because this reaches everything the contract
    ///         holds, including catches already booked to feeshers. It exists
    ///         for the day something is broken and the money has to come out.
    function drain(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (!paused) revert NotPaused();
        amount = address(this).balance;
        if (amount == 0) revert PotEmpty();
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "send");
        emit Drained(to, amount);
    }
}
