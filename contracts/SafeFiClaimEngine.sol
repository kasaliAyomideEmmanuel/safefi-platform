// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * SafeFiClaimEngine.sol
 * SafeFi Tech Solutions Ltd | Kasali Ayomide Emmanuel
 * Deploy order: ClaimStore -> Eligibility -> ClaimEngine
 */

interface IStore {
    enum Status { Submitted, Checking, Approved, Paid, Denied, Escalated, Paused, ProRata }
    function claimCount() external view returns (uint256);
    function claimStatus(uint256 id) external view returns (IStore.Status);
    function claimProject(uint256 id) external view returns (address);
    function claimHash(uint256 id) external view returns (bytes32);
    function claimLoss(uint256 id) external view returns (uint256);
    function claimEventType(uint256 id) external view returns (uint8);
    function culprits(uint256 id, uint256 i) external view returns (address);
    function victimAt(uint256 id, uint256 i) external view returns (address);
    function balanceAt(uint256 id, uint256 i) external view returns (uint256);
    function oracleData(uint256 id) external view returns (uint256[6] memory);
    function metricData(uint256 id) external view returns (uint256[7] memory);
    function flagData(uint256 id) external view returns (bool[4] memory);
    function createClaim(address p, uint8 et, bytes32 h, uint256 loss, address by) external returns (uint256);
    function setOracleData(uint256 id, uint256[6] calldata d) external;
    function setMetricData(uint256 id, uint256[7] calldata d) external;
    function setFlagData(uint256 id, bool[4] calldata d) external;
    function setCulprits(uint256 id, address[] calldata d) external;
    function setVictims(uint256 id, address[] calldata s, uint256[] calldata b) external;
    function setStatus(uint256 id, IStore.Status s) external;
    function setDenial(uint256 id, string calldata r) external;
    function setEnforced(uint256 id) external;
}

interface IEl {
    function check(uint8 et, uint256[7] calldata m, bool[4] calldata f, uint256 c) external pure returns (bool, string memory);
}

interface IPool {
    function fundClaim(uint256 id, uint256 amt) external;
    function proRataFundClaim(uint256 id, uint256 amt) external;
    function protectionReserve() external view returns (uint256);
}

interface ISFI  { function mint(address to, uint256 amt, uint256 id) external returns (uint256); }
interface ITAD  {
    function blacklistWallet(address w, uint256 id, string calldata r) external;
    function fileEnforcementRecord(uint256 id, address p, bytes32 h, address[] calldata c, uint256 l) external;
    function isBlacklisted(address w) external view returns (bool);
}

contract SafeFiClaimEngine {

    address public owner;
    IStore  public store;
    IEl     public el;
    IPool   public pool;
    ISFI    public sfi;
    ITAD    public tad;

    mapping(address => bool) public isMonitor;
    mapping(address => bool) public isCouncil;
    uint256 public maxPct = 8000;

    event Detected(uint256 indexed id, address indexed project);
    event Approved(uint256 indexed id, uint256 amt);
    event Paid(uint256 indexed id, uint256 amt);
    event Denied(uint256 indexed id, string reason);
    event ClaimPaused(uint256 indexed id);
    event ClaimEscalated(uint256 indexed id);

    modifier onlyOwner()   { require(msg.sender == owner, "not owner"); _; }
    modifier onlyMonitor() { require(isMonitor[msg.sender], "not monitor"); _; }
    modifier onlyCouncil() { require(isCouncil[msg.sender] || msg.sender == owner, "not council"); _; }

    constructor(address _store, address _el, address _pool, address _sfi, address _tad, address _owner) {
        owner = _owner;
        store = IStore(_store);
        el    = IEl(_el);
        pool  = IPool(_pool);
        sfi   = ISFI(_sfi);
        tad   = ITAD(_tad);
    }

    function setMonitor(address a, bool v) external onlyOwner { isMonitor[a] = v; }
    function setCouncil(address a, bool v) external onlyOwner { isCouncil[a] = v; }
    function setMaxPct(uint256 v) external onlyOwner { require(v <= 10000); maxPct = v; }
    function setStore(address a) external onlyOwner { require(a != address(0)); store = IStore(a); }
    function setPool(address a) external onlyOwner { require(a != address(0)); pool = IPool(a); }
    function setSFI(address a) external onlyOwner { require(a != address(0)); sfi = ISFI(a); }

    // ── Step 1a ───────────────────────────────────────────
    function submitIncident(address project, uint8 eventType, bytes32 hash, uint256 lossUSD)
        external onlyMonitor returns (uint256 id)
    {
        require(project != address(0) && hash != bytes32(0) && lossUSD > 0, "bad args");
        id = store.createClaim(project, eventType, hash, lossUSD, msg.sender);
        emit Detected(id, project);
    }

    // ── Step 1b ───────────────────────────────────────────
    function submitData(uint256 id, uint256[6] calldata oracles, uint256[7] calldata metrics, bool[4] calldata flags)
        external onlyMonitor
    {
        store.setOracleData(id, oracles);
        store.setMetricData(id, metrics);
        store.setFlagData(id, flags);
    }

    // ── Step 1c ───────────────────────────────────────────
    function submitParties(uint256 id, address[] calldata culpritList, address[] calldata victims, uint256[] calldata balances)
        external onlyMonitor
    {
        require(victims.length > 0 && victims.length == balances.length, "bad victims");
        store.setCulprits(id, culpritList);
        store.setVictims(id, victims, balances);
    }

    // ── Step 2: Process ───────────────────────────────────
    function processEligibility(uint256 id) external {
        require(store.claimStatus(id) == IStore.Status.Submitted, "not submitted");
        store.setStatus(id, IStore.Status.Checking);
        if (_oracleFailed(id)) {
            store.setStatus(id, IStore.Status.Paused);
            emit ClaimPaused(id);
            return;
        }
        _checkEl(id);
    }

    function _checkEl(uint256 id) internal {
        uint256[7] memory m = store.metricData(id);
        bool[4]    memory f = store.flagData(id);
        uint256 c = _countCulprits(id);
        uint8 et  = store.claimEventType(id);
        (bool ok, string memory reason) = el.check(et, m, f, c);
        if (!ok) {
            store.setStatus(id, IStore.Status.Denied);
            store.setDenial(id, reason);
            emit Denied(id, reason);
            return;
        }
        uint256 loss = store.claimLoss(id);
        store.setStatus(id, IStore.Status.Approved);
        emit Approved(id, loss);
        _pay(id, loss);
    }

    // ── Oracle check ──────────────────────────────────────
    function _oracleFailed(uint256 id) internal view returns (bool) {
        uint256[6] memory o = store.oracleData(id);
        bool a1 = o[0] > 0 && (block.timestamp - o[3]) <= 900;
        bool a2 = o[1] > 0 && (block.timestamp - o[4]) <= 900;
        bool a3 = o[2] > 0 && (block.timestamp - o[5]) <= 900;
        uint256 cnt = (a1?1:0)+(a2?1:0)+(a3?1:0);
        if (cnt == 0) return true;
        if (cnt == 1) {
            uint256 t = a1 ? o[3] : (a2 ? o[4] : o[5]);
            return (block.timestamp - t) > 1800;
        }
        return false;
    }

    // ── Count culprits ────────────────────────────────────
    function _countCulprits(uint256 id) internal view returns (uint256 n) {
        for (uint256 i = 0; i < 20; i++) {
            try store.culprits(id, i) returns (address a) {
                if (a == address(0)) break;
                n++;
            } catch { break; }
        }
    }

    // ── Payout ────────────────────────────────────────────
    function _pay(uint256 id, uint256 loss) internal {
        uint256 reserve = pool.protectionReserve();
        uint256 amt = loss > (reserve * maxPct / 10000) ? (reserve * maxPct / 10000) : loss;
        if (reserve >= amt) pool.fundClaim(id, amt);
        else { pool.proRataFundClaim(id, amt); store.setStatus(id, IStore.Status.ProRata); }
        _mintVictims(id, amt);
        if (store.claimStatus(id) != IStore.Status.ProRata) store.setStatus(id, IStore.Status.Paid);
        emit Paid(id, amt);
        _enforce(id, amt);
    }

    function _mintVictims(uint256 id, uint256 amt) internal {
        uint256 total;
        for (uint256 i = 0; i < 500; i++) {
            try store.balanceAt(id, i) returns (uint256 b) { total += b; } catch { break; }
        }
        if (total == 0) return;
        for (uint256 i = 0; i < 500; i++) {
            address v; uint256 b;
            try store.victimAt(id, i) returns (address a)  { v = a; } catch { break; }
            try store.balanceAt(id, i) returns (uint256 x) { b = x; } catch { break; }
            if (b > 0) sfi.mint(v, (amt * b) / total, id);
        }
    }

    // ── Enforcement ───────────────────────────────────────
    function _enforce(uint256 id, uint256 loss) internal {
        address proj  = store.claimProject(id);
        bytes32 hash  = store.claimHash(id);
        address[] memory c = new address[](20);
        uint256 n;
        for (uint256 i = 0; i < 20; i++) {
            try store.culprits(id, i) returns (address a) {
                if (a == address(0)) break;
                if (!tad.isBlacklisted(a)) tad.blacklistWallet(a, id, "SAFEFI");
                c[n++] = a;
            } catch { break; }
        }
        if (n == 0) return;
        address[] memory trimmed = new address[](n);
        for (uint256 i = 0; i < n; i++) trimmed[i] = c[i];
        tad.fileEnforcementRecord(id, proj, hash, trimmed, loss);
        store.setEnforced(id);
    }

    // ── Council ───────────────────────────────────────────
    function councilApprove(uint256 id) external onlyCouncil {
        IStore.Status s = store.claimStatus(id);
        require(s == IStore.Status.Escalated || s == IStore.Status.Paused, "wrong status");
        uint256 loss = store.claimLoss(id);
        store.setStatus(id, IStore.Status.Approved);
        emit Approved(id, loss);
        _pay(id, loss);
    }

    function councilDeny(uint256 id, string calldata reason) external onlyCouncil {
        IStore.Status s = store.claimStatus(id);
        require(s == IStore.Status.Escalated || s == IStore.Status.Paused, "wrong status");
        store.setStatus(id, IStore.Status.Denied);
        store.setDenial(id, reason);
        emit Denied(id, reason);
    }

    function escalate(uint256 id) external onlyMonitor {
        store.setStatus(id, IStore.Status.Escalated);
        emit ClaimEscalated(id);
    }

    // ── Views ─────────────────────────────────────────────
    function getStatus(uint256 id) external view returns (IStore.Status) { return store.claimStatus(id); }
    function getLoss(uint256 id)   external view returns (uint256)        { return store.claimLoss(id); }
    function totalClaims()         external view returns (uint256)        { return store.claimCount(); }
}
