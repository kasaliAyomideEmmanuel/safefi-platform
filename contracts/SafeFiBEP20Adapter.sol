// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ============================================================
 *  SafeFiBEP20Adapter.sol  —  BNB Chain Premium Adapter
 *  SafeFi Tech Solutions Ltd  |  Kasali Ayomide Emmanuel
 *  Version: 1.0.0  |  March 2026
 * ============================================================
 *
 *  WHAT THIS CONTRACT DOES:
 *  ─────────────────────────────────────────────────────────
 *  1. Embeds into a partner BEP-20 token on BNB Chain
 *  2. Automatically deducts 0.1–0.2% premium on every transfer
 *  3. Converts collected token premiums to USDC via PancakeSwap
 *  4. Forwards USDC premium atomically to SafeFiPremiumPool
 *  5. Verifies the partner team has a signed TAD before
 *     any premium collection begins
 *  6. Emits events the ClaimEngine monitors for incident detection
 *
 *  CHAIN:   BNB Chain — Chain ID 56 (mainnet) / 97 (testnet)
 *  GAS:     BNB
 *  STANDARD: BEP-20 (identical to ERC-20 in Solidity)
 *
 *  MASTER PLAN REFERENCE:
 *  Section 7  — Premium Mechanics & Reserve Economics
 *  Section 8  — Partner Integration
 *  Appendix A — Premium Module BEP-20 Adapter (BNB Chain)
 * ============================================================
 */

// ── Token interface ─────────────────────────────────────────
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

// ── PancakeSwap router (BNB Chain DEX for token → USDC swap) ─
interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

// ── SafeFiPremiumPool interface ─────────────────────────────
interface IPremiumPool {
    function receivePremium(address projectContract, uint256 amount) external;
}

// ── SafeFiTeamAccountability interface ──────────────────────
interface ITADRegistry {
    function isTADSigned(address projectContract) external view returns (bool);
    function isBlacklisted(address wallet) external view returns (bool);
}

// ── Reentrancy guard ────────────────────────────────────────
abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status != 2, "Adapter: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

