// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ============================================================
 *  SafeFiERC20Adapter.sol  —  Ethereum + Polygon Premium Adapter
 *  SafeFi Tech Solutions Ltd  |  Kasali Ayomide Emmanuel
 *  Version: 1.0.0  |  March 2026
 * ============================================================
 *
 *  WHAT THIS CONTRACT DOES:
 *  ─────────────────────────────────────────────────────────
 *  Identical premium logic to SafeFiBEP20Adapter.sol.
 *  Deployed separately on two chains:
 *
 *    Chain 1 — Ethereum  (Chain ID: 1)
 *      Gas token : ETH
 *      DEX       : Uniswap V2 / V3
 *      WETH addr : 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
 *
 *    Chain 2 — Polygon   (Chain ID: 137)
 *      Gas token : MATIC / POL
 *      DEX       : QuickSwap (Uniswap V2 fork)
 *      WMATIC    : 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
 *
 *  Same contract file — different constructor arguments per chain.
 *  Both are EVM-compatible ERC-20 chains — no Solidity changes needed.
 *
 *  DIFFERENCES FROM BEP-20 ADAPTER:
 *  - Native wrapped token is WETH (Ethereum) or WMATIC (Polygon)
 *    instead of WBNB. Swap path uses chain-appropriate wrapped native.
 *  - DEX router is Uniswap V2 (Ethereum) or QuickSwap (Polygon)
 *    instead of PancakeSwap.
 *  - Chain ID stored at deployment for audit trail clarity.
 *  - USDC address differs per chain (both are Circle-issued USDC).
 *
 *  MASTER PLAN REFERENCE:
 *  Section 7  — Premium Mechanics & Reserve Economics
 *  Section 8  — Partner Integration
 *  Appendix A — Multi-Chain Compatibility Summary
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

