// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * SafeFiEligibility.sol - 40 Event Rule Engine
 * SafeFi Tech Solutions Ltd | Kasali Ayomide Emmanuel
 * Metrics array: [lpPct, pricePct, supplyPct, tvlPct, transferUSD, ownerBlocks, wallets]
 * Flags array:   [disputed, govVote, bridge, ackError]
 */
contract SafeFiEligibility {

    function check(
        uint8          et,
        uint256[7] calldata m,
        bool[4]    calldata f,
        uint256        culprits
    ) external pure returns (bool ok, string memory reason) {
        if (et <= 7)  return _g1(et, m, f, culprits);
        if (et <= 15) return _g2(et, m, f, culprits);
                      return _g3(et, m, f, culprits);
    }

    // m[0]=lpPct m[1]=pricePct m[2]=supplyPct m[3]=tvlPct
    // m[4]=transferUSD m[5]=ownerBlocks m[6]=wallets
    // f[0]=disputed f[1]=govVote f[2]=bridge f[3]=ackError

    function _g1(uint8 et, uint256[7] calldata m, bool[4] calldata f, uint256 c)
        internal pure returns (bool, string memory)
    {
        if (et == 0) {
            if (m[0] < 4000) return (false, "E1: LP <40%");
            if (m[1] < 5000) return (false, "E1: price drop <50%");
            return (true, "");
        }
        if (et == 1) {
            if (m[3] < 4000) return (false, "E2: TVL <40%");
            if (c == 0)      return (false, "E2: no culprits");
            return (true, "");
        }
        if (et == 2) {
            if (m[2] < 3000) return (false, "E3: supply <30%");
            if (m[1] < 3000) return (false, "E3: price <30%");
            if (f[1])        return (false, "E3: gov vote existed");
            return (true, "");
        }
        if (et == 3) {
            if (m[4] < 50000*1e6) return (false, "E4: transfer <$50K");
            if (f[1])             return (false, "E4: gov approved");
            if (m[1] < 3000)      return (false, "E4: price <30%");
            return (true, "");
        }
        if (et == 4) {
            if (!f[2]) return (false, "E5: bridge not listed");
            return (true, "");
        }
        if (et == 5) {
            if (f[1])        return (false, "E6: gov vote preceded");
            if (m[1] < 6000) return (false, "E6: price <60%");
            return (true, "");
        }
        if (et == 6) {
            if (m[2] < 2000) return (false, "E7: supply <20%");
            if (f[1])        return (false, "E7: gov approved mint");
            if (m[1] < 4000) return (false, "E7: price <40%");
            return (true, "");
        }
        // et==7 FlashLoan
        if (m[3] < 3000) return (false, "E8: TVL <30%");
        if (c == 0)      return (false, "E8: no culprits");
        return (true, "");
    }

    function _g2(uint8 et, uint256[7] calldata m, bool[4] calldata f, uint256 c)
        internal pure returns (bool, string memory)
    {
        if (et == 8) {
            if (m[5] > 10)   return (false, "E9: action >10 blocks");
            if (m[1] < 4000) return (false, "E9: price <40%");
            return (true, "");
        }
        if (et == 9) {
            if (m[3] < 2500) return (false, "E10: TVL <25%");
            if (c == 0)      return (false, "E10: no culprits");
            return (true, "");
        }
        if (et == 10) {
            if (m[0] < 4000) return (false, "E11: LP not removed");
            return (true, "");
        }
        if (et == 11) {
            if (!f[3]) return (false, "E12: error not acknowledged");
            return (true, "");
        }
        if (et == 12) {
            if (!f[0])       return (false, "E13: not disputed");
            if (m[1] < 3000) return (false, "E13: price <30%");
            return (true, "");
        }
        if (et == 13) {
            if (m[1] < 9000) return (false, "E14: sell fail <90%");
            if (m[0] < 4000) return (false, "E14: LP not removed");
            return (true, "");
        }
        if (et == 14) {
            if (m[1] < 5000) return (false, "E15: deviation <50%");
            if (c == 0)      return (false, "E15: no culprits");
            return (true, "");
        }
        // et==15 GovernanceAttack
        if (c == 0) return (false, "E16: no culprits");
        return (true, "");
    }

    function _g3(uint8 et, uint256[7] calldata m, bool[4] calldata f, uint256 c)
        internal pure returns (bool, string memory)
    {
        if (et == 16) { if (m[3] < 3000) return (false, "E17: TVL <30%"); return (true, ""); }
        if (et == 17) { if (!f[2]) return (false, "E18: bridge not listed"); return (true, ""); }
        if (et == 18 || et == 19) { if (c == 0) return (false, "E19-20: no culprits"); return (true, ""); }
        if (et == 20) { return (true, ""); }
        if (et == 21) { if (m[0] < 4000) return (false, "E22: LP <40%"); return (true, ""); }
        if (et == 22) { return (true, ""); }
        if (et == 23) { if (c == 0) return (false, "E24: no culprits"); return (true, ""); }
        if (et == 24) { if (m[6] < 20) return (false, "E25: <20 wallets"); if (c == 0) return (false, "E25: no culprits"); return (true, ""); }
        if (et == 25) { if (!f[3]) return (false, "E26: not confirmed"); return (true, ""); }
        if (et == 26) { if (c == 0) return (false, "E27: no culprits"); return (true, ""); }
        if (et == 27) { if (!f[2]) return (false, "E28: bridge not listed"); return (true, ""); }
        if (et == 28) { if (m[3] < 2000) return (false, "E29: loss <20%"); if (!f[2]) return (false, "E29: not listed"); return (true, ""); }
        if (et == 29) { if (!f[0]) return (false, "E30: not reported"); return (true, ""); }
        if (et == 30) { if (m[1] < 3500) return (false, "E31: price <35%"); if (c == 0) return (false, "E31: no culprits"); return (true, ""); }
        if (et == 31) { return (true, ""); }
        if (et == 32) { if (c == 0) return (false, "E33: no culprits"); return (true, ""); }
        if (et == 33) { if (c == 0) return (false, "E34: no culprits"); return (true, ""); }
        if (et == 34) { if (c == 0) return (false, "E35: no culprits"); return (true, ""); }
        if (et == 35) { if (m[3] < 4000) return (false, "E36: TVL <40%"); if (c == 0) return (false, "E36: no culprits"); return (true, ""); }
        if (et == 36 || et == 37 || et == 38) { if (c == 0) return (false, "E37-39: no culprits"); return (true, ""); }
        if (et == 39) { if (c == 0) return (false, "E40: no culprits"); return (true, ""); }
        return (false, "unknown event");
    }
}
