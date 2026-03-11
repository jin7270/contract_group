// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ========================================================
// 1. Library (상태 관리 로직)
// ========================================================
library StateLogic {
    enum VaultState { READY, DEATH_CERT_SUBMITTED, WILL_CHECKED, HEIR_KYC_COMPLETED, HEIR_CONFIRMED, UNLOCK_READY, UNLOCKED, SERVICE_PAUSED, WITHDRAW_COMPLETED }

    function isForwardTransition(VaultState from, VaultState to, bool needsWill) internal pure returns (bool) {
        if (to == VaultState.SERVICE_PAUSED) return from != VaultState.WITHDRAW_COMPLETED;
        if (from == VaultState.SERVICE_PAUSED && to == VaultState.READY) return true;
        if (!needsWill && from == VaultState.DEATH_CERT_SUBMITTED && to == VaultState.HEIR_KYC_COMPLETED) return true;
        if (uint(to) == uint(from) + 1) return true;
        return false;
    }

    function isRevertAllowed(VaultState current, VaultState target) internal pure returns (bool) {
        if (current == VaultState.UNLOCK_READY || current == VaultState.UNLOCKED || current == VaultState.WITHDRAW_COMPLETED) return false;
        if (current == VaultState.SERVICE_PAUSED) return target == VaultState.READY;
        return uint(target) < uint(current);
    }
}

