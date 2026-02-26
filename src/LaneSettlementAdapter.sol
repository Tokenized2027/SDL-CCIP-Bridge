// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CCIPReceiver } from "chainlink-ccip/chains/evm/contracts/applications/CCIPReceiver.sol";
import { Client } from "chainlink-ccip/chains/evm/contracts/libraries/Client.sol";
import { IRouterClient } from "chainlink-ccip/chains/evm/contracts/interfaces/IRouterClient.sol";

interface ILaneVaultSettlement {
  function GOVERNANCE_ROLE() external view returns (bytes32);
  function hasRole(bytes32 role, address account) external view returns (bool);
  function reconcileSettlementSuccess(bytes32 fillId, uint256 principalAssets, uint256 netFeeIncomeAssets) external;
  function reconcileSettlementLoss(bytes32 fillId, uint256 principalAssets, uint256 recoveredAssets) external;
}

/// @title LaneSettlementAdapter
/// @notice CCIP receiver adapter with tuple replay protection and payload domain/version binding.
contract LaneSettlementAdapter is CCIPReceiver {
  error NotVaultGovernance();
  error SourceNotAllowed(uint64 sourceChainSelector, address sender);
  error ReplayDetected(bytes32 replayKey);
  error InvalidPayload(string reason);

  uint16 public constant PAYLOAD_VERSION = 1;

  struct SettlementPayload {
    uint16 version;
    address vault;
    uint256 chainId;
    bytes32 routeId;
    bytes32 fillId;
    bool success;
    uint256 principalAssets;
    uint256 netFeeIncomeAssets;
    uint256 recoveredAssets;
  }

  ILaneVaultSettlement public immutable vault;
  mapping(uint64 => mapping(address => bool)) public isAllowedSource;
  mapping(bytes32 => bool) public replayConsumed;

  event SourceUpdated(uint64 indexed sourceChainSelector, address indexed sender, bool allowed);
  event SettlementProcessed(
    bytes32 indexed messageId, bytes32 indexed replayKey, bytes32 indexed fillId, bool success, uint256 principalAssets
  );

  constructor(address router, ILaneVaultSettlement vault_) CCIPReceiver(router) {
    vault = vault_;
  }

  function setAllowedSource(uint64 sourceChainSelector, address sender, bool allowed) external {
    _requireVaultGovernance(msg.sender);
    isAllowedSource[sourceChainSelector][sender] = allowed;
    emit SourceUpdated(sourceChainSelector, sender, allowed);
  }

  function computeReplayKey(uint64 sourceChainSelector, address sender, bytes32 messageId)
    public
    pure
    returns (bytes32)
  {
    return keccak256(abi.encode(sourceChainSelector, sender, messageId));
  }

  function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
    external
    view
    returns (uint256)
  {
    return IRouterClient(getRouter()).getFee(destinationChainSelector, message);
  }

  function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
    address sourceSender = abi.decode(message.sender, (address));
    if (!isAllowedSource[message.sourceChainSelector][sourceSender]) {
      revert SourceNotAllowed(message.sourceChainSelector, sourceSender);
    }

    bytes32 replayKey = computeReplayKey(message.sourceChainSelector, sourceSender, message.messageId);
    if (replayConsumed[replayKey]) revert ReplayDetected(replayKey);

    SettlementPayload memory payload = abi.decode(message.data, (SettlementPayload));
    if (payload.version != PAYLOAD_VERSION) revert InvalidPayload("invalid_version");
    if (payload.vault != address(vault)) revert InvalidPayload("invalid_vault");
    if (payload.chainId != block.chainid) revert InvalidPayload("invalid_chainid");
    if (payload.fillId == bytes32(0) || payload.principalAssets == 0) revert InvalidPayload("invalid_settlement");

    replayConsumed[replayKey] = true;

    if (payload.success) {
      vault.reconcileSettlementSuccess(payload.fillId, payload.principalAssets, payload.netFeeIncomeAssets);
    } else {
      if (payload.recoveredAssets > payload.principalAssets) revert InvalidPayload("invalid_recovered_assets");
      vault.reconcileSettlementLoss(payload.fillId, payload.principalAssets, payload.recoveredAssets);
    }

    emit SettlementProcessed(message.messageId, replayKey, payload.fillId, payload.success, payload.principalAssets);
  }

  function _requireVaultGovernance(address caller) internal view {
    bytes32 governanceRole = vault.GOVERNANCE_ROLE();
    if (!vault.hasRole(governanceRole, caller)) revert NotVaultGovernance();
  }
}