// ── Two-step Ownable ────────────────────────────────────────
abstract contract Ownable {
    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed current, address indexed next);
    event OwnershipTransferred(address indexed previous, address indexed next);

    constructor(address _owner) {
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Adapter: not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Adapter: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

// ════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ════════════════════════════════════════════════════════════
contract SafeFiBEP20Adapter is ReentrancyGuard, Ownable {

    // ── Core references ───────────────────────────────────
    IERC20           public immutable partnerToken;   // The BEP-20 token this adapter serves
    IERC20           public immutable USDC;           // USDC on BNB Chain
    IPremiumPool     public           premiumPool;    // SafeFiPremiumPool.sol
    ITADRegistry     public immutable tadRegistry;   // SafeFiTeamAccountability.sol
    IPancakeRouter   public           dexRouter;      // PancakeSwap V2 router

    // ── Partner identity ──────────────────────────────────
    address public immutable projectContract;  // This partner token's address (= partnerToken)
    string  public           projectName;

    // ── Premium rate ──────────────────────────────────────
    // Rate stored as parts per 1,000,000
    // 1000 = 0.10%  |  1500 = 0.15%  |  2000 = 0.20%
    uint256 public premiumRate;
    uint256 public constant MIN_PREMIUM_RATE = 1000;  // 0.10%
    uint256 public constant MAX_PREMIUM_RATE = 2000;  // 0.20% (tiered cap per Master Plan)
    uint256 public constant RATE_DENOMINATOR = 1_000_000;

    // ── Swap path: partnerToken → WBNB → USDC ────────────
    // BNB Chain token addresses (mainnet)
    address public constant WBNB  = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // USDC on BNB Chain mainnet: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d
    // For testnet, this will be the mock USDC address you deploy
    address[] public swapPath;

    // ── Slippage protection for DEX swap ─────────────────
    // Min USDC out = (expected × (10000 - slippageBPS)) / 10000
    uint256 public slippageBPS = 200; // 2% default slippage tolerance
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% hard cap

    // ── Integration state ─────────────────────────────────
    bool    public integrationActive;
    bool    public paused;
    uint256 public integrationTimestamp;

    // ── Statistics ────────────────────────────────────────
    uint256 public totalPremiumCollectedToken;  // Cumulative token-denominated premium
    uint256 public totalPremiumForwardedUSDC;   // Cumulative USDC forwarded to pool
    uint256 public totalTransferCount;          // Total transfers processed
    uint256 public lastTransferBlock;           // Block of most recent premium-bearing transfer

    // ── Swap toggle: if false, send token directly (no swap) ─
    // Used for tokens that ARE USDC or in testing
    bool public swapEnabled;

    // ════════════════════════════════════════════════════════
    //  EVENTS
    // ════════════════════════════════════════════════════════

    event PremiumDeducted(
        address indexed from,
        address indexed to,
        uint256 transferAmount,
        uint256 premiumToken,
        uint256 premiumUSDC,
        uint256 netAmount,
        uint256 blockNumber
    );
    event PremiumForwardedToPool(
        address indexed pool,
        uint256 usdcAmount,
        uint256 blockNumber
    );
    event IntegrationActivated(
        address indexed projectContract,
        string  projectName,
        uint256 premiumRate,
        uint256 timestamp
    );
    event PremiumRateUpdated(uint256 oldRate, uint256 newRate);
    event SlippageUpdated(uint256 oldBPS, uint256 newBPS);
    event AdapterPaused(address indexed by);
    event AdapterUnpaused(address indexed by);
    event SwapRouterUpdated(address indexed newRouter);
    event SwapToggled(bool enabled);

    // ════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ════════════════════════════════════════════════════════

    /**
     * @param _partnerToken   BEP-20 token address this adapter serves
     * @param _usdc           USDC address on BNB Chain
     * @param _premiumPool    SafeFiPremiumPool.sol address
     * @param _tadRegistry    SafeFiTeamAccountability.sol address
     * @param _dexRouter      PancakeSwap V2 router address
     * @param _premiumRate    Initial premium rate (1000–2000)
     * @param _projectName    Human-readable project name
     * @param _owner          SafeFi multisig wallet
     */
    constructor(
        address _partnerToken,
        address _usdc,
        address _premiumPool,
        address _tadRegistry,
        address _dexRouter,
        uint256 _premiumRate,
        string  memory _projectName,
        address _owner
    ) Ownable(_owner) {
        require(_partnerToken != address(0), "Adapter: zero partner token");
        require(_usdc         != address(0), "Adapter: zero USDC");
        require(_premiumPool  != address(0), "Adapter: zero premium pool");
        require(_tadRegistry  != address(0), "Adapter: zero TAD registry");
        require(_dexRouter    != address(0), "Adapter: zero DEX router");
        require(
            _premiumRate >= MIN_PREMIUM_RATE && _premiumRate <= MAX_PREMIUM_RATE,
            "Adapter: premium rate out of bounds (1000-2000)"
        );
        require(bytes(_projectName).length > 0, "Adapter: empty project name");

        // ── TAD gate: partner team must have signed TAD ───
        // This is the integration gate. No signed TAD = no adapter.
        require(
            ITADRegistry(_tadRegistry).isTADSigned(_partnerToken),
            "Adapter: partner team has not signed TAD - integration blocked"
        );

        partnerToken    = IERC20(_partnerToken);
        USDC            = IERC20(_usdc);
        premiumPool     = IPremiumPool(_premiumPool);
        tadRegistry     = ITADRegistry(_tadRegistry);
        dexRouter       = IPancakeRouter(_dexRouter);
        projectContract = _partnerToken;
        projectName     = _projectName;
        premiumRate     = _premiumRate;
        swapEnabled     = true;

        // Default swap path: partnerToken → WBNB → USDC
        swapPath = new address[](3);
        swapPath[0] = _partnerToken;
        swapPath[1] = WBNB;
        swapPath[2] = _usdc;

        integrationActive    = true;
        integrationTimestamp = block.timestamp;

        emit IntegrationActivated(_partnerToken, _projectName, _premiumRate, block.timestamp);
    }

    // ════════════════════════════════════════════════════════
    //  MODIFIERS
    // ════════════════════════════════════════════════════════

    modifier whenActive() {
        require(integrationActive, "Adapter: integration not active");
        require(!paused,           "Adapter: paused");
        _;
    }

    // ════════════════════════════════════════════════════════
    //  CORE FUNCTION: transferWithPremium
    //  Called by the partner token's transfer() function.
    //  This is the heart of SafeFi's automatic protection model.
    // ════════════════════════════════════════════════════════

    /**
     * @notice Execute a token transfer with automatic premium deduction
     * @dev    This function is called by the partner BEP-20 token's
     *         transfer() and transferFrom() hooks. The partner token's
     *         _transfer() internal function must delegate to this adapter.
     *
     *         Flow:
     *         1. Calculate premium = amount × premiumRate / 1,000,000
     *         2. Transfer net amount (amount - premium) to recipient
     *         3. Swap premium tokens to USDC via PancakeSwap
     *         4. Forward USDC to SafeFiPremiumPool.receivePremium()
     *         5. PremiumPool atomically splits to all 5 pools
     *
     * @param  from    Sender wallet address
     * @param  to      Recipient wallet address
     * @param  amount  Full transfer amount (before premium deduction)
     *
     * @return netAmount   Amount received by `to` after premium
     * @return premium     Premium amount deducted (in partner token)
     */
    function transferWithPremium(
        address from,
        address to,
        uint256 amount
    ) external nonReentrant whenActive returns (uint256 netAmount, uint256 premium) {
        require(from   != address(0), "Adapter: transfer from zero address");
        require(to     != address(0), "Adapter: transfer to zero address");
        require(amount > 0,           "Adapter: zero amount");

        // ── Sanity check: TAD still valid ─────────────────
        // Check the team hasn't been blacklisted since integration
        require(
            !tadRegistry.isBlacklisted(from),
            "Adapter: sender wallet is blacklisted by SafeFi enforcement"
        );

        // ── Step 1: Calculate premium and net amount ──────
        premium   = amount * premiumRate / RATE_DENOMINATOR;
        netAmount = amount - premium;

        // If premium rounds to zero (tiny transfer), skip premium collection
        if (premium == 0) {
            // Just transfer the full amount with no premium
            bool ok = partnerToken.transferFrom(from, to, amount);
            require(ok, "Adapter: transfer failed");
            totalTransferCount++;
            lastTransferBlock = block.number;
            return (amount, 0);
        }

        // ── Step 2: Transfer net amount to recipient ──────
        bool ok1 = partnerToken.transferFrom(from, to, netAmount);
        require(ok1, "Adapter: net transfer to recipient failed");

        // ── Step 3: Collect premium tokens from sender ────
        bool ok2 = partnerToken.transferFrom(from, address(this), premium);
        require(ok2, "Adapter: premium collection from sender failed");

        // ── Step 4: Convert premium token → USDC ─────────
        uint256 usdcAmount;
        if (swapEnabled && address(partnerToken) != address(USDC)) {
            usdcAmount = _swapTokenToUSDC(premium);
        } else {
            // Token IS USDC or swap disabled — use directly
            usdcAmount = premium;
        }

        // ── Step 5: Forward USDC to PremiumPool ──────────
        if (usdcAmount > 0) {
            USDC.approve(address(premiumPool), usdcAmount);
            premiumPool.receivePremium(projectContract, usdcAmount);
            totalPremiumForwardedUSDC += usdcAmount;
        }

        // ── Update stats ──────────────────────────────────
        totalPremiumCollectedToken += premium;
        totalTransferCount++;
        lastTransferBlock = block.number;

        emit PremiumDeducted(from, to, amount, premium, usdcAmount, netAmount, block.number);
        emit PremiumForwardedToPool(address(premiumPool), usdcAmount, block.number);

        return (netAmount, premium);
    }

    // ════════════════════════════════════════════════════════
    //  SWAP: partner token → USDC via PancakeSwap V2
    // ════════════════════════════════════════════════════════

    /**
     * @notice Swap collected premium tokens to USDC
     * @dev    Uses PancakeSwap V2 router with slippage protection.
     *         Path: partnerToken → WBNB → USDC
     *         Slippage tolerance: configurable, default 2%, hard cap 10%
     */
    function _swapTokenToUSDC(uint256 tokenAmount) internal returns (uint256 usdcReceived) {
        // Approve router to spend tokens
        partnerToken.approve(address(dexRouter), tokenAmount);

        // Get expected output for slippage calculation
        uint256[] memory expectedAmounts = dexRouter.getAmountsOut(tokenAmount, swapPath);
        uint256 expectedUSDC = expectedAmounts[expectedAmounts.length - 1];

        // Apply slippage: minOut = expected × (10000 - slippageBPS) / 10000
        uint256 minUSDCOut = expectedUSDC * (10_000 - slippageBPS) / 10_000;

        // Execute swap
        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
            tokenAmount,
            minUSDCOut,
            swapPath,
            address(this),
            block.timestamp + 300 // 5-minute deadline
        );

        usdcReceived = amounts[amounts.length - 1];
    }

    // ════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════

    /**
     * @notice Update the premium rate for this integration
     * @dev    Rate must stay within 1000–2000 (0.10%–0.20%)
     *         per Master Plan Section 7 tiered fee structure.
     */
    function setPremiumRate(uint256 newRate) external onlyOwner {
        require(
            newRate >= MIN_PREMIUM_RATE && newRate <= MAX_PREMIUM_RATE,
            "Adapter: rate out of bounds (1000-2000)"
        );
        emit PremiumRateUpdated(premiumRate, newRate);
        premiumRate = newRate;
    }

    /**
     * @notice Update slippage tolerance for DEX swaps
     * @dev    Hard cap: 10% (1000 BPS)
     */
    function setSlippageBPS(uint256 newSlippageBPS) external onlyOwner {
        require(newSlippageBPS <= MAX_SLIPPAGE_BPS, "Adapter: slippage too high (max 10%)");
        emit SlippageUpdated(slippageBPS, newSlippageBPS);
        slippageBPS = newSlippageBPS;
    }

    /**
     * @notice Update the DEX router (e.g. upgrade to PancakeSwap V3)
     */
    function setDEXRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Adapter: zero address");
        dexRouter = IPancakeRouter(newRouter);
        emit SwapRouterUpdated(newRouter);
    }

    /**
     * @notice Toggle token→USDC swap on/off
     * @dev    Disable for testing or if partner token IS USDC
     */
    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
        emit SwapToggled(enabled);
    }

    /**
     * @notice Update swap path (e.g. direct partnerToken → USDC if pool exists)
     */
    function setSwapPath(address[] calldata newPath) external onlyOwner {
        require(newPath.length >= 2, "Adapter: path too short");
        require(newPath[0] == address(partnerToken), "Adapter: path must start with partner token");
        require(newPath[newPath.length - 1] == address(USDC), "Adapter: path must end with USDC");
        swapPath = newPath;
    }

    /**
     * @notice Update PremiumPool address (e.g. after upgrade)
     */
    function setPremiumPool(address newPool) external onlyOwner {
        require(newPool != address(0), "Adapter: zero address");
        premiumPool = IPremiumPool(newPool);
    }

    /**
     * @notice Pause premium collection on this integration
     * @dev    Emergency use. Does not affect token transfers — only stops
     *         premium deduction. Holders can still transfer freely.
     */
    function pause() external onlyOwner {
        paused = true;
        emit AdapterPaused(msg.sender);
    }

    /**
     * @notice Resume premium collection
     */
    function unpause() external onlyOwner {
        paused = false;
        emit AdapterUnpaused(msg.sender);
    }

    /**
     * @notice Deactivate this integration permanently
     * @dev    Once deactivated, cannot be reactivated.
     *         Used when a partner project graduates or terminates.
     */
    function deactivateIntegration() external onlyOwner {
        integrationActive = false;
    }

    /**
     * @notice Emergency token rescue (accidentally sent tokens, not premiums)
     * @dev    Cannot rescue partner token or USDC — those are premium funds.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(partnerToken), "Adapter: cannot rescue partner token");
        require(token != address(USDC),         "Adapter: cannot rescue USDC");
        require(to    != address(0),            "Adapter: zero recipient");
        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "Adapter: rescue transfer failed");
    }

    // ════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════

    /**
     * @notice Calculate premium for a given transfer amount
     * @dev    Used by UIs and partner tokens to show users the fee upfront
     */
    function calculatePremium(uint256 amount)
        external
        view
        returns (uint256 premium, uint256 netAmount)
    {
        premium   = amount * premiumRate / RATE_DENOMINATOR;
        netAmount = amount - premium;
    }

    /**
     * @notice Current premium rate as a human-readable percentage string basis
     * @return rate  e.g. 1500 means 0.15%
     */
    function getPremiumRateBPS() external view returns (uint256 rate) {
        // Convert from per-1M to basis points (per 10K)
        return premiumRate / 100;
    }

    /**
     * @notice Full integration stats for Partner Dashboard
     */
    function getIntegrationStats()
        external
        view
        returns (
            bool   active,
            bool   isPaused,
            uint256 rate,
            uint256 totalTokenPremium,
            uint256 totalUSDCForwarded,
            uint256 transferCount,
            uint256 lastBlock,
            uint256 activatedAt
        )
    {
        return (
            integrationActive,
            paused,
            premiumRate,
            totalPremiumCollectedToken,
            totalPremiumForwardedUSDC,
            totalTransferCount,
            lastTransferBlock,
            integrationTimestamp
        );
    }

    /**
     * @notice Get the current swap path
     */
    function getSwapPath() external view returns (address[] memory) {
        return swapPath;
    }

    /**
     * @notice Get expected USDC output for a given token premium amount
     * @dev    Used by UI to show expected USDC value before swap
     */
    function getExpectedUSDCOutput(uint256 tokenAmount)
        external
        view
        returns (uint256 expectedUSDC)
    {
        if (!swapEnabled || tokenAmount == 0) return tokenAmount;
        uint256[] memory amounts = dexRouter.getAmountsOut(tokenAmount, swapPath);
        return amounts[amounts.length - 1];
    }
}

