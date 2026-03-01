// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title LaneQueueManager
/// @notice Strict FIFO queue for redemption requests.
/// @dev Queue entries are append-only and non-cancelable by policy.
contract LaneQueueManager {
  error OnlyVault();
  error InvalidVault();
  error EmptyQueue();
  error InvalidRequest();

  struct RedeemRequest {
    uint256 requestId;
    address owner;
    address receiver;
    uint256 shares;
    uint64 enqueuedAt;
  }

  address public immutable vault;
  uint256 public headRequestId;
  uint256 public tailRequestId;

  mapping(uint256 => RedeemRequest) private _requests;

  event Enqueued(uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares);
  event Dequeued(uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares);

  modifier onlyVault() {
    if (msg.sender != vault) revert OnlyVault();
    _;
  }

  constructor(address vault_) {
    if (vault_ == address(0)) revert InvalidVault();
    vault = vault_;
  }

  function enqueue(address owner, address receiver, uint256 shares) external onlyVault returns (uint256 requestId) {
    if (owner == address(0) || receiver == address(0) || shares == 0) revert InvalidRequest();

    requestId = tailRequestId + 1;
    tailRequestId = requestId;
    if (headRequestId == 0) {
      headRequestId = requestId;
    }

    _requests[requestId] = RedeemRequest({
      requestId: requestId, owner: owner, receiver: receiver, shares: shares, enqueuedAt: uint64(block.timestamp)
    });

    emit Enqueued(requestId, owner, receiver, shares);
  }

  function peek() external view returns (bool exists, RedeemRequest memory request) {
    if (pendingCount() == 0) {
      return (false, request);
    }
    return (true, _requests[headRequestId]);
  }

  function dequeue() external onlyVault returns (RedeemRequest memory request) {
    if (pendingCount() == 0) revert EmptyQueue();

    uint256 currentHead = headRequestId;
    request = _requests[currentHead];
    delete _requests[currentHead];

    if (currentHead >= tailRequestId) {
      headRequestId = 0;
      tailRequestId = 0;
    } else {
      headRequestId = currentHead + 1;
    }

    emit Dequeued(request.requestId, request.owner, request.receiver, request.shares);
  }

  function pendingCount() public view returns (uint256) {
    if (headRequestId == 0 || tailRequestId == 0 || tailRequestId < headRequestId) {
      return 0;
    }
    return (tailRequestId - headRequestId) + 1;
  }

  function getRequest(uint256 requestId) external view returns (RedeemRequest memory) {
    return _requests[requestId];
  }
}

