// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IAny2EVMMessageReceiver } from "chainlink-ccip/chains/evm/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "chainlink-ccip/chains/evm/contracts/interfaces/IRouterClient.sol";
import { Client } from "chainlink-ccip/chains/evm/contracts/libraries/Client.sol";

import { ILaneVaultSettlement, LaneSettlementAdapter } from "../src/LaneSettlementAdapter.sol";

contract MockLaneSettlementVault is ILaneVaultSettlement {
  bytes32 internal constant GOV_ROLE = keccak256("GOVERNANCE_ROLE");

  mapping(address => bool) internal _isGov;

  uint256 public successCalls;
  uint256 public lossCalls;

  bytes32 public lastSuccessFillId;
  uint256 public lastSuccessPrincipal;
  uint256 public lastSuccessFee;

  bytes32 public lastLossFillId;
  uint256 public lastLossPrincipal;
  uint256 public lastLossRecovered;

  function GOVERNANCE_ROLE() external pure returns (bytes32) {
    return GOV_ROLE;
  }

  function hasRole(bytes32 role, address account) external view returns (bool) {
    return role == GOV_ROLE && _isGov[account];
  }

  function setGovernance(address account, bool allowed) external {
    _isGov[account] = allowed;
  }

  function reconcileSettlementSuccess(bytes32 fillId, uint256 principalAssets, uint256 netFeeIncomeAssets) external {
    successCalls += 1;
    lastSuccessFillId = fillId;
    lastSuccessPrincipal = principalAssets;
    lastSuccessFee = netFeeIncomeAssets;
  }

  function reconcileSettlementLoss(bytes32 fillId, uint256 principalAssets, uint256 recoveredAssets) external {
    lossCalls += 1;
    lastLossFillId = fillId;
    lastLossPrincipal = principalAssets;
    lastLossRecovered = recoveredAssets;
  }
}

contract MockRouterClient is IRouterClient {
  uint256 public quotedFee = 123_456;

  function isChainSupported(uint64) external pure returns (bool supported) {
    return true;
  }

  function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256 fee) {
    return quotedFee;
  }

  function ccipSend(uint64, Client.EVM2AnyMessage calldata) external payable returns (bytes32) {
    return bytes32(uint256(1));
  }

  function setQuotedFee(uint256 fee) external {
    quotedFee = fee;
  }

  function deliver(address receiver, Client.Any2EVMMessage memory message) external {
    IAny2EVMMessageReceiver(receiver).ccipReceive(message);
  }
}