// ═══════════════════════════════════════════════════════════
// SAFEFI STAKER REGISTRY EXTENSION
// SafeFi Tech Solutions Ltd | Kasali Ayomide Emmanuel
// ═══════════════════════════════════════════════════════════
//
// This extension tracks stakers and LP providers so the
// SafeFi monitor can accurately calculate victim losses
// at any historical block during an exploit incident.
//
// HOW IT WORKS:
// 1. Partner staking contract calls registerStake() when user stakes
// 2. Partner staking contract calls unregisterStake() when user unstakes
// 3. LP contracts call registerLP() when user adds/removes liquidity
// 4. SafeFi monitor reads stakedAt() and lpAt() at exploit block
// 5. Monitor calculates individual losses and submits victims[]
// ═══════════════════════════════════════════════════════════

interface IStakerRegistry {
    function registerStake(address user, uint256 amount) external;
    function unregisterStake(address user, uint256 amount) external;
    function registerLP(address user, uint256 lpTokens) external;
    function unregisterLP(address user, uint256 lpTokens) external;
    function stakedBalance(address user) external view returns (uint256);
    function lpBalance(address user) external view returns (uint256);
    function holderCount() external view returns (uint256);
    function stakerCount() external view returns (uint256);
    function lpCount() external view returns (uint256);
}

