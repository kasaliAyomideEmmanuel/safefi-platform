// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ============================================================
 * SafeFiPremiumPool.sol — 5-Pool Premium Vault (Mainnet)
 * SafeFi Tech Solutions Ltd | Kasali Ayomide Emmanuel
 * Version: 1.0.0 | March 2026
 * ============================================================
 *
 * WHAT THIS CONTRACT DOES:
 * 1. Receives micro-premiums (0.1-0.2%) from partner token adapters
 * 2. Splits every premium into 5 isolated pools:
 *    - 60% Protection Reserve  (funds approved claims)
 *    - 15% Operational Pool    (team, infrastructure, legal)
 *    - 10% Yield Vault         (deployed to Aave V3 / Compound V3)
 *    - 10% Ecosystem Pool      (grants, partnerships, growth)
 *    -  5% Recovery Fund       (project-specific recovery)
 * 3. Funds approved claims via ClaimEngine instruction
 * 4. Deploys idle yield capital to Aave V3 and Compound V3
 *
 * DEPLOY ORDER: SafeFiPoolStorage (base) is inherited — deploy
 * only this contract. SafeFiPoolStorage does not need separate
 * deployment as it is abstract.
 *
 * MAINNET CONSTRUCTOR ARGS (BNB Chain - Chain ID 56):
 * _usdc:        0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d
 * _owner:       your multisig wallet address
 * _sfiContract: deployed SafeFiSFI address
 *
 * POST-DEPLOY CALLS:
 * setAavePool(0x6807dc923806fE8Fd134338EABCA509979a7e0cB, true)
 * setCompoundComet(0xEFAACF73CE2D38ED40991f29E72B12C74bd4cf23, true)
 * setClaimEngine(SafeFiClaimEngine address)
 * setAdapterApproval(each adapter address, true)
 */

import "./SafeFiPoolStorage.sol";