contract LaneSettlementAdapterTest is Test {
  uint64 internal constant SOURCE_CHAIN_A = 16015286601757825753;
  uint64 internal constant SOURCE_CHAIN_B = 14767482510784806043;

  address internal sourceSenderA = makeAddr("source-sender-a");
  address internal sourceSenderB = makeAddr("source-sender-b");

  MockLaneSettlementVault internal vault;
  MockRouterClient internal router;
  LaneSettlementAdapter internal adapter;

  function setUp() public {
    vault = new MockLaneSettlementVault();
    vault.setGovernance(address(this), true);

    router = new MockRouterClient();
    adapter = new LaneSettlementAdapter(address(router), ILaneVaultSettlement(address(vault)));
  }

  function testSetAllowedSourceRequiresVaultGovernance() public {
    address attacker = makeAddr("attacker");

    vm.prank(attacker);
    vm.expectRevert(LaneSettlementAdapter.NotVaultGovernance.selector);
    adapter.setAllowedSource(SOURCE_CHAIN_A, sourceSenderA, true);

    adapter.setAllowedSource(SOURCE_CHAIN_A, sourceSenderA, true);
    assertTrue(adapter.isAllowedSource(SOURCE_CHAIN_A, sourceSenderA), "source should be allowlisted");
  }

  function testSourceAllowlistCheckedBeforePayloadDecode() public {
    Client.Any2EVMMessage memory message = _buildMessage(
      SOURCE_CHAIN_A,
      sourceSenderA,
      keccak256("msg-disallowed"),
      hex"123456" // invalid payload encoding on purpose
    );

    vm.expectRevert(
      abi.encodeWithSelector(LaneSettlementAdapter.SourceNotAllowed.selector, SOURCE_CHAIN_A, sourceSenderA)
    );
    router.deliver(address(adapter), message);
  }

  function testPayloadVersionAndDomainBinding() public {
    adapter.setAllowedSource(SOURCE_CHAIN_A, sourceSenderA, true);

    LaneSettlementAdapter.SettlementPayload memory payload = _validPayload(keccak256("fill-1"));

    payload.version = 2;
    vm.expectRevert(abi.encodeWithSelector(LaneSettlementAdapter.InvalidPayload.selector, "invalid_version"));
    router.deliver(
      address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, keccak256("msg-version"), abi.encode(payload))
    );

    payload = _validPayload(keccak256("fill-2"));
    payload.vault = makeAddr("wrong-vault");
    vm.expectRevert(abi.encodeWithSelector(LaneSettlementAdapter.InvalidPayload.selector, "invalid_vault"));
    router.deliver(
      address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, keccak256("msg-vault"), abi.encode(payload))
    );

    payload = _validPayload(keccak256("fill-3"));
    payload.chainId = block.chainid + 1;
    vm.expectRevert(abi.encodeWithSelector(LaneSettlementAdapter.InvalidPayload.selector, "invalid_chainid"));
    router.deliver(
      address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, keccak256("msg-chainid"), abi.encode(payload))
    );
  }

  function testReplayProtectionUsesSourceSenderAndMessageTuple() public {
    adapter.setAllowedSource(SOURCE_CHAIN_A, sourceSenderA, true);
    adapter.setAllowedSource(SOURCE_CHAIN_A, sourceSenderB, true);

    bytes32 messageId = keccak256("shared-message-id");
    bytes32 keyA = adapter.computeReplayKey(SOURCE_CHAIN_A, sourceSenderA, messageId);
    bytes32 keyB = adapter.computeReplayKey(SOURCE_CHAIN_A, sourceSenderB, messageId);
    bytes32 keyC = adapter.computeReplayKey(SOURCE_CHAIN_B, sourceSenderA, messageId);

    assertTrue(keyA != keyB, "sender must change replay key");
    assertTrue(keyA != keyC, "source chain must change replay key");

    LaneSettlementAdapter.SettlementPayload memory payloadA = _validPayload(keccak256("fill-success-a"));
    router.deliver(address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, messageId, abi.encode(payloadA)));

    vm.expectRevert(abi.encodeWithSelector(LaneSettlementAdapter.ReplayDetected.selector, keyA));
    router.deliver(address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, messageId, abi.encode(payloadA)));

    LaneSettlementAdapter.SettlementPayload memory payloadB = _validPayload(keccak256("fill-success-b"));
    router.deliver(address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderB, messageId, abi.encode(payloadB)));

    assertTrue(adapter.replayConsumed(keyA), "replay key A should be consumed");
    assertTrue(adapter.replayConsumed(keyB), "replay key B should be consumed");
    assertEq(vault.successCalls(), 2, "both distinct tuples should settle");
  }

  function testSettlementLossPathAndPayloadValidation() public {
    adapter.setAllowedSource(SOURCE_CHAIN_A, sourceSenderA, true);

    LaneSettlementAdapter.SettlementPayload memory payload = _validPayload(keccak256("fill-loss"));
    payload.success = false;
    payload.recoveredAssets = 90;
    payload.netFeeIncomeAssets = 0;

    router.deliver(
      address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, keccak256("msg-loss"), abi.encode(payload))
    );

    assertEq(vault.lossCalls(), 1, "loss reconciliation should be called");
    assertEq(vault.lastLossRecovered(), 90, "loss recovered amount mismatch");

    payload = _validPayload(keccak256("fill-loss-invalid"));
    payload.success = false;
    payload.recoveredAssets = payload.principalAssets + 1;

    vm.expectRevert(abi.encodeWithSelector(LaneSettlementAdapter.InvalidPayload.selector, "invalid_recovered_assets"));
    router.deliver(
      address(adapter), _buildMessage(SOURCE_CHAIN_A, sourceSenderA, keccak256("msg-loss-invalid"), abi.encode(payload))
    );
  }

  function testGetFeePassesThroughRouter() public {
    router.setQuotedFee(987_654);

    Client.EVM2AnyMessage memory outbound = Client.EVM2AnyMessage({
      receiver: abi.encode(makeAddr("dest-receiver")),
      data: hex"abcd",
      tokenAmounts: new Client.EVMTokenAmount[](0),
      feeToken: address(0),
      extraArgs: hex""
    });

    uint256 quoted = adapter.getFee(42, outbound);
    assertEq(quoted, 987_654, "adapter fee quote mismatch");
  }

  function _validPayload(bytes32 fillId)
    internal
    view
    returns (LaneSettlementAdapter.SettlementPayload memory payload)
  {
    payload = LaneSettlementAdapter.SettlementPayload({
      version: adapter.PAYLOAD_VERSION(),
      vault: address(vault),
      chainId: block.chainid,
      routeId: keccak256(abi.encode(fillId, "route")),
      fillId: fillId,
      success: true,
      principalAssets: 100,
      netFeeIncomeAssets: 15,
      recoveredAssets: 0
    });
  }

  function _buildMessage(uint64 sourceChainSelector, address sourceSender, bytes32 messageId, bytes memory data)
    internal
    pure
    returns (Client.Any2EVMMessage memory message)
  {
    message = Client.Any2EVMMessage({
      messageId: messageId,
      sourceChainSelector: sourceChainSelector,
      sender: abi.encode(sourceSender),
      data: data,
      destTokenAmounts: new Client.EVMTokenAmount[](0)
    });
  }
}