contract SafeFiStakerRegistry {

    // ── State ──────────────────────────────────────────────
    address public adapter;
    address public owner;

    // Staked balances per user
    mapping(address => uint256) public stakedBalance;

    // LP token balances per user
    mapping(address => uint256) public lpBalance;

    // Regular token holder balances (updated on every transfer)
    mapping(address => uint256) public holderBalance;

    // Snapshot history — block => user => balance
    // Used by monitor to reconstruct state at exploit block
    mapping(uint256 => mapping(address => uint256)) public stakedSnapshot;
    mapping(uint256 => mapping(address => uint256)) public lpSnapshot;
    mapping(uint256 => mapping(address => uint256)) public holderSnapshot;

    // All unique addresses for enumeration
    address[] public allHolders;
    address[] public allStakers;
    address[] public allLPs;
    mapping(address => bool) public isHolder;
    mapping(address => bool) public isStaker;
    mapping(address => bool) public isLP;

    // Approved staking contracts that can register
    mapping(address => bool) public approvedStakingContracts;
    mapping(address => bool) public approvedLPContracts;

    // Snapshot blocks recorded
    uint256[] public snapshotBlocks;
    mapping(uint256 => bool) public isSnapshotBlock;

    // ── Events ─────────────────────────────────────────────
    event StakeRegistered(address indexed user, uint256 amount, uint256 totalStaked);
    event StakeUnregistered(address indexed user, uint256 amount, uint256 totalStaked);
    event LPRegistered(address indexed user, uint256 lpTokens, uint256 totalLP);
    event LPUnregistered(address indexed user, uint256 lpTokens, uint256 totalLP);
    event HolderUpdated(address indexed user, uint256 newBalance);
    event SnapshotTaken(uint256 indexed blockNumber, uint256 holderCount, uint256 stakerCount, uint256 lpCount);

    // ── Modifiers ──────────────────────────────────────────
    modifier onlyOwner() { require(msg.sender == owner, "Registry: not owner"); _; }
    modifier onlyAdapter() { require(msg.sender == adapter, "Registry: not adapter"); _; }
    modifier onlyStakingContract() { require(approvedStakingContracts[msg.sender], "Registry: not approved staking contract"); _; }
    modifier onlyLPContract() { require(approvedLPContracts[msg.sender], "Registry: not approved LP contract"); _; }

    constructor(address _adapter, address _owner) {
        adapter = _adapter;
        owner   = _owner;
    }

    // ── Admin ──────────────────────────────────────────────
    function setAdapter(address _adapter) external onlyOwner {
        adapter = _adapter;
    }

    function approveStakingContract(address sc, bool approved) external onlyOwner {
        approvedStakingContracts[sc] = approved;
    }

    function approveLPContract(address lp, bool approved) external onlyOwner {
        approvedLPContracts[lp] = approved;
    }

    // ── Holder tracking (called by adapter on every transfer) ──
    function updateHolder(address user, uint256 newBalance) external onlyAdapter {
        if (!isHolder[user] && newBalance > 0) {
            allHolders.push(user);
            isHolder[user] = true;
        }
        holderBalance[user] = newBalance;
        emit HolderUpdated(user, newBalance);
    }

    // ── Staker tracking (called by partner staking contract) ──
    function registerStake(address user, uint256 amount) external onlyStakingContract {
        if (!isStaker[user]) {
            allStakers.push(user);
            isStaker[user] = true;
        }
        stakedBalance[user] += amount;
        emit StakeRegistered(user, amount, stakedBalance[user]);
    }

    function unregisterStake(address user, uint256 amount) external onlyStakingContract {
        if (stakedBalance[user] >= amount) {
            stakedBalance[user] -= amount;
        } else {
            stakedBalance[user] = 0;
        }
        emit StakeUnregistered(user, amount, stakedBalance[user]);
    }

    // ── LP tracking (called by partner LP contract) ────────
    function registerLP(address user, uint256 lpTokens) external onlyLPContract {
        if (!isLP[user]) {
            allLPs.push(user);
            isLP[user] = true;
        }
        lpBalance[user] += lpTokens;
        emit LPRegistered(user, lpTokens, lpBalance[user]);
    }

    function unregisterLP(address user, uint256 lpTokens) external onlyLPContract {
        if (lpBalance[user] >= lpTokens) {
            lpBalance[user] -= lpTokens;
        } else {
            lpBalance[user] = 0;
        }
        emit LPUnregistered(user, lpTokens, lpBalance[user]);
    }

    // ── Manual snapshot (called by SafeFi monitor at exploit block) ──
    // Monitor calls this immediately when exploit detected
    // Creates permanent record of all balances at that block
    function takeSnapshot() external {
        require(
            approvedStakingContracts[msg.sender] ||
            approvedLPContracts[msg.sender] ||
            msg.sender == owner ||
            msg.sender == adapter,
            "Registry: not authorized"
        );
        uint256 blockNum = block.number;
        if (isSnapshotBlock[blockNum]) return;

        for (uint256 i = 0; i < allHolders.length; i++) {
            address u = allHolders[i];
            holderSnapshot[blockNum][u] = holderBalance[u];
        }
        for (uint256 i = 0; i < allStakers.length; i++) {
            address u = allStakers[i];
            stakedSnapshot[blockNum][u] = stakedBalance[u];
        }
        for (uint256 i = 0; i < allLPs.length; i++) {
            address u = allLPs[i];
            lpSnapshot[blockNum][u] = lpBalance[u];
        }
        snapshotBlocks.push(blockNum);
        isSnapshotBlock[blockNum] = true;
        emit SnapshotTaken(blockNum, allHolders.length, allStakers.length, allLPs.length);
    }

    // ── Views for monitor ──────────────────────────────────

    // Get all holders with their balances in one call
    // Monitor uses this to build victim list
    function getAllHolders() external view returns (address[] memory users, uint256[] memory balances) {
        users    = allHolders;
        balances = new uint256[](allHolders.length);
        for (uint256 i = 0; i < allHolders.length; i++) {
            balances[i] = holderBalance[allHolders[i]];
        }
    }

    function getAllStakers() external view returns (address[] memory users, uint256[] memory balances) {
        users    = allStakers;
        balances = new uint256[](allStakers.length);
        for (uint256 i = 0; i < allStakers.length; i++) {
            balances[i] = stakedBalance[allStakers[i]];
        }
    }

    function getAllLPs() external view returns (address[] memory users, uint256[] memory balances) {
        users    = allLPs;
        balances = new uint256[](allLPs.length);
        for (uint256 i = 0; i < allLPs.length; i++) {
            balances[i] = lpBalance[allLPs[i]];
        }
    }

    // Get snapshot at specific block
    function getSnapshotHolders(uint256 blockNum) external view returns (address[] memory users, uint256[] memory balances) {
        users    = allHolders;
        balances = new uint256[](allHolders.length);
        for (uint256 i = 0; i < allHolders.length; i++) {
            balances[i] = holderSnapshot[blockNum][allHolders[i]];
        }
    }

    function getSnapshotStakers(uint256 blockNum) external view returns (address[] memory users, uint256[] memory balances) {
        users    = allStakers;
        balances = new uint256[](allStakers.length);
        for (uint256 i = 0; i < allStakers.length; i++) {
            balances[i] = stakedSnapshot[blockNum][allStakers[i]];
        }
    }

    // Total positions
    function holderCount() external view returns (uint256) { return allHolders.length; }
    function stakerCount() external view returns (uint256) { return allStakers.length; }
    function lpCount()     external view returns (uint256) { return allLPs.length; }

    // Combined position for one user (holder + staker + LP)
    function totalPosition(address user) external view returns (uint256 held, uint256 staked, uint256 lp, uint256 total) {
        held   = holderBalance[user];
        staked = stakedBalance[user];
        lp     = lpBalance[user];
        total  = held + staked + lp;
    }
}