// ── Uniswap V2 / QuickSwap router interface ─────────────────
// Both use the same IUniswapV2Router02 interface
interface IUniswapV2Router {
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
contract SafeFiERC20Adapter is ReentrancyGuard, Ownable {

    // ── Core references ───────────────────────────────────
    IERC20           public immutable partnerToken;
    IERC20           public immutable USDC;
    IPremiumPool     public           premiumPool;
    ITADRegistry     public immutable tadRegistry;
    IUniswapV2Router public           dexRouter;

    // ── Partner identity ──────────────────────────────────
    address public immutable projectContract;
    string  public           projectName;

    // ── Chain identity ────────────────────────────────────
    // Stored at deployment — Ethereum (1) or Polygon (137)
    // Used in events and dashboards to distinguish deployments
    uint256 public immutable chainId;
    string  public           chainName;   // "Ethereum" or "Polygon"

    // Wrapped native token for this chain
    // Ethereum : WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    // Polygon  : WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
    address public immutable wrappedNative;

    // ── Premium rate ──────────────────────────────────────
    // 1000 = 0.10%  |  1500 = 0.15%  |  2000 = 0.20%
    uint256 public premiumRate;
    uint256 public constant MIN_PREMIUM_RATE = 1000;
    uint256 public constant MAX_PREMIUM_RATE = 2000;
    uint256 public constant RATE_DENOMINATOR = 1_000_000;

    // ── USDC addresses per chain ──────────────────────────
    // Ethereum mainnet USDC  : 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // Polygon mainnet USDC   : 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
    // (passed in constructor — no hardcoding for cross-chain flexibility)

    // ── Swap path: partnerToken → wrappedNative → USDC ───
    address[] public swapPath;

    // ── Slippage protection ───────────────────────────────
    uint256 public slippageBPS = 200;           // 2% default
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% hard cap

    // ── Integration state ─────────────────────────────────
    bool    public integrationActive;
    bool    public paused;
    uint256 public integrationTimestamp;

    // ── Statistics ────────────────────────────────────────
    uint256 public totalPremiumCollectedToken;
    uint256 public totalPremiumForwardedUSDC;
    uint256 public totalTransferCount;
    uint256 public lastTransferBlock;

    // ── Swap toggle ───────────────────────────────────────
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
        uint256 chainId,
        uint256 blockNumber
    );
    event PremiumForwardedToPool(
        address indexed pool,
        uint256 usdcAmount,
        uint256 chainId,
        uint256 blockNumber
    );
    event IntegrationActivated(
        address indexed projectContract,
        string  projectName,
        string  chainName,
        uint256 chainId,
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
     * @param _partnerToken    ERC-20 token address this adapter serves
     * @param _usdc            USDC address on THIS chain
     * @param _wrappedNative   WETH (Ethereum) or WMATIC (Polygon)
     * @param _premiumPool     SafeFiPremiumPool.sol address
     * @param _tadRegistry     SafeFiTeamAccountability.sol address
     * @param _dexRouter       Uniswap V2 (Ethereum) or QuickSwap (Polygon) router
     * @param _premiumRate     Initial rate (1000–2000)
     * @param _projectName     Human-readable project name
     * @param _chainName       "Ethereum" or "Polygon"
     * @param _owner           SafeFi multisig wallet
     *
     * @dev  Deploy this contract TWICE:
     *       Once on Ethereum mainnet (chainId = 1)
     *       Once on Polygon mainnet  (chainId = 137)
     *       With the appropriate addresses for each chain.
     */
    constructor(
        address _partnerToken,
        address _usdc,
        address _wrappedNative,
        address _premiumPool,
        address _tadRegistry,
        address _dexRouter,
        uint256 _premiumRate,
        string  memory _projectName,
        string  memory _chainName,
        address _owner
    ) Ownable(_owner) {
        require(_partnerToken  != address(0), "Adapter: zero partner token");
        require(_usdc          != address(0), "Adapter: zero USDC");
        require(_wrappedNative != address(0), "Adapter: zero wrapped native");
        require(_premiumPool   != address(0), "Adapter: zero premium pool");
        require(_tadRegistry   != address(0), "Adapter: zero TAD registry");
        require(_dexRouter     != address(0), "Adapter: zero DEX router");
        require(
            _premiumRate >= MIN_PREMIUM_RATE && _premiumRate <= MAX_PREMIUM_RATE,
            "Adapter: premium rate out of bounds (1000-2000)"
        );
        require(bytes(_projectName).length > 0, "Adapter: empty project name");
        require(bytes(_chainName).length  > 0,  "Adapter: empty chain name");

        // ── TAD gate ──────────────────────────────────────
        require(
            ITADRegistry(_tadRegistry).isTADSigned(_partnerToken),
            "Adapter: partner team has not signed TAD - integration blocked"
        );

        partnerToken    = IERC20(_partnerToken);
        USDC            = IERC20(_usdc);
        wrappedNative   = _wrappedNative;
        premiumPool     = IPremiumPool(_premiumPool);
        tadRegistry     = ITADRegistry(_tadRegistry);
        dexRouter       = IUniswapV2Router(_dexRouter);
        projectContract = _partnerToken;
        projectName     = _projectName;
        chainId         = block.chainid;
        chainName       = _chainName;
        premiumRate     = _premiumRate;
        swapEnabled     = true;

        // Default swap path: partnerToken → wrappedNative → USDC
        // e.g. on Ethereum: tokenX → WETH → USDC
        // e.g. on Polygon:  tokenX → WMATIC → USDC
        swapPath = new address[](3);
        swapPath[0] = _partnerToken;
        swapPath[1] = _wrappedNative;
        swapPath[2] = _usdc;

        integrationActive    = true;
        integrationTimestamp = block.timestamp;

        emit IntegrationActivated(
            _partnerToken, _projectName, _chainName,
            block.chainid, _premiumRate, block.timestamp
        );
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
    //  CORE: transferWithPremium
    // ════════════════════════════════════════════════════════

    /**
     * @notice Execute a token transfer with automatic premium deduction
     * @dev    Called by the partner ERC-20 token's _transfer() hook.
     *
     *         Flow:
     *         1. Calculate premium = amount × premiumRate / 1,000,000
     *         2. Transfer net (amount - premium) to recipient
     *         3. Collect premium tokens from sender
     *         4. Swap premium tokens → USDC via Uniswap/QuickSwap
     *         5. Forward USDC to SafeFiPremiumPool.receivePremium()
     *
     *         ClaimEngine monitors the PremiumDeducted event on this
     *         contract to track transfer activity and detect anomalies.
     *
     * @param  from    Sender wallet
     * @param  to      Recipient wallet
     * @param  amount  Full transfer amount before premium deduction
     *
     * @return netAmount  Amount received by `to`
     * @return premium    Token premium deducted
     */
    function transferWithPremium(
        address from,
        address to,
        uint256 amount
    ) external nonReentrant whenActive returns (uint256 netAmount, uint256 premium) {
        require(from   != address(0), "Adapter: from zero address");
        require(to     != address(0), "Adapter: to zero address");
        require(amount > 0,           "Adapter: zero amount");

        // ── Blacklist check ───────────────────────────────
        require(
            !tadRegistry.isBlacklisted(from),
            "Adapter: sender wallet is blacklisted by SafeFi enforcement"
        );

        // ── Step 1: Calculate premium ─────────────────────
        premium   = amount * premiumRate / RATE_DENOMINATOR;
        netAmount = amount - premium;

        // Skip premium for dust transfers
        if (premium == 0) {
            bool ok = partnerToken.transferFrom(from, to, amount);
            require(ok, "Adapter: transfer failed");
            totalTransferCount++;
            lastTransferBlock = block.number;
            return (amount, 0);
        }

        // ── Step 2: Net transfer to recipient ─────────────
        bool ok1 = partnerToken.transferFrom(from, to, netAmount);
        require(ok1, "Adapter: net transfer failed");

        // ── Step 3: Collect premium from sender ───────────
        bool ok2 = partnerToken.transferFrom(from, address(this), premium);
        require(ok2, "Adapter: premium collection failed");

        // ── Step 4: Swap token premium → USDC ────────────
        uint256 usdcAmount;
        if (swapEnabled && address(partnerToken) != address(USDC)) {
            usdcAmount = _swapTokenToUSDC(premium);
        } else {
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

        emit PremiumDeducted(
            from, to, amount, premium, usdcAmount,
            netAmount, chainId, block.number
        );
        emit PremiumForwardedToPool(address(premiumPool), usdcAmount, chainId, block.number);

        return (netAmount, premium);
    }

    // ════════════════════════════════════════════════════════
    //  SWAP: partner token → USDC
    //  Ethereum:  Uniswap V2 router
    //  Polygon:   QuickSwap router (same IUniswapV2Router interface)
    // ════════════════════════════════════════════════════════

    function _swapTokenToUSDC(uint256 tokenAmount) internal returns (uint256 usdcReceived) {
        partnerToken.approve(address(dexRouter), tokenAmount);

        uint256[] memory expectedAmounts = dexRouter.getAmountsOut(tokenAmount, swapPath);
        uint256 expectedUSDC = expectedAmounts[expectedAmounts.length - 1];
        uint256 minUSDCOut   = expectedUSDC * (10_000 - slippageBPS) / 10_000;

        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
            tokenAmount,
            minUSDCOut,
            swapPath,
            address(this),
            block.timestamp + 300
        );

        usdcReceived = amounts[amounts.length - 1];
    }

    // ════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════

    function setPremiumRate(uint256 newRate) external onlyOwner {
        require(
            newRate >= MIN_PREMIUM_RATE && newRate <= MAX_PREMIUM_RATE,
            "Adapter: rate out of bounds (1000-2000)"
        );
        emit PremiumRateUpdated(premiumRate, newRate);
        premiumRate = newRate;
    }

    function setSlippageBPS(uint256 newSlippageBPS) external onlyOwner {
        require(newSlippageBPS <= MAX_SLIPPAGE_BPS, "Adapter: slippage too high");
        emit SlippageUpdated(slippageBPS, newSlippageBPS);
        slippageBPS = newSlippageBPS;
    }

    function setDEXRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Adapter: zero address");
        dexRouter = IUniswapV2Router(newRouter);
        emit SwapRouterUpdated(newRouter);
    }

    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
        emit SwapToggled(enabled);
    }

