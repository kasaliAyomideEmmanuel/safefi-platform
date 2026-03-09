# SafeFi — Decentralized Automatic Protection Protocol

> **Protect every DeFi token holder automatically. No opt-in. No claims. No risk.**

[![Live Platform](https://img.shields.io/badge/Live%20Platform-safefi--platform.netlify.app-00d4ff?style=for-the-badge)](https://safefi-platform.netlify.app)
[![Network](https://img.shields.io/badge/Network-BNB%20Chain%20Testnet-f0b90b?style=for-the-badge)](https://testnet.bscscan.com)
[![License](https://img.shields.io/badge/License-MIT-00ff88?style=for-the-badge)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?style=for-the-badge)](https://soliditylang.org)

---

## 🌍 The Problem

Over **$12 billion** was lost to DeFi exploits in 2023–2024 alone — rug pulls, flash loan attacks, oracle manipulation, liquidity drains. When these events happen, victims receive nothing. No compensation. No recourse. No protection.

Existing insurance solutions like Nexus Mutual require users to manually purchase coverage before an exploit, understand complex risk parameters, and file claims afterward. The result: **less than 0.1% of DeFi users are protected.**

---

## 💡 The Solution

SafeFi embeds a tiny **0.1–0.2% micro-premium** directly into partner token smart contracts. Every token transfer automatically contributes to five isolated USDC reserve vaults. If an exploit is detected, SafeFi's oracle service:

1. **Detects** the attack in under 15 seconds (40+ event types covered)
2. **Calculates** every victim's pro-rata loss automatically
3. **Mints SFI tokens** (1 SFI = 1 USDC always) and sends them to every affected wallet
4. **Blacklists** the culprit wallet on-chain permanently

**Zero manual claims. Zero opt-in. Fully automatic and fully on-chain.**

---

## 🔴 Live Demo

**Platform:** https://safefi-platform.netlify.app

The full claim lifecycle has been tested and verified on BNB Chain Testnet:

| Event | Details |
|-------|---------|
| Transaction | `0x8a20cd5d34d6f372e46e89a865a1f820ee63dda5...` |
| Block | `94544014` |
| Result | Claim #4 approved — 10 on-chain events fired |
| SFI minted | 1,000,000 SFI sent to victim wallet |
| Culprit | Blacklisted in SafeFiTeamAccountability contract |

---

## 🏗️ Architecture

```
Partner Token Contract
        │
        │ 0.1–0.2% micro-premium on every transfer
        ▼
SafeFiBEP20Adapter ──────────────────────────────────────────┐
        │                                                      │
        ▼                                                      │
SafeFiPremiumPool                                    SafeFiStakerRegistry
  ├── Protection Reserve (60%)                    (tracks all holders,
  ├── Operational Pool   (15%)                     stakers, LP providers)
  ├── Yield Vault        (10%) ──► Aave V3 / Compound V3
  ├── Ecosystem Pool     (10%)
  └── Recovery Fund       (5%)
        │
        │ Exploit detected by Oracle Monitor (<15 seconds)
        ▼
SafeFiClaimEngine
  ├── SafeFiClaimStore    (claim registry)
  ├── SafeFiEligibility   (victim validation)
  └── SafeFiClaimEngine   (payout execution)
        │
        ▼
SafeFiSFI Token ──► Victim Wallets (1 SFI = 1 USDC)
        │
SafeFiTeamAccountability ──► Culprit Blacklisted On-Chain
```

---

## 📜 Smart Contracts (BNB Chain Testnet — Chain ID: 97)

| Contract | Address | Purpose |
|----------|---------|---------|
| SafeFiSFI | `0xE75b54E53109D76896fbb0142F3e0ECd29347953` | SFI stablecoin — 1:1 USDC backed |
| SafeFiPremiumPool | `0x17cAB26591a68E9af52B23BE0533839Eb209C422` | 5-vault premium distribution |
| SafeFiClaimEngine | `0x2Be43Bd667401cbD31Cd154340DbE5F9285000Cd` | Automated claim processing |
| SafeFiClaimStore | `0x832bfa5c582604c2ab53649986dc3f1066ccd4ee` | On-chain claim registry |
| SafeFiTeamAccountability | `0x832bfa5c582604c2ab53649986dc3f1066ccd4ee` | Culprit blacklist enforcement |
| TestUSDC | `0x64544969ed7EBf5f083679233325356EbE738930` | Test USDC for reserve backing |

> All contracts are verified on [BscScan Testnet](https://testnet.bscscan.com)

---

## ⚙️ How Integration Works

Token projects integrate SafeFi in 5 steps — **no changes to their existing contract required:**

1. **Contact SafeFi** via the Partner Onboarding tab on the platform
2. **SafeFi deploys** a BEP20/ERC20 Adapter contract linked to their token
3. **StakerRegistry** begins tracking all holders, stakers, and LP providers
4. **Oracle Monitor** activates — 24/7 coverage across 40+ attack event types
5. **Dashboard listing** — token appears on SafeFi platform as a Protected Partner

---

## 🛡️ Coverage — 40+ Attack Event Types

SafeFi monitors for and responds to:

- Rug pulls and liquidity removal attacks
- Flash loan price manipulation
- Oracle manipulation and price feed attacks
- Unauthorized minting / supply inflation
- Governance takeover attacks
- Sandwich attacks and MEV exploitation
- Honeypot contract detection
- Smart contract vulnerability exploits
- And 32+ more attack patterns

---

## 💰 Token Economics

**SFI Token**
- 1 SFI = 1 USDC — always, guaranteed by smart contract
- Minted only when a claim is approved
- Redeemable for USDC at any time
- 100% USDC-backed reserve — no algorithmic risk

**Premium Pool Split (per transfer)**
| Pool | Share | Purpose |
|------|-------|---------|
| Protection Reserve | 60% | Primary victim compensation fund |
| Operational Pool | 15% | Protocol operations |
| Yield Vault | 10% | Aave V3 + Compound V3 yield |
| Ecosystem Pool | 10% | Grants, partnerships, growth |
| Recovery Fund | 5% | Catastrophic event backstop |

---

## 🚀 Tech Stack

| Layer | Technology |
|-------|-----------|
| Smart Contracts | Solidity 0.8.20, OpenZeppelin |
| Blockchain | BNB Chain (BEP20) + Ethereum (ERC20) |
| Frontend | React 18, Vite, CSS-in-JS |
| Deployment | Netlify (CI/CD from GitHub) |
| Wallet | MetaMask, ethers.js |
| Oracle/Monitor | Node.js, ethers v6, Winston |
| Yield | Aave V3, Compound V3 |
| Dev Tools | Remix IDE, Hardhat-compatible |

---

## 📁 Repository Structure

```
safefi-platform/
├── src/
│   ├── App.jsx          # Full platform UI — 6 tabs, wallet connect, live data
│   └── main.jsx         # React entry point
├── public/
│   └── favicon.svg      # SafeFi shield favicon
├── index.html           # SPA entry + Netlify Forms detection
├── package.json
├── vite.config.js
└── netlify.toml         # Build config + SPA routing
```

**Smart contract source files** are available on request and will be submitted for audit prior to mainnet deployment.

---

## 🗺️ Roadmap

| Phase | Timeline | Milestone |
|-------|----------|-----------|
| ✅ Phase 1 | Q1 2026 | Testnet deployment, full claim lifecycle tested, platform live |
| 🔄 Phase 2 | Q2 2026 | Smart contract audit (Certik/Hacken), testnet partners onboarded |
| 📋 Phase 3 | Q3 2026 | Mainnet launch, 10+ partner tokens, reserve capitalized to $3M+ |
| 📋 Phase 4 | Q4 2026 | Multi-chain expansion (Ethereum, Polygon), 50+ partners, DAO governance |

---

## 💵 Funding

SafeFi is raising a **$500K Seed Round** to fund:
- Smart contract audit — $150K
- Engineering & development — $125K
- Business development — $100K
- Operations & legal — $75K
- Initial protocol reserve seed — $50K

A subsequent **$3M–$5M Strategic Round** will capitalize the Protection Reserve pools before mainnet launch, ensuring every victim can be paid from day one.

---

## 👨‍💻 Founder

**Kasali Ayomide Emmanuel**
SafeFi Tech Solutions Ltd — Nigeria

- Platform: https://safefi-platform.netlify.app
- Partner Onboarding: https://safefi-platform.netlify.app (Partner Onboarding tab)
- Email: kasaliayomidee@gmail.com

---

## 🔒 Security & Audit Status

| Item | Status |
|------|--------|
| Testnet deployment | ✅ Complete |
| End-to-end claim test | ✅ Verified on-chain |
| Open source contracts | ✅ Readable on BscScan |
| Smart contract audit | 🔄 Planned — Certik/Hacken pre-mainnet |
| Multisig treasury | 🔄 Planned — Gnosis Safe pre-mainnet |
| Mainnet deployment | 🔄 Post-audit only |

> **SafeFi will never deploy to mainnet without a clean audit report.**

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

*SafeFi — Making DeFi safe for everyone, automatically.*