contract SafeFiPremiumPool is SafeFiPoolStorage {

    constructor(address _usdc, address _owner, address _sfiContract)
        SafeFiPoolStorage(_usdc, _owner, _sfiContract) {}

    // ── Founding Reserve ──────────────────────────────────
    function depositFoundingReserve(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Pool: zero amount");
        bool ok = USDC.transferFrom(msg.sender, address(this), amount);
        require(ok, "Pool: transfer failed");
        protectionReserve += amount;
        emit FoundingReserveDeposited(amount);
    }

    // ── Receive Premium from Adapters ─────────────────────
    function receivePremium(address projectContract, uint256 amount) external nonReentrant {
        require(amount > 0, "Pool: zero amount");
        bool ok = USDC.transferFrom(msg.sender, address(this), amount);
        require(ok, "Pool: transfer failed");

        uint256 forProtection  = amount * PROTECTION_BPS  / 10000;
        uint256 forOperational = amount * OPERATIONAL_BPS / 10000;
        uint256 forYield       = amount * YIELD_BPS       / 10000;
        uint256 forEcosystem   = amount * ECOSYSTEM_BPS   / 10000;
        uint256 forRecovery    = amount - forProtection - forOperational - forYield - forEcosystem;

        protectionReserve += forProtection;
        operationalPool   += forOperational;
        yieldVaultBalance += forYield;
        ecosystemPool     += forEcosystem;
        recoveryFund      += forRecovery;

        emit PremiumReceived(projectContract, amount);
    }

    // ── Fund Claims (called by ClaimEngine only) ──────────
    function fundClaim(uint256 claimId, uint256 amountUSD) external onlyClaimEngine nonReentrant {
        require(!catastrophicMode, "Pool: catastrophic - use proRataFundClaim");
        require(amountUSD > 0, "Pool: zero amount");
        require(protectionReserve >= amountUSD, "Pool: insufficient reserve");
        protectionReserve -= amountUSD;
        bool ok = USDC.transfer(sfiContract, amountUSD);
        require(ok, "Pool: transfer failed");
        _updateAvgMonthlyClaims(amountUSD);
        emit ClaimFunded(claimId, sfiContract, amountUSD);
    }

    function proRataFundClaim(uint256 claimId, uint256 fullAmountUSD) external onlyClaimEngine nonReentrant {
        require(fullAmountUSD > 0, "Pool: zero amount");
        uint256 actual = protectionReserve < fullAmountUSD ? protectionReserve : fullAmountUSD;
        if (actual == 0) { emit ProRataFunded(claimId, fullAmountUSD, 0); return; }
        protectionReserve -= actual;
        bool ok = USDC.transfer(sfiContract, actual);
        require(ok, "Pool: transfer failed");
        emit ProRataFunded(claimId, fullAmountUSD, actual);
    }

    function withdrawRecoveryFund(address projectContract, uint256 claimId, uint256 amount)
        external onlyClaimEngine nonReentrant
    {
        require(amount <= recoveryFund, "Pool: insufficient recovery");
        recoveryFund -= amount;
        bool ok = USDC.transfer(sfiContract, amount);
        require(ok, "Pool: transfer failed");
        projectRecoveryUsed[projectContract] += amount;
        emit ClaimFunded(claimId, sfiContract, amount);
    }

    // ── Yield Deployment to Aave V3 ───────────────────────
    function deployToAave(uint256 amount) external onlyOwner nonReentrant {
        require(aaveEnabled, "Pool: Aave disabled");
        require(amount <= yieldVaultBalance, "Pool: insufficient yield vault");
        yieldVaultBalance -= amount;
        aaveDeployed      += amount;
        USDC.approve(address(aavePool), amount);
        aavePool.supply(address(USDC), amount, address(this), 0);
        emit YieldDeployed("Aave", amount);
    }

    function withdrawFromAave(uint256 amount) external onlyOwner nonReentrant {
        require(aaveEnabled, "Pool: Aave disabled");
        require(amount <= aaveDeployed, "Pool: exceeds deployed");
        aaveDeployed      -= amount;
        yieldVaultBalance += amount;
        aavePool.withdraw(address(USDC), amount, address(this));
        emit YieldWithdrawn("Aave", amount);
    }

    // ── Yield Deployment to Compound V3 ───────────────────
    function deployToCompound(uint256 amount) external onlyOwner nonReentrant {
        require(compoundEnabled, "Pool: Compound disabled");
        require(amount <= yieldVaultBalance, "Pool: insufficient yield vault");
        yieldVaultBalance -= amount;
        compoundDeployed  += amount;
        USDC.approve(address(compoundComet), amount);
        compoundComet.supply(address(USDC), amount);
        emit YieldDeployed("Compound", amount);
    }

    function withdrawFromCompound(uint256 amount) external onlyOwner nonReentrant {
        require(compoundEnabled, "Pool: Compound disabled");
        require(amount <= compoundDeployed, "Pool: exceeds deployed");
        compoundDeployed  -= amount;
        yieldVaultBalance += amount;
        compoundComet.withdraw(address(USDC), amount);
        emit YieldWithdrawn("Compound", amount);
    }

    // ── Owner Withdrawals ─────────────────────────────────
    function withdrawOperational(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= operationalPool, "Pool: insufficient");
        operationalPool -= amount;
        USDC.transfer(to, amount);
    }

    function withdrawEcosystem(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= ecosystemPool, "Pool: insufficient");
        ecosystemPool -= amount;
        USDC.transfer(to, amount);
    }

    // ── Reserve Adequacy Check ────────────────────────────
    function checkReserveAdequacy() external view returns (
        bool adequate, uint256 ratio, uint256 required
    ) {
        if (integratedTVL == 0) return (true, 10000, 0);
        required = integratedTVL * 500 / 10000;
        uint256 total = protectionReserve + aaveDeployed + compoundDeployed;
        ratio    = total * 10000 / integratedTVL;
        adequate = total >= required;
    }

    // ── Views ─────────────────────────────────────────────
    function getPoolBalances() external view returns (
        uint256 protection, uint256 operational,
        uint256 yield, uint256 ecosystem, uint256 recovery
    ) {
        return (protectionReserve, operationalPool, yieldVaultBalance, ecosystemPool, recoveryFund);
    }

    function totalUSDCUnderManagement() external view returns (uint256) {
        return protectionReserve + operationalPool + yieldVaultBalance +
               ecosystemPool + recoveryFund + aaveDeployed + compoundDeployed;
    }

    function totalYieldDeployed() external view returns (uint256) {
        return aaveDeployed + compoundDeployed;
    }

    function totalUSDC() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
}