// ========================================================
// 2. Main Contract (단일 마스터 Vault - 최종 클린)
// ========================================================
contract SanmantecInheritanceVaultV4Clean {
    using StateLogic for StateLogic.VaultState;

    // ----------------------------------------------------
    // 2.1. Admin & Global Configuration
    // ----------------------------------------------------
    address public companyServer;
    address public companyCold;
    uint256 public nextVaultId = 1;
    uint256 public minimumDeposit; 

    // ----------------------------------------------------
    // 2.2. Vault Structure
    // ----------------------------------------------------
    struct Vault {
        address owner;
        address heir;
        bool needsWill;
        uint256 maintenanceDeposit; // KLAY 보증금 잔액
        StateLogic.VaultState state;
        bool isFrozen;
        bool isHeirConfirmed;
        mapping(address => bool) unlockApprovals; 
        uint256 approvalCount;
        uint256 assetBalance; // 상속 대상 KLAY 자산
    }

    mapping(uint256 => Vault) internal vaults;
    mapping(address => uint256[]) public myVaults;
    mapping(address => bool) public isOwnerRegistered; 

    // ----------------------------------------------------
    // 2.3. Events
    // ----------------------------------------------------
    event VaultCreated(uint256 indexed vaultId, address indexed owner, address indexed heir, uint256 time);
    event StateChanged(uint256 indexed vaultId, StateLogic.VaultState from, StateLogic.VaultState to, uint256 time);
    event UnlockExecuted(uint256 indexed vaultId, address indexed oldOwner, address indexed newOwner);
    event AllKLAYWithdrawn(uint256 indexed vaultId, uint256 totalAmount, address indexed to); 
    event ServicePaused(uint256 indexed vaultId); 
    event ServiceResumed(uint256 indexed vaultId); 
    event OwnerFrozen(uint256 indexed vaultId); 
    event HeirChanged(uint256 indexed vaultId, address oldHeir, address newHeir);
    event MinimumDepositUpdated(uint256 newMinimum);
    event HeirConfirmed(uint256 indexed vaultId, address indexed heir);


    // ----------------------------------------------------
    // 2.4. Modifiers
    // ----------------------------------------------------
    modifier onlyOwner(uint256 vaultId) {
        require(vaults[vaultId].owner != address(0), "Vault does not exist");
        require(msg.sender == vaults[vaultId].owner, "Only owner");
        _;
    }
    modifier onlyHeir(uint256 vaultId) {
        require(vaults[vaultId].heir != address(0), "Vault does not exist");
        require(msg.sender == vaults[vaultId].heir, "Only heir");
        _;
    }
    modifier onlyAdmins() {
        require(msg.sender == companyServer || msg.sender == companyCold, "Not admin");
        _;
    }

    // ----------------------------------------------------
    // 2.5. Constructor & Vault Creation
    // ----------------------------------------------------
    constructor(address _server, address _cold, uint256 _minimumDeposit) {
        companyServer = _server;
        companyCold = _cold;
        minimumDeposit = _minimumDeposit;
    }

    function createVault(address _heir, bool _needsWill) external {
        require(!isOwnerRegistered[msg.sender], "Owner already has a vault"); 
        require(_heir != address(0), "Invalid heir");

        uint256 vaultId = nextVaultId++; //
        Vault storage v = vaults[vaultId];

        v.owner = msg.sender;
        v.heir = _heir;
        v.needsWill = _needsWill;
        v.state = StateLogic.VaultState.READY;

        myVaults[msg.sender].push(vaultId);
        isOwnerRegistered[msg.sender] = true;  
        //플래그설정 owner주소 등록 플래그를 true로.. 새 지갑 못만들게 
        emit VaultCreated(vaultId, msg.sender, _heir, block.timestamp);
    }
    
    // ----------------------------------------------------
    // 2.6. KLAY Deposit Functions
    // ----------------------------------------------------
    
    function depositAssetKLAY(uint256 vaultId) external payable onlyOwner(vaultId) {
        require(msg.value > 0, "Zero value");
        Vault storage v = vaults[vaultId];
        v.assetBalance += msg.value;
    }
    
    function depositMaintenanceKLAY(uint256 vaultId) external payable onlyOwner(vaultId) {
        require(msg.value > 0, "Zero value");
        Vault storage v = vaults[vaultId];
        v.maintenanceDeposit += msg.value;

        if (v.maintenanceDeposit >= minimumDeposit && v.state == StateLogic.VaultState.SERVICE_PAUSED) {
            _changeState(vaultId, StateLogic.VaultState.READY);
            emit ServiceResumed(vaultId);
        }
    }

    // ----------------------------------------------------
    // 2.7. Workflow Functions (Admin, Heir)
    // ----------------------------------------------------
    
    // [Owner가 보증금 출금] - 제거됨! 통합 인출 함수만 사용합니다.
    // function ownerWithdrawMaintenanceKLAY(...) { ... } 
    
    function updateState(uint256 vaultId, StateLogic.VaultState newState) external onlyAdmins {
        Vault storage v = vaults[vaultId];
        
        if (v.maintenanceDeposit < minimumDeposit && newState != StateLogic.VaultState.SERVICE_PAUSED) {
            _changeState(vaultId, StateLogic.VaultState.SERVICE_PAUSED);
            emit ServicePaused(vaultId);
            revert("Insufficient maintenance deposit; Vault paused.");
        }
        
        require(v.state != StateLogic.VaultState.UNLOCKED, "Unlocked");
        require(v.state.isForwardTransition(newState, v.needsWill), "Invalid transition");

        if (newState == StateLogic.VaultState.HEIR_KYC_COMPLETED) {
            v.isFrozen = true;
            emit OwnerFrozen(vaultId); 
        }

        _resetApprovals(vaultId);
        _changeState(vaultId, newState);
    }

    function confirmByHeir(uint256 vaultId) external onlyHeir(vaultId) {
        Vault storage v = vaults[vaultId];
        require(v.state == StateLogic.VaultState.HEIR_KYC_COMPLETED, "Not ready");
        require(!v.isHeirConfirmed, "Confirmed");
        v.isHeirConfirmed = true;
        _changeState(vaultId, StateLogic.VaultState.HEIR_CONFIRMED);
        emit HeirConfirmed(vaultId, msg.sender);
    }
    
    function approveUnlock(uint256 vaultId) external onlyAdmins {
        Vault storage v = vaults[vaultId];
        require(v.isHeirConfirmed, "Heir confirm needed");
        require(
            v.state == StateLogic.VaultState.HEIR_CONFIRMED || v.state == StateLogic.VaultState.UNLOCK_READY,
            "Not ready"
        );

        if (!v.unlockApprovals[msg.sender]) {
            v.unlockApprovals[msg.sender] = true;
            v.approvalCount++;
        }

        if (v.approvalCount == 2) {
            _finalizeUnlock(vaultId);
        } else if (v.state == StateLogic.VaultState.HEIR_CONFIRMED) {
            _changeState(vaultId, StateLogic.VaultState.UNLOCK_READY);
        }
    }

    function _finalizeUnlock(uint256 vaultId) internal {
        Vault storage v = vaults[vaultId];
        address oldOwner = v.owner;
        v.owner = v.heir; 
        
        // [버그 수정]: Frozen 상태를 해제하여 보증금 인출 가능하게 함
        v.isFrozen = false; 
        
        emit UnlockExecuted(vaultId, oldOwner, v.heir);
        _changeState(vaultId, StateLogic.VaultState.UNLOCKED);
    }
    
    // ----------------------------------------------------
    // [최종 인출] 통합 KLAY 인출 함수 (Asset + Maintenance)
    // ----------------------------------------------------
    function withdrawAllKLAY(uint256 vaultId) external onlyOwner(vaultId) {
        Vault storage v = vaults[vaultId];
        // Owner는 Heir로 변경된 후의 Owner를 의미
        require(v.state == StateLogic.VaultState.UNLOCKED || v.state == StateLogic.VaultState.WITHDRAW_COMPLETED, "Locked");
        require(v.owner == v.heir, "Only the new owner (heir) can withdraw");

        uint256 assetAmount = v.assetBalance;
        uint256 maintenanceAmount = v.maintenanceDeposit;
        uint256 totalAmount = assetAmount + maintenanceAmount;

        require(totalAmount > 0, "No KLAY left to withdraw");

        // 잔액 초기화 (보증금 포함)
        v.assetBalance = 0;
        v.maintenanceDeposit = 0;

        // KLAY 전송 (Heir에게)
        payable(v.heir).transfer(totalAmount);
        
        emit AllKLAYWithdrawn(vaultId, totalAmount, v.heir);
        
        // 인출 완료 상태로 전환
        _changeState(vaultId, StateLogic.VaultState.WITHDRAW_COMPLETED);
    }

    // ----------------------------------------------------
    // 2.9. View/Utility Functions
    // ----------------------------------------------------
    
    function _resetApprovals(uint256 vaultId) internal {
        Vault storage v = vaults[vaultId];
        v.approvalCount = 0;
        v.unlockApprovals[companyServer] = false;
        v.unlockApprovals[companyCold] = false;
    }

    function _changeState(uint256 vaultId, StateLogic.VaultState newState) internal {
        Vault storage v = vaults[vaultId];
        emit StateChanged(vaultId, v.state, newState, block.timestamp);
        v.state = newState;
    }

    function getVaultInfo(uint256 vaultId) 
        external 
        view 
        returns (address owner, address heir, uint256 assetBalance, uint256 maintenanceDeposit, uint256 state) 
    {
        Vault storage v = vaults[vaultId];
        return (v.owner, v.heir, v.assetBalance, v.maintenanceDeposit, uint256(v.state));
    }
    
    function getVaultsOf(address user) external view returns (uint256[] memory) { 
        return myVaults[user]; 
    }
    
    // 컨트랙트가 KLAY를 받을 수 있도록 설정
    receive() external payable {}
}