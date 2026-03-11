// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * SafeFiClaimStore.sol - Pure Storage
 * SafeFi Tech Solutions Ltd | Kasali Ayomide Emmanuel
 */
contract SafeFiClaimStore {

    address public owner;
    address public engine;

    modifier onlyEngine() { require(msg.sender == engine, "not engine"); _; }
    modifier onlyOwner()  { require(msg.sender == owner,  "not owner");  _; }

    constructor(address _owner) { owner = _owner; }
    function setEngine(address e) external onlyOwner { engine = e; }

    enum Status { Submitted, Checking, Approved, Paid, Denied, Escalated, Paused, ProRata }

    uint256 public claimCount;
    mapping(uint256 => Status)   public claimStatus;
    mapping(uint256 => uint8)    public claimEventType;
    mapping(uint256 => address)  public claimProject;
    mapping(uint256 => bytes32)  public claimHash;
    mapping(uint256 => uint256)  public claimLoss;
    mapping(uint256 => uint256)  public claimTime;
    mapping(uint256 => address)  public claimBy;
    mapping(uint256 => string)   public claimDenial;
    mapping(uint256 => bool)     public claimEnforced;

    mapping(uint256 => address[]) public culprits;
    mapping(uint256 => address[]) private _victims;
    mapping(uint256 => uint256[]) private _balances;
    mapping(address => uint256[]) public projectClaims;

    mapping(uint256 => uint256[6]) private _oracle;
    mapping(uint256 => uint256[7]) private _metric;
    mapping(uint256 => bool[4])    private _flags;

    function createClaim(address p, uint8 et, bytes32 h, uint256 loss, address by)
        external onlyEngine returns (uint256 id)
    {
        id = claimCount++;
        claimStatus[id]    = Status.Submitted;
        claimEventType[id] = et;
        claimProject[id]   = p;
        claimHash[id]      = h;
        claimLoss[id]      = loss;
        claimTime[id]      = block.timestamp;
        claimBy[id]        = by;
        projectClaims[p].push(id);
    }

    function setOracleData(uint256 id, uint256[6] calldata d) external onlyEngine { _oracle[id] = d; }
    function setMetricData(uint256 id, uint256[7] calldata d) external onlyEngine { _metric[id] = d; }
    function setFlagData(uint256 id, bool[4] calldata d)      external onlyEngine { _flags[id]  = d; }
    function setCulprits(uint256 id, address[] calldata d)    external onlyEngine { culprits[id] = d; }
    function setStatus(uint256 id, Status s)                  external onlyEngine { claimStatus[id] = s; }
    function setDenial(uint256 id, string calldata r)         external onlyEngine { claimDenial[id] = r; }
    function setEnforced(uint256 id)                          external onlyEngine { claimEnforced[id] = true; }

    function setVictims(uint256 id, address[] calldata s, uint256[] calldata b)
        external onlyEngine
    {
        _victims[id]  = s;
        _balances[id] = b;
    }

    function oracleData(uint256 id) external view returns (uint256[6] memory) { return _oracle[id]; }
    function metricData(uint256 id) external view returns (uint256[7] memory) { return _metric[id]; }
    function flagData(uint256 id)   external view returns (bool[4]    memory) { return _flags[id];  }

    function victimAt(uint256 id, uint256 i)  external view returns (address) { return _victims[id][i];  }
    function balanceAt(uint256 id, uint256 i) external view returns (uint256) { return _balances[id][i]; }

    function getProjectClaims(address p) external view returns (uint256[] memory) {
        return projectClaims[p];
    }
}
