# SafeFi Smart Contracts

> ⚠️ **TESTNET ONLY** — All contracts below are deployed exclusively on BNB Chain Testnet (Chain ID: 97). No mainnet deployment exists. Mainnet launch will occur after a full smart contract audit by Certik or Hacken.

---

## Deployed Addresses (BNB Chain Testnet — Chain ID: 97)

| Contract | Address | Purpose |
|----------|---------|---------|
| SafeFiSFI | `0xE75b54E53109D76896fbb0142F3e0ECd29347953` | SFI stablecoin — 1 SFI = 1 USDC always |
| SafeFiPremiumPool | `0x17cAB26591a68E9af52B23BE0533839Eb209C422` | 5-vault premium distribution |
| SafeFiClaimEngine | `0x2Be43Bd667401cbD31Cd154340DbE5F9285000Cd` | Automated claim processing |
| SafeFiClaimStore | `0x832bfa5c582604c2ab53649986dc3f1066ccd4ee` | On-chain claim registry |
| SafeFiTeamAccountability | `0x832bfa5c582604c2ab53649986dc3f1066ccd4ee` | Culprit blacklist enforcement |
| TestUSDC | `0x64544969ed7EBf5f083679233325356EbE738930` | Test USDC for reserve backing |

> Verify all contracts on [BscScan Testnet](https://testnet.bscscan.com)

---

## Contract Descriptions

### SafeFiSFI.sol
The SFI token contract. SFI is a 100% USDC-backed stablecoin minted only when a claim is approved. Victims receive SFI automatically and can redeem 1:1 for USDC at any time. No algorithmic mechanism — pure USDC backing.

### SafeFiPremiumPool.sol
Receives micro-premiums (0.1–0.2%) from partner token transfers and automatically distributes them across 5 isolated vaults:
- Protection Reserve — 60%
- Operational Pool — 15%
- Yield Vault — 10% (deployed to Aave V3 / Compound V3)
- Ecosystem Pool — 10%
- Recovery Fund — 5%

### SafeFiClaimEngine.sol
The core claim processing contract. Executes a 3-step on-chain process:
1. `submitIncident()` — registers exploit event with type and loss amount
2. `submitData()` — provides oracle metrics and proof data
3. `submitParties()` — registers victim list with pro-rata balances, triggers payout

### SafeFiClaimStore.sol
Permanent on-chain registry of all claims. Stores claim status, victim data, payout amounts, and exploit details. Fully auditable and immutable.

### SafeFiEligibility.sol
Validates victim eligibility before payout. Checks holder status, balance at time of exploit, and position type (holder / staker / LP provider).

### SafeFiBEP20Adapter.sol
Adapter contract for BEP20 (BNB Chain) partner tokens. Wraps the standard transfer() function to deduct the micro-premium and route it to SafeFiPremiumPool. No changes required to existing token contracts.

### SafeFiERC20Adapter.sol
Adapter contract for ERC20 (Ethereum) partner tokens. Same functionality as BEP20Adapter for Ethereum-based tokens.

### SafeFiTeamAccountability.sol
Permanent blacklist contract. Culprit wallets identified in approved claims are blacklisted on-chain, preventing future participation across all SafeFi partner tokens.

### TestUSDC.sol
Test USDC token for testnet use only. Allows minting for development and testing purposes. Will be replaced by real USDC on mainnet.

---

## Architecture

```
Partner Token Transfer
        │
        │ 0.1–0.2% micro-premium
        ▼
SafeFiBEP20Adapter / SafeFiERC20Adapter
        │
        ▼
SafeFiPremiumPool ──► 5 isolated USDC vaults
        │
        │ Exploit detected by Oracle Monitor
        ▼
SafeFiClaimEngine
  ├── SafeFiClaimStore    (registry)
  ├── SafeFiEligibility   (victim validation)
  └── Payout execution
        │
        ▼
SafeFiSFI ──► Victim wallets (1 SFI = 1 USDC)
        │
SafeFiTeamAccountability ──► Culprit blacklisted
```

---

## Audit Status

| Item | Status |
|------|--------|
| Testnet deployment | ✅ Complete |
| End-to-end claim test | ✅ Verified on-chain |
| Smart contract audit | 🔄 Planned — Certik/Hacken pre-mainnet |
| Mainnet deployment | 🔄 Post-audit only |

---

## Verified On-Chain Claim Test

A full end-to-end claim lifecycle has been tested and verified:

- **Transaction:** `0x8a20cd5d34d6f372e46e89a865a1f820ee63dda5ad61ec56afd9b633c7e77b8d`
- **Block:** `94544014` on BNB Chain Testnet
- **Result:** Claim #4 approved — 10 on-chain events fired
- **SFI minted:** 1,000,000 SFI sent to victim wallet
- **Culprit:** Blacklisted in SafeFiTeamAccountability

---

*SafeFi Tech Solutions Ltd — Nigeria*
*Platform: https://safefi-platform.netlify.app*
