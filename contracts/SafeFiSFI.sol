// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ============================================================
 *  SafeFiSFI.sol  —  SFI Stablecoin Contract
 *  SafeFi Tech Solutions Ltd  |  Kasali Ayomide Emmanuel
 *  Version: 1.0.0  |  March 2026
 * ============================================================
 *
 *  WHAT THIS CONTRACT DOES:
 *  ─────────────────────────────────────────────────────────
 *  1. Maintains a 1:1 peg: 1 SFI = 1 USDC at all times
 *  2. Mints SFI only when a verified claim is approved
 *     (called by the ClaimEngine — no one else can mint)
 *  3. Burns SFI when a holder redeems for real USDC
 *  4. Enforces a 24–72 hour timelock on large mint operations
 *  5. Owner (SafeFi multisig) can pause in emergency
 *  6. No algorithmic mechanics — pure 1:1 USDC backing
 * ============================================================
 */

// ── Minimal ERC-20 interface for USDC ──────────────────────
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

// ── Reentrancy guard ────────────────────────────────────────
abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status != 2, "SFI: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

// ── Ownable (simple two-step) ───────────────────────────────
abstract contract Ownable {
    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed currentOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address _owner) {
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "SFI: not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "SFI: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

// ════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ════════════════════════════════════════════════════════════
contract SafeFiSFI is ReentrancyGuard, Ownable {

    // ── Token metadata ────────────────────────────────────
    string  public constant name     = "SafeFi Stable";
    string  public constant symbol   = "SFI";
    uint8   public constant decimals = 6;           // matches USDC decimals

    // ── State ─────────────────────────────────────────────
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ── USDC reserve ──────────────────────────────────────
    IERC20  public immutable USDC;                  // USDC contract address
    uint256 public usdcReserve;                     // USDC held in this vault

    // ── Access control ────────────────────────────────────
    address public claimEngine;                     // only address that can mint
    bool    public paused;

    // ── Timelock for large mints ──────────────────────────
    // Any single mint above LARGE_MINT_THRESHOLD requires
    // a 24-hour waiting period before execution.
    uint256 public constant LARGE_MINT_THRESHOLD = 50_000 * 1e6;  // 50,000 SFI
    uint256 public constant TIMELOCK_DELAY       = 24 hours;

    struct PendingMint {
        address recipient;
        uint256 amount;
        uint256 claimId;
        uint256 unlocksAt;
        bool    executed;
        bool    cancelled;
    }

    uint256 public pendingMintCount;
    mapping(uint256 => PendingMint) public pendingMints;

    // ── Events ────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event SFIMinted(address indexed recipient, uint256 amount, uint256 claimId);
    event SFIBurned(address indexed holder,   uint256 amount);
    event USDCDeposited(address indexed depositor, uint256 amount);
    event USDCWithdrawn(address indexed to,         uint256 amount);
    event ClaimEngineSet(address indexed oldEngine, address indexed newEngine);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event LargeMintQueued(uint256 indexed mintId, address recipient, uint256 amount, uint256 unlocksAt);
    event LargeMintExecuted(uint256 indexed mintId);
    event LargeMintCancelled(uint256 indexed mintId);

    // ── Constructor ───────────────────────────────────────
    /**
     * @param _usdc        Address of USDC token on this chain
     * @param _owner       SafeFi multisig wallet address
     */
    constructor(address _usdc, address _owner) Ownable(_owner) {
        require(_usdc  != address(0), "SFI: zero USDC address");
        require(_owner != address(0), "SFI: zero owner address");
        USDC = IERC20(_usdc);
    }

    // ════════════════════════════════════════════════════════
    //  MODIFIERS
    // ════════════════════════════════════════════════════════

    modifier onlyClaimEngine() {
        require(msg.sender == claimEngine, "SFI: caller is not ClaimEngine");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "SFI: contract is paused");
        _;
    }

    // ════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════

    /**
     * @notice Set or update the ClaimEngine address
     * @dev    Only the SafeFi multisig owner can call this
     */
    function setClaimEngine(address _claimEngine) external onlyOwner {
        require(_claimEngine != address(0), "SFI: zero ClaimEngine address");
        emit ClaimEngineSet(claimEngine, _claimEngine);
        claimEngine = _claimEngine;
    }

    /**
     * @notice Pause all minting and redemption (emergency use only)
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Resume normal operations
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Owner deposits USDC into the vault to back future SFI claims
     * @dev    SafeFi PremiumPool sends USDC here from the Protection Reserve
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "SFI: zero amount");
        bool ok = USDC.transferFrom(msg.sender, address(this), amount);
        require(ok, "SFI: USDC transfer failed");
        usdcReserve += amount;
        emit USDCDeposited(msg.sender, amount);
    }

    /**
     * @notice Emergency USDC withdrawal by owner (multisig only)
     * @dev    Cannot withdraw more than surplus (usdcReserve - totalSupply)
     */
    function emergencyWithdrawUSDC(address to, uint256 amount) external onlyOwner nonReentrant {
        uint256 surplus = usdcReserve > totalSupply ? usdcReserve - totalSupply : 0;
        require(amount <= surplus, "SFI: would undercollateralise");
        usdcReserve -= amount;
        bool ok = USDC.transfer(to, amount);
        require(ok, "SFI: USDC transfer failed");
        emit USDCWithdrawn(to, amount);
    }

    // ════════════════════════════════════════════════════════
    //  MINTING  (ClaimEngine only)
    // ════════════════════════════════════════════════════════

    /**
     * @notice Mint SFI to a verified victim wallet
     * @dev    Called exclusively by SafeFiClaimEngine after claim approval
     *         Small claims (<= LARGE_MINT_THRESHOLD) mint immediately.
     *         Large claims are queued with a 24-hour timelock.
     *
     * @param  recipient  Victim wallet address
     * @param  amount     SFI amount to mint (6 decimals, matching USDC)
     * @param  claimId    ID from the ClaimEngine for audit trail
     */
    function mint(
        address recipient,
        uint256 amount,
        uint256 claimId
    ) external onlyClaimEngine whenNotPaused nonReentrant returns (uint256 mintId) {
        require(recipient != address(0), "SFI: zero recipient");
        require(amount > 0,              "SFI: zero amount");
        require(usdcReserve >= totalSupply + amount, "SFI: insufficient USDC reserve");

        if (amount <= LARGE_MINT_THRESHOLD) {
            // ── Instant mint for normal-sized claims ──
            _mint(recipient, amount);
            emit SFIMinted(recipient, amount, claimId);
            return type(uint256).max; // no pending mint ID
        } else {
            // ── Queue large mint with 24-hour timelock ──
            mintId = pendingMintCount++;
            uint256 unlocksAt = block.timestamp + TIMELOCK_DELAY;
            pendingMints[mintId] = PendingMint({
                recipient:  recipient,
                amount:     amount,
                claimId:    claimId,
                unlocksAt:  unlocksAt,
                executed:   false,
                cancelled:  false
            });
            emit LargeMintQueued(mintId, recipient, amount, unlocksAt);
            return mintId;
        }
    }

    /**
     * @notice Execute a queued large mint after the timelock has expired
     * @dev    Anyone can call this — the check enforces the delay
     */
    function executePendingMint(uint256 mintId) external whenNotPaused nonReentrant {
        PendingMint storage pm = pendingMints[mintId];
        require(!pm.executed,              "SFI: already executed");
        require(!pm.cancelled,             "SFI: cancelled");
        require(block.timestamp >= pm.unlocksAt, "SFI: timelock not expired");
        require(usdcReserve >= totalSupply + pm.amount, "SFI: insufficient USDC reserve");

        pm.executed = true;
        _mint(pm.recipient, pm.amount);
        emit SFIMinted(pm.recipient, pm.amount, pm.claimId);
        emit LargeMintExecuted(mintId);
    }

    /**
     * @notice Cancel a queued large mint (owner only — e.g. false positive)
     */
    function cancelPendingMint(uint256 mintId) external onlyOwner {
        PendingMint storage pm = pendingMints[mintId];
        require(!pm.executed,  "SFI: already executed");
        require(!pm.cancelled, "SFI: already cancelled");
        pm.cancelled = true;
        emit LargeMintCancelled(mintId);
    }

    // ════════════════════════════════════════════════════════
    //  REDEMPTION  (any SFI holder)
    // ════════════════════════════════════════════════════════

    /**
     * @notice Redeem SFI for USDC at 1:1 ratio
     * @dev    Burns the SFI and sends equivalent USDC to the caller
     * @param  amount  Amount of SFI to redeem (must have balance)
     */
    function redeem(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0,                        "SFI: zero amount");
        require(balanceOf[msg.sender] >= amount,   "SFI: insufficient SFI balance");
        require(usdcReserve >= amount,             "SFI: insufficient USDC in vault");

        _burn(msg.sender, amount);
        usdcReserve -= amount;

        bool ok = USDC.transfer(msg.sender, amount);
        require(ok, "SFI: USDC transfer failed");

        emit SFIBurned(msg.sender, amount);
    }

    // ════════════════════════════════════════════════════════
    //  ERC-20 STANDARD FUNCTIONS
    // ════════════════════════════════════════════════════════

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "SFI: allowance exceeded");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    // ════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════

    /**
     * @notice Returns the collateralisation ratio as a percentage
     *         Should always be >= 100 (100% backed)
     */
    function collateralisationRatio() external view returns (uint256) {
        if (totalSupply == 0) return type(uint256).max;
        return (usdcReserve * 100) / totalSupply;
    }

    /**
     * @notice Confirms whether the vault is fully collateralised
     */
    function isFullyCollateralised() external view returns (bool) {
        return usdcReserve >= totalSupply;
    }

    /**
     * @notice Returns details of a pending large mint
     */
    function getPendingMint(uint256 mintId) external view returns (PendingMint memory) {
        return pendingMints[mintId];
    }

    // ════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ════════════════════════════════════════════════════════

    function _mint(address to, uint256 amount) internal {
        totalSupply        += amount;
        balanceOf[to]      += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0),            "SFI: transfer to zero address");
        require(balanceOf[from] >= amount,   "SFI: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