    /**
     * @notice Update swap path
     * @dev    On Ethereum you might set a direct partnerToken → USDC path
     *         if a deep Uniswap pool exists, skipping WETH hop.
     *         On Polygon you might route through USDT instead of WMATIC.
     */
    function setSwapPath(address[] calldata newPath) external onlyOwner {
        require(newPath.length >= 2, "Adapter: path too short");
        require(
            newPath[0] == address(partnerToken),
            "Adapter: path must start with partner token"
        );
        require(
            newPath[newPath.length - 1] == address(USDC),
            "Adapter: path must end with USDC"
        );
        swapPath = newPath;
    }

    function setPremiumPool(address newPool) external onlyOwner {
        require(newPool != address(0), "Adapter: zero address");
        premiumPool = IPremiumPool(newPool);
    }

    function pause() external onlyOwner {
        paused = true;
        emit AdapterPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit AdapterUnpaused(msg.sender);
    }

    function deactivateIntegration() external onlyOwner {
        integrationActive = false;
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(partnerToken), "Adapter: cannot rescue partner token");
        require(token != address(USDC),         "Adapter: cannot rescue USDC");
        require(to    != address(0),            "Adapter: zero recipient");
        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "Adapter: rescue failed");
    }

    // ════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════

    function calculatePremium(uint256 amount)
        external
        view
        returns (uint256 premium, uint256 netAmount)
    {
        premium   = amount * premiumRate / RATE_DENOMINATOR;
        netAmount = amount - premium;
    }

    function getPremiumRateBPS() external view returns (uint256) {
        return premiumRate / 100;
    }

    function getIntegrationStats()
        external
        view
        returns (
            bool    active,
            bool    isPaused,
            uint256 rate,
            uint256 deployedChainId,
            string  memory deployedChainName,
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
            chainId,
            chainName,
            totalPremiumCollectedToken,
            totalPremiumForwardedUSDC,
            totalTransferCount,
            lastTransferBlock,
            integrationTimestamp
        );
    }

    function getSwapPath() external view returns (address[] memory) {
        return swapPath;
    }

    function getExpectedUSDCOutput(uint256 tokenAmount)
        external
        view
        returns (uint256 expectedUSDC)
    {
        if (!swapEnabled || tokenAmount == 0) return tokenAmount;
        uint256[] memory amounts = dexRouter.getAmountsOut(tokenAmount, swapPath);
        return amounts[amounts.length - 1];
    }

    /**
     * @notice Confirm which chain this adapter is deployed on
     * @dev    Safety check — confirms deployment chain matches intent
     */
    function getChainInfo()
        external
        view
        returns (uint256 deployedChainId, string memory name, address native)
    {
        return (chainId, chainName, wrappedNative);
    }
}
