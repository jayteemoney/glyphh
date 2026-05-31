// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";

contract GlyphReactive {
    uint256 public constant ORIGIN_CHAIN_ID    = 1301;
    uint256 public constant DEST_CHAIN_ID      = 1301;
    uint256 public constant CALLBACK_GAS_LIMIT = 200_000;
    uint32  public constant MAX_AGGREGATE_COUNT = 1_000;
    uint16  public constant DISPATCH_THRESHOLD  = 500;

    struct Aggregate {
        uint32 count;
        uint64 scoreSum;
        uint64 lastUpdated;
    }

    address public owner;
    address public registryOnDestination;

    mapping(address => Aggregate) public aggregates;
    mapping(address => bool)      public subscribedHooks;

    event Subscribed(address indexed hook, uint256 chainId);
    event AggregateUpdated(address indexed wallet, uint64 newSum, uint32 count);
    event CallbackDispatched(address indexed wallet, uint16 aggregateScore);

    error NotOwner();
    error AlreadySubscribed();

    constructor(address _registry) {
        owner                 = msg.sender;
        registryOnDestination = _registry;
    }

    function react(
        uint256 chainId,
        address,
        uint256,
        uint256,
        bytes32,
        uint256,
        address  wallet,
        uint16   localSeverity
    ) external {
        if (chainId != ORIGIN_CHAIN_ID) return;

        Aggregate storage agg = aggregates[wallet];

        if (agg.count < MAX_AGGREGATE_COUNT) {
            unchecked { agg.count++; }
        }
        uint64 newSum = agg.scoreSum + localSeverity;
        if (newSum < agg.scoreSum) newSum = type(uint64).max;
        agg.scoreSum    = newSum;
        agg.lastUpdated = uint64(block.timestamp);

        emit AggregateUpdated(wallet, newSum, agg.count);

        uint256 avg = agg.count == 0 ? 0 : uint256(agg.scoreSum) / agg.count;
        uint16 aggregateScore = avg > 10_000 ? 10_000 : uint16(avg);

        if (aggregateScore >= DISPATCH_THRESHOLD) {
            _dispatchCallback(wallet, aggregateScore);
        }
    }

    function subscribeToHook(address hookAddress) external {
        if (msg.sender != owner) revert NotOwner();
        if (subscribedHooks[hookAddress]) revert AlreadySubscribed();
        subscribedHooks[hookAddress] = true;
        emit Subscribed(hookAddress, ORIGIN_CHAIN_ID);
    }

    function updateRegistry(address newRegistry) external {
        if (msg.sender != owner) revert NotOwner();
        registryOnDestination = newRegistry;
    }

    function _dispatchCallback(address wallet, uint16 aggregateScore) internal {
        bytes memory payload = abi.encodeWithSelector(
            IReputationRegistry.updateScoreFromReactive.selector,
            wallet,
            aggregateScore
        );
        emit CallbackDispatched(wallet, aggregateScore);
        (payload);
    }
}
