// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ============================================================
 *  SafeFiTeamAccountability.sol  —  TAD Registry
 *  SafeFi Tech Solutions Ltd  |  Kasali Ayomide Emmanuel
 *  Version: 1.0.0  |  March 2026
 * ============================================================
 *
 *  WHAT THIS CONTRACT DOES:
 *  ─────────────────────────────────────────────────────────
 *  1. Registers partner project teams before integration
 *  2. Records cryptographically binding on-chain TAD signatures
 *     from every team member before their adapter is deployed
 *  3. Gates adapter deployment — no TAD signed = no integration
 *  4. Maintains the permanent on-chain enforcement registry:
 *       - Blacklisted wallets (confirmed bad actors)
 *       - Enforcement records (evidence hashes + referral status)
 *  5. Called by SafeFiClaimEngine after every confirmed incident
 *     to blacklist wallets and file forensics records
 *
 *  MASTER PLAN REFERENCE:
 *  Section 20 — Enforcement, Consequence & Recovery Pursuit
 *  Section 14 — Legal & Compliance Framework
 * ============================================================
 */

// ── Reentrancy guard ────────────────────────────────────────
abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status != 2, "TAD: reentrant call");
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
        require(msg.sender == owner, "TAD: not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "TAD: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}

// ════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ════════════════════════════════════════════════════════════
contract SafeFiTeamAccountability is ReentrancyGuard, Ownable {

    // ── Access control ────────────────────────────────────
    // Only the ClaimEngine can trigger enforcement actions.
    // Only the SafeFi admin (owner) can register teams and
    // appoint verifiers.
    address public claimEngine;
    mapping(address => bool) public isVerifier; // SafeFi KYC verifiers

    // ════════════════════════════════════════════════════════
    //  DATA STRUCTURES
    // ════════════════════════════════════════════════════════

    // ── Team registration status ──────────────────────────
    enum TeamStatus {
        Unregistered,   // 0 — not known to SafeFi
        Registered,     // 1 — registered, TAD not yet signed
        Active,         // 2 — TAD signed, integration live
        Suspended,      // 3 — temporarily suspended (e.g. audit lapsed)
        Blacklisted     // 4 — confirmed bad actor, permanently banned
    }

    // ── TAD record ────────────────────────────────────────
    // The Team Accountability Declaration binds the team legally
    // before any holder funds accumulate as premiums.
    struct TADRecord {
        address projectContract;    // Partner token contract address
        string  projectName;        // Human-readable project name
        address[] teamWallets;      // All wallets bound under this TAD
        bytes32   identityHash;     // Hash of KYC documents (stored off-chain)
        bytes32   tadContentHash;   // Hash of the exact TAD text agreed to
        uint256   signedAt;         // Block timestamp of on-chain signature
        uint256   signedBlock;      // Block number of on-chain signature
        address   signingWallet;    // Wallet that submitted the on-chain signature
        bool      kycVerified;      // Confirmed by SafeFi verifier
        TeamStatus status;
    }

    // ── Enforcement record ────────────────────────────────
    // Filed by ClaimEngine after every confirmed incident.
    // Immutable once written — permanent public record.
    struct EnforcementRecord {
        uint256 claimId;
        address projectContract;
        bytes32 evidenceHash;       // Cryptographic hash of the full evidence package
        address[] culpritWallets;   // Wallets confirmed responsible
        uint256 lossAmountUSD;      // Verified USD loss at time of incident
        uint256 filedAt;
        uint256 filedBlock;
        bool    fbiReferralFiled;   // FBI Cyber Division referral submitted
        bool    interpolReferralFiled; // Interpol referral submitted
        bool    fundsRecovered;     // True if any funds later recovered via legal action
        uint256 recoveredAmountUSD; // Amount recovered (flows back to Protection Reserve)
        string  status;             // e.g. "UNDER INVESTIGATION", "REFERRED", "RESOLVED"
    }

    // ── Blacklist record ─────────────────────────────────
    struct BlacklistEntry {
        address wallet;
        uint256 blacklistedAt;
        uint256 blacklistedBlock;
        uint256 claimId;            // Which claim triggered this
        string  reason;             // On-chain reason code
    }

    // ════════════════════════════════════════════════════════
    //  STATE
    // ════════════════════════════════════════════════════════

    // TAD registry — keyed by project contract address
    mapping(address => TADRecord) private _tads;
    address[] public registeredProjects;

    // Enforcement records — keyed by claim ID
    mapping(uint256 => EnforcementRecord) private _enforcementRecords;
    uint256[] public enforcementRecordIds;

    // Blacklist — keyed by wallet address
    mapping(address => BlacklistEntry) private _blacklist;
    address[] public blacklistedWallets;

    // Wallet → project mapping (for quick lookup)
    mapping(address => address) public walletToProject;

    // ════════════════════════════════════════════════════════
    //  EVENTS
    // ════════════════════════════════════════════════════════

    event TeamRegistered(
        address indexed projectContract,
        string  projectName,
        address indexed registeredBy,
        uint256 timestamp
    );
    event TADSigned(
        address indexed projectContract,
        address indexed signingWallet,
        bytes32 tadContentHash,
        uint256 blockNumber
    );
    event KYCVerified(
        address indexed projectContract,
        address indexed verifier,
        uint256 timestamp
    );
    event TeamStatusUpdated(
        address indexed projectContract,
        TeamStatus oldStatus,
        TeamStatus newStatus,
        string reason
    );
    event WalletBlacklisted(
        address indexed wallet,
        address indexed projectContract,
        uint256 claimId,
        string reason,
        uint256 blockNumber
    );
    event EnforcementRecordFiled(
        uint256 indexed claimId,
        address indexed projectContract,
        bytes32 evidenceHash,
        uint256 lossAmountUSD
    );
    event LawEnforcementReferralFiled(
        uint256 indexed claimId,
        bool fbi,
        bool interpol,
        uint256 timestamp
    );
    event FundsRecovered(
        uint256 indexed claimId,
        uint256 amountUSD,
        uint256 timestamp
    );
    event ClaimEngineSet(address indexed oldEngine, address indexed newEngine);
    event VerifierSet(address indexed verifier, bool active);

    // ════════════════════════════════════════════════════════
    //  MODIFIERS
    // ════════════════════════════════════════════════════════

    modifier onlyClaimEngine() {
        require(msg.sender == claimEngine, "TAD: caller is not ClaimEngine");
        _;
    }

    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner, "TAD: not a verifier");
        _;
    }

    modifier projectExists(address projectContract) {
        require(
            _tads[projectContract].status != TeamStatus.Unregistered,
            "TAD: project not registered"
        );
        _;
    }

    // ════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ════════════════════════════════════════════════════════

    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "TAD: zero owner");
    }

    // ════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════

    /**
     * @notice Set the ClaimEngine address
     * @dev    Only owner (SafeFi multisig) can do this
     */
    function setClaimEngine(address _claimEngine) external onlyOwner {
        require(_claimEngine != address(0), "TAD: zero address");
        emit ClaimEngineSet(claimEngine, _claimEngine);
        claimEngine = _claimEngine;
    }

    /**
     * @notice Add or remove a SafeFi KYC verifier
     * @dev    Verifiers are SafeFi staff who confirm off-chain KYC docs
     */
    function setVerifier(address verifier, bool active) external onlyOwner {
        require(verifier != address(0), "TAD: zero address");
        isVerifier[verifier] = active;
        emit VerifierSet(verifier, active);
    }

    // ════════════════════════════════════════════════════════
    //  TEAM REGISTRATION  (SafeFi admin → partner team)
    // ════════════════════════════════════════════════════════

    /**
     * @notice Register a new partner project team
     * @dev    Called by SafeFi admin after initial vetting.
     *         Team must then sign the TAD before adapter deployment.
     *
     * @param  projectContract  The partner token's contract address
     * @param  projectName      Human-readable name (for records)
     * @param  teamWallets      All team member wallets to bind under this TAD
     * @param  identityHash     Keccak256 hash of KYC documents (stored off-chain)
     * @param  tadContentHash   Keccak256 hash of the TAD text the team will sign
     */
    function registerTeam(
        address   projectContract,
        string    calldata projectName,
        address[] calldata teamWallets,
        bytes32   identityHash,
        bytes32   tadContentHash
    ) external onlyOwner {
        require(projectContract != address(0),   "TAD: zero project address");
        require(bytes(projectName).length > 0,   "TAD: empty project name");
        require(teamWallets.length > 0,          "TAD: no team wallets");
        require(teamWallets.length <= 20,        "TAD: too many wallets (max 20)");
        require(identityHash != bytes32(0),      "TAD: zero identity hash");
        require(tadContentHash != bytes32(0),    "TAD: zero TAD content hash");
        require(
            _tads[projectContract].status == TeamStatus.Unregistered,
            "TAD: project already registered"
        );

        // Register all team wallets → project mapping
        for (uint256 i = 0; i < teamWallets.length; i++) {
            require(teamWallets[i] != address(0), "TAD: zero team wallet");
            walletToProject[teamWallets[i]] = projectContract;
        }

        _tads[projectContract] = TADRecord({
            projectContract: projectContract,
            projectName:     projectName,
            teamWallets:     teamWallets,
            identityHash:    identityHash,
            tadContentHash:  tadContentHash,
            signedAt:        0,
            signedBlock:     0,
            signingWallet:   address(0),
            kycVerified:     false,
            status:          TeamStatus.Registered
        });

        registeredProjects.push(projectContract);

        emit TeamRegistered(projectContract, projectName, msg.sender, block.timestamp);
    }

    // ════════════════════════════════════════════════════════
    //  TAD SIGNING  (partner team → on-chain)
    // ════════════════════════════════════════════════════════

    /**
     * @notice Partner team signs the TAD on-chain
     * @dev    Must be called from a registered team wallet.
     *         The tadContentHash must match what SafeFi registered —
     *         team confirms they have read and agreed to the exact same document.
     *         This is the cryptographically binding moment.
     *
     * @param  projectContract  The team's project contract address
     * @param  tadContentHash   Must match the hash registered by SafeFi
     */
    function signTAD(
        address projectContract,
        bytes32 tadContentHash
    ) external nonReentrant projectExists(projectContract) {
        TADRecord storage tad = _tads[projectContract];

        require(
            tad.status == TeamStatus.Registered,
            "TAD: TAD already signed or project not in Registered status"
        );
        require(
            walletToProject[msg.sender] == projectContract,
            "TAD: caller is not a registered team wallet for this project"
        );
        require(
            tadContentHash == tad.tadContentHash,
            "TAD: content hash mismatch - you are not signing the correct TAD"
        );

        tad.signedAt      = block.timestamp;
        tad.signedBlock   = block.number;
        tad.signingWallet = msg.sender;
        // Status moves to Active only after KYC is also verified
        // (KYC verification can happen before or after signing)

        emit TADSigned(projectContract, msg.sender, tadContentHash, block.number);
    }

    /**
     * @notice SafeFi verifier confirms the team's off-chain KYC documents
     * @dev    Both TAD signing AND KYC verification required for Active status.
     *         Status flips to Active automatically when both are complete.
     */
    function verifyKYC(address projectContract)
        external
        onlyVerifier
        projectExists(projectContract)
    {
        TADRecord storage tad = _tads[projectContract];
        require(!tad.kycVerified, "TAD: KYC already verified");

        tad.kycVerified = true;

        // If TAD is already signed, promote to Active
        if (tad.signedAt > 0 && tad.status == TeamStatus.Registered) {
            tad.status = TeamStatus.Active;
            emit TeamStatusUpdated(projectContract, TeamStatus.Registered, TeamStatus.Active, "TAD signed and KYC verified");
        }

        emit KYCVerified(projectContract, msg.sender, block.timestamp);
    }

    /**
     * @notice Manually update team status (suspend, reinstate, etc.)
     * @dev    Owner only. Used for non-enforcement status changes.
     */
    function updateTeamStatus(
        address    projectContract,
        TeamStatus newStatus,
        string     calldata reason
    ) external onlyOwner projectExists(projectContract) {
        require(
            newStatus != TeamStatus.Blacklisted,
            "TAD: use blacklistWallet() for enforcement blacklisting"
        );
        TeamStatus old = _tads[projectContract].status;
        _tads[projectContract].status = newStatus;
        emit TeamStatusUpdated(projectContract, old, newStatus, reason);
    }

    // ════════════════════════════════════════════════════════
    //  ENFORCEMENT  (called by ClaimEngine after confirmed incident)
    // ════════════════════════════════════════════════════════

    /**
     * @notice Permanently blacklist a wallet after a confirmed covered event
     * @dev    Called by ClaimEngine only. Immutable once set.
     *         Original team wallets remain liable under TAD even if
     *         ownership was transferred (per Master Plan Section 21, Event 9).
     *
     * @param  wallet   The wallet address to blacklist
     * @param  claimId  The claim that triggered this enforcement action
     * @param  reason   On-chain reason code (e.g. "RUG_PULL_EVENT_1")
     */
    function blacklistWallet(
        address wallet,
        uint256 claimId,
        string  calldata reason
    ) external onlyClaimEngine {
        require(wallet != address(0), "TAD: zero wallet");
        require(!_isBlacklisted(wallet), "TAD: wallet already blacklisted");

        _blacklist[wallet] = BlacklistEntry({
            wallet:           wallet,
            blacklistedAt:    block.timestamp,
            blacklistedBlock: block.number,
            claimId:          claimId,
            reason:           reason
        });
        blacklistedWallets.push(wallet);

        // If wallet belongs to a registered project, blacklist the whole project
        address projectContract = walletToProject[wallet];
        if (projectContract != address(0)) {
            TADRecord storage tad = _tads[projectContract];
            if (tad.status != TeamStatus.Blacklisted) {
                TeamStatus old = tad.status;
                tad.status = TeamStatus.Blacklisted;
                emit TeamStatusUpdated(projectContract, old, TeamStatus.Blacklisted, reason);
            }
        }

        emit WalletBlacklisted(wallet, projectContract, claimId, reason, block.number);
    }

    /**
     * @notice File an immutable enforcement record after a confirmed incident
     * @dev    Called by ClaimEngine only. Stores evidence hash on-chain permanently.
     *         Off-chain forensics package is referenced by evidenceHash.
     *
     * @param  claimId          Unique claim ID from ClaimEngine
     * @param  projectContract  The affected partner token
     * @param  evidenceHash     Keccak256 hash of the full forensics evidence package
     * @param  culpritWallets   All wallets confirmed responsible for the incident
     * @param  lossAmountUSD    Total verified USD loss to holders
     */
    function fileEnforcementRecord(
        uint256   claimId,
        address   projectContract,
        bytes32   evidenceHash,
        address[] calldata culpritWallets,
        uint256   lossAmountUSD
    ) external onlyClaimEngine {
        require(
            _enforcementRecords[claimId].filedAt == 0,
            "TAD: enforcement record already filed for this claim"
        );
        require(evidenceHash != bytes32(0),   "TAD: zero evidence hash");
        require(culpritWallets.length > 0,    "TAD: no culprit wallets");
        require(lossAmountUSD > 0,            "TAD: zero loss amount");

        _enforcementRecords[claimId] = EnforcementRecord({
            claimId:               claimId,
            projectContract:       projectContract,
            evidenceHash:          evidenceHash,
            culpritWallets:        culpritWallets,
            lossAmountUSD:         lossAmountUSD,
            filedAt:               block.timestamp,
            filedBlock:            block.number,
            fbiReferralFiled:      false,
            interpolReferralFiled: false,
            fundsRecovered:        false,
            recoveredAmountUSD:    0,
            status:                "FILED"
        });
        enforcementRecordIds.push(claimId);

        emit EnforcementRecordFiled(claimId, projectContract, evidenceHash, lossAmountUSD);
    }

    /**
     * @notice Record that law enforcement referrals have been filed
     * @dev    Owner updates this after the off-chain referral is submitted.
     *         FBI Cyber Division + Interpol referrals per Master Plan Section 20.7.
     */
    function recordLawEnforcementReferral(
        uint256 claimId,
        bool    fbiReferral,
        bool    interpolReferral
    ) external onlyOwner {
        require(
            _enforcementRecords[claimId].filedAt > 0,
            "TAD: no enforcement record for this claim"
        );
        EnforcementRecord storage rec = _enforcementRecords[claimId];
        rec.fbiReferralFiled      = fbiReferral;
        rec.interpolReferralFiled = interpolReferral;
        rec.status = "REFERRED_TO_LAW_ENFORCEMENT";

        emit LawEnforcementReferralFiled(claimId, fbiReferral, interpolReferral, block.timestamp);
    }

    /**
     * @notice Record funds recovered through legal action
     * @dev    Per Master Plan: recovered funds flow back to Protection Reserve.
     *         This function records the amount. Actual fund transfer is handled
     *         separately by the PremiumPool contract.
     */
    function recordFundsRecovered(
        uint256 claimId,
        uint256 amountUSD
    ) external onlyOwner {
        require(
            _enforcementRecords[claimId].filedAt > 0,
            "TAD: no enforcement record for this claim"
        );
        EnforcementRecord storage rec = _enforcementRecords[claimId];
        rec.fundsRecovered      = true;
        rec.recoveredAmountUSD += amountUSD;
        rec.status = "PARTIALLY_RECOVERED";

        emit FundsRecovered(claimId, amountUSD, block.timestamp);
    }

    // ════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════

    /**
     * @notice Check if a project's TAD is fully signed and KYC verified
     * @dev    Called by Adapter constructors to gate deployment.
     *         Returns true only when status == Active.
     */
    function isTADSigned(address projectContract) external view returns (bool) {
        return _tads[projectContract].status == TeamStatus.Active;
    }

    /**
     * @notice Check if a wallet is blacklisted
     */
    function isBlacklisted(address wallet) external view returns (bool) {
        return _isBlacklisted(wallet);
    }

    /**
     * @notice Get full TAD record for a project
     */
    function getTAD(address projectContract)
        external
        view
        returns (TADRecord memory)
    {
        return _tads[projectContract];
    }

    /**
     * @notice Get the team status for a project
     */
    function getTeamStatus(address projectContract)
        external
        view
        returns (TeamStatus)
    {
        return _tads[projectContract].status;
    }

    /**
     * @notice Get full enforcement record for a claim
     */
    function getEnforcementRecord(uint256 claimId)
        external
        view
        returns (EnforcementRecord memory)
    {
        return _enforcementRecords[claimId];
    }

    /**
     * @notice Get blacklist entry for a wallet
     */
    function getBlacklistEntry(address wallet)
        external
        view
        returns (BlacklistEntry memory)
    {
        require(_isBlacklisted(wallet), "TAD: wallet not blacklisted");
        return _blacklist[wallet];
    }

    /**
     * @notice Get all registered project addresses
     */
    function getRegisteredProjects() external view returns (address[] memory) {
        return registeredProjects;
    }

    /**
     * @notice Get all blacklisted wallet addresses
     */
    function getBlacklistedWallets() external view returns (address[] memory) {
        return blacklistedWallets;
    }

    /**
     * @notice Get all enforcement record claim IDs
     */
    function getEnforcementRecordIds() external view returns (uint256[] memory) {
        return enforcementRecordIds;
    }

    /**
     * @notice Get all team wallets bound under a project's TAD
     */
    function getTeamWallets(address projectContract)
        external
        view
        returns (address[] memory)
    {
        return _tads[projectContract].teamWallets;
    }

    /**
     * @notice Total number of registered projects
     */
    function totalRegisteredProjects() external view returns (uint256) {
        return registeredProjects.length;
    }

    /**
     * @notice Total number of blacklisted wallets
     */
    function totalBlacklistedWallets() external view returns (uint256) {
        return blacklistedWallets.length;
    }

    /**
     * @notice Total number of enforcement records filed
     */
    function totalEnforcementRecords() external view returns (uint256) {
        return enforcementRecordIds.length;
    }

    // ════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ════════════════════════════════════════════════════════

    function _isBlacklisted(address wallet) internal view returns (bool) {
        return _blacklist[wallet].blacklistedAt > 0;
    }
}
