# SafeFi Testnet Platform

SafeFi is a protection protocol demonstration for partner tokens. This repository contains the React and Vite website used to explain the current BSC Testnet deployment, show validation evidence, and guide partner onboarding.

[![Live Platform](https://img.shields.io/badge/Live%20Platform-safefi--platform.netlify.app-08C7D9?style=for-the-badge)](https://safefi-platform.netlify.app/)
[![Network](https://img.shields.io/badge/Network-BNB%20Chain%20Testnet-F0B90B?style=for-the-badge)](https://testnet.bscscan.com/)
[![Contracts](https://img.shields.io/badge/Contracts-17%20deployed-00A86B?style=for-the-badge)](https://safefi-platform.netlify.app/)
[![License](https://img.shields.io/badge/License-MIT-334155?style=for-the-badge)](LICENSE)

Live website: [safefi-platform.netlify.app](https://safefi-platform.netlify.app/)

The current release is a BSC Testnet demonstration on chain ID 97. It is not a mainnet deployment, insurance product, audit certificate, or guarantee of payouts with real funds.

## Product boundary

SafeFi uses an explicit protected-transfer route. A partner token is protected when the partner and user use the configured SafeFi route, which charges an explicit premium and records coverage evidence. Ordinary token transfers remain ordinary and are not automatically treated as covered.

The website is an inspection and communication layer. Deployed contracts and BscScan transactions remain the authoritative source for chain facts.

## Website areas

- **Overview** - current testnet deployment count, source-verification count, pool accounting model, and validation results.
- **Pools** - the five-ledger premium allocation: Protection Reserve 60%, Operational Pool 15%, Yield Vault 10%, Ecosystem Pool 10%, and Recovery Fund 5%.
- **Testnet Evidence** - protected-transfer, two-monitor claim, and local security-test evidence.
- **My Protection** - wallet-connected SFI balance inspection. Claim history is not fabricated; a live indexed claims feed is a separate future feature.
- **Partner Onboarding** - the information a token team needs to request integration and test the protected route.
- **Contracts** - the complete deployed manifest with direct BscScan links.

## Testnet evidence

| Test | Result |
| --- | --- |
| Protected transfer | Recipient received 999,000 units; PremiumCollector accrued 1,000 units; coverage count increased by one. |
| Two-monitor claim | Claim 2 completed with the configured two-monitor quorum; recipient received 999,000 SFI; coverage receipt was consumed. |
| Eligibility boundaries | All 40 qualifying event vectors passed at their exact boundary and failing one-step boundaries were rejected. |
| Security and invariants | Randomized cashflows, proportional distribution, rounding dust, withdrawal limits, and malicious-token re-entry tests passed locally. |
| Source verification | Deployed contracts and test-only support contracts were published with matching bytecode and ABI on BscScan. |

Protected-transfer transaction: [view on BscScan](https://testnet.bscscan.com/tx/0xec1f46d38f7dcec9a914856b5399f5913611c53a629009e00d7a78c103b2115d).

## Deployed contract manifest

All addresses below are BSC Testnet addresses. Mock assets and mock feeds are test-only and have no monetary value.

| Contract | Role | Address |
| --- | --- | --- |
| SafeFiSFI | SFI accounting and redemption token | `0xB4c8970A91aF6a8261D27B5f41D71bf67189AfCa` |
| SafeFiTeamAccountability | Project and culprit accountability | `0xE5837834c919507FA551A23Cde590eD6A3738C4A` |
| SafeFiPremiumPool | Five premium accounting ledgers | `0x31E78650D330A51f4979a22b6d11d696EAD65A65` |
| SafeFiProtectedTransferRouter | Explicit protected-transfer route | `0x5e68c37FE0aa147BB4eA88d0f4A676B02cd39131` |
| SafeFiPremiumCollector | Partner-token premium intake | `0x5Cb49755B829e162ADa46f9B90aeDAA66FFa0e91` |
| SafeFiClaimStore | Claim data storage | `0x69eb8A33D297765075eeD2E5D6De0960f98004f8` |
| SafeFiEligibility | Forty-rule eligibility engine | `0x15E7ab3a61DDBce1143d53DB307eDa003f31b69D` |
| SafeFiClaimEngine | Claim orchestration and payout flow | `0x38d9d2731B3D7856482d79D1095483698974d804` |
| SafeFiOracleAggregator | Freshness and disagreement safeguards | `0xfb03551Cd05f1e1774B08a4386cC7A5670Ae970B` |
| SafeFiBEP20Adapter | Partner token integration adapter | `0x26663c40A559F8b0E7c2D4e39d87AaF90a0c13eb` |
| SafeFiCoverageRegistry | Coverage receipt records | `0xbB98552728ab48BdD77F1D4EcDD4f518c82c008f` |
| SafeFiCoverageGate | Receipt validation and consumption | `0x399bF2B103D36222306b662036b2D59a9b44b8a9` |
| TestUSDC reserve | Test-only reserve asset | `0xA6DD768593300d443cEd0f2d57dc534adFCE5EcE` |
| TestUSDC partner | Test-only partner token | `0x741C99E54FADc1A141E8cAa74c9c00Ecd37340dc` |
| MockPriceFeed A | Test-only oracle feed | `0x78579f84dE1889428C70F36f37d7A9A73A08dD4A` |
| MockPriceFeed B | Test-only oracle feed | `0x9F7b3De4917a4AE123a5a192de12eE80aEe80827` |
| MockDEXRouter | Test-only conversion route | `0xe81cfF4480b0Fc836962979fbb03B4e7e3529d3F` |

The active ClaimEngine is the deployed `SafeFiClaimEngine_8.sol`. Archived duplicate engines are retained as reference and are not part of the active deployment.

## How the system works

1. A partner token uses the SafeFi protected route for a transfer.
2. The route charges the configured premium and sends the net token amount to the recipient.
3. PremiumCollector and PremiumPool account for the five destination ledgers.
4. CoverageRegistry records the protected-transfer receipt.
5. A monitored incident can be submitted to ClaimEngine.
6. ClaimEngine checks monitor approval, oracle freshness, oracle disagreement, eligibility, and coverage evidence.
7. Approved claims mint SFI against reserve accounting, subject to configured limits and timelocks.
8. A receipt is consumed when it supports a payout, preventing reuse.
9. Accountability and enforcement actions can be recorded for confirmed projects or culprits.

## Partner integration model

Partners should use the Partner Onboarding tab and the detailed integration guide in the SafeFi local project:

1. Confirm token compatibility and testnet addresses.
2. Agree the premium rate and protected-transfer user experience.
3. Configure the adapter, router, collector, and coverage relationships.
4. Test allowance, transfer, premium, coverage, and redemption behavior on BSC Testnet.
5. Run a monitored claim test with the configured monitor quorum.
6. Review BscScan source and transaction evidence before any production decision.

## Public project links

- [Live SafeFi platform](https://safefi-platform.netlify.app/)
- [GitHub source repository](https://github.com/kasaliAyomideEmmanuel/safefi-platform)
- [BSC Testnet explorer](https://testnet.bscscan.com/)
- [Protected-transfer test transaction](https://testnet.bscscan.com/tx/0xec1f46d38f7dcec9a914856b5399f5913611c53a629009e00d7a78c103b2115d)

The connected Netlify project builds the `main` branch and publishes the generated static site. Private keys, seed phrases, RPC secrets, monitor keys, `.env` files, and deployment credentials must never be committed.

## Repository structure

```text
safefi-platform/
├── src/
│   ├── App.jsx          # Website interface and testnet manifest
│   └── main.jsx         # React entry point
├── index.html
├── package.json
├── package-lock.json
├── vite.config.js
├── netlify.toml
└── README.md
```

Smart-contract source files, deployment scripts, manifests, verification input, detailed test reports, and partner integration documentation are maintained in the separate `outputs/safefi-local` project.

## Security and production boundary

The current system is suitable for testnet demonstration and partner conversations. Before real funds or mainnet deployment, the project still needs:

- independent smart-contract audit and remediation;
- production oracle providers and monitoring;
- multisig governance and operational key management;
- economic, reserve, and stress-model review;
- legal and regulatory review;
- production incident response, alerting, and recovery drills;
- a live indexed claims interface linked to on-chain events.

Passing the test suite, deploying to testnet, and publishing source code do not by themselves establish production readiness, insurance status, regulatory approval, or guaranteed compensation.

## License

MIT License. See [LICENSE](LICENSE) for details.
