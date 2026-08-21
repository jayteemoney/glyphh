// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @notice Minimal Pyth stand-in: settable price, confidence, exponent, and staleness.
/// @dev    Only the surface `PythPriceOracle` actually calls. A feed that has not been set
///         reverts, exactly as the real `getPriceNoOlderThan` does when a price is missing or
///         older than the requested age — which is the behaviour the adapter must absorb
///         rather than propagate.
contract MockPyth {
    struct Feed {
        int64 price;
        uint64 conf;
        int32 expo;
        bool set;
        bool stale;
    }

    mapping(bytes32 => Feed) public feeds;

    function setFeed(bytes32 id, int64 price, uint64 conf, int32 expo) external {
        feeds[id] = Feed({price: price, conf: conf, expo: expo, set: true, stale: false});
    }

    function setStale(bytes32 id, bool isStale) external {
        feeds[id].stale = isStale;
    }

    function getPriceNoOlderThan(bytes32 id, uint256) external view returns (PythStructs.Price memory p) {
        Feed memory f = feeds[id];
        require(f.set && !f.stale, "StalePrice");
        p.price = f.price;
        p.conf = f.conf;
        p.expo = f.expo;
        p.publishTime = block.timestamp;
    }
}
