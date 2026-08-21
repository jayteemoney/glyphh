// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PythPriceOracle} from "../src/oracles/PythPriceOracle.sol";
import {SettablePriceOracle} from "../src/oracles/SettablePriceOracle.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice The production oracle adapter.
///
/// @dev    Worth stating why this file exists. v1's oracle logic lived inside the hook and was
///         reachable only through a real `IPyth`, so every test constructed the hook with
///         `IPyth(address(0))` and the branch was never executed — which is how a bug that made
///         the whole toxicity check unusable reached deployment.
///
///         The contract these tests defend is: **a bad price is never an error.** Missing,
///         stale, zero, negative or low-confidence input must all return `available = false`
///         and let the hook price the swap on its remaining layers. An oracle that can revert
///         inside `beforeSwap` is an oracle that can halt a pool.
contract PythPriceOracleTest is Test {
    address constant OWNER = address(0xD1);
    bytes32 constant BASE = keccak256("ETH/USD");
    bytes32 constant QUOTE = keccak256("USDC/USD");
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));

    MockPyth pyth;
    PythPriceOracle oracle;

    function setUp() public {
        pyth = new MockPyth();
        oracle = new PythPriceOracle(IPyth(address(pyth)), OWNER);
        vm.prank(OWNER);
        oracle.setFeeds(POOL, BASE, QUOTE);
    }

    function _price(int64 base, int64 quote, int32 expo) internal {
        pyth.setFeed(BASE, base, 0, expo);
        pyth.setFeed(QUOTE, quote, 0, expo);
    }

    // ── The happy path ───────────────────────────────────────────────────────

    function test_returnsBaseOverQuoteScaledTo1e18() public {
        _price(2_000e8, 1e8, -8); // ETH 2000, USDC 1
        (uint256 price, bool ok) = oracle.referencePrice(POOL);
        assertTrue(ok);
        assertEq(price, 2_000e18);
    }

    function test_handlesDifferingExponents() public {
        pyth.setFeed(BASE, 2_000e8, 0, -8);
        pyth.setFeed(QUOTE, 1e6, 0, -6);
        (uint256 price, bool ok) = oracle.referencePrice(POOL);
        assertTrue(ok);
        assertEq(price, 2_000e18);
    }

    function test_subUnitPrice() public {
        _price(1e8, 2_000e8, -8);
        (uint256 price, bool ok) = oracle.referencePrice(POOL);
        assertTrue(ok);
        assertEq(price, 5e14); // 1/2000
    }

    // ── Every way a price can be unusable ────────────────────────────────────

    function test_unconfiguredPool_isUnavailable() public {
        (, bool ok) = oracle.referencePrice(PoolId.wrap(bytes32(uint256(99))));
        assertFalse(ok);
    }

    function test_missingFeed_isUnavailableNotRevert() public {
        // Feeds configured but never published.
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_staleBaseFeed_isUnavailable() public {
        _price(2_000e8, 1e8, -8);
        pyth.setStale(BASE, true);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_staleQuoteFeed_isUnavailable() public {
        _price(2_000e8, 1e8, -8);
        pyth.setStale(QUOTE, true);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_zeroPrice_isUnavailable() public {
        _price(0, 1e8, -8);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_negativePrice_isUnavailable() public {
        _price(-1e8, 1e8, -8);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    /// @dev A wide confidence band means Pyth itself is unsure. Acting on it would let oracle
    ///      noise quote the maximum fee to honest flow, which is the v1 failure in miniature.
    function test_wideConfidenceOnBase_isUnavailable() public {
        pyth.setFeed(BASE, 2_000e8, 2_000e8 / 50, -8); // 2% band, cap is 1%
        pyth.setFeed(QUOTE, 1e8, 0, -8);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    /// @dev The quote leg is gated too. A wide band there distorts the ratio just as much,
    ///      and v1 checked only the base.
    function test_wideConfidenceOnQuote_isUnavailable() public {
        pyth.setFeed(BASE, 2_000e8, 0, -8);
        pyth.setFeed(QUOTE, 1e8, 1e8 / 50, -8);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_confidenceAtTheCap_isStillAvailable() public {
        pyth.setFeed(BASE, 2_000e8, 2_000e8 / 100, -8); // exactly 1%
        pyth.setFeed(QUOTE, 1e8, 0, -8);
        (, bool ok) = oracle.referencePrice(POOL);
        assertTrue(ok);
    }

    function test_absurdExponent_isUnavailableNotOverflow() public {
        pyth.setFeed(BASE, 1e8, 0, 90);
        pyth.setFeed(QUOTE, 1e8, 0, -90);
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_noPythDeployed_isUnavailable() public {
        PythPriceOracle blind = new PythPriceOracle(IPyth(address(0)), OWNER);
        vm.prank(OWNER);
        blind.setFeeds(POOL, BASE, QUOTE);
        (, bool ok) = blind.referencePrice(POOL);
        assertFalse(ok);
    }

    /// @dev However mangled the input, the adapter returns rather than reverts. This is the
    ///      property the hook depends on: an oracle outage must not be able to halt a pool.
    function testFuzz_neverReverts(int64 base, int64 quote, uint64 conf, int32 expo) public {
        expo = int32(bound(expo, -30, 30));
        pyth.setFeed(BASE, base, conf, expo);
        pyth.setFeed(QUOTE, quote, conf, expo);
        oracle.referencePrice(POOL); // must not revert
    }

    // ── Access control ───────────────────────────────────────────────────────

    function test_setFeeds_RevertWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.setFeeds(POOL, BASE, QUOTE);
    }

    function test_clearingFeeds_disablesTheLayer() public {
        _price(2_000e8, 1e8, -8);
        vm.prank(OWNER);
        oracle.setFeeds(POOL, bytes32(0), bytes32(0));
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }
}

/// @notice The demo oracle. Trivial by design, but it decides prices in the demo, so the
///         owner gate and the availability flag are worth pinning.
contract SettablePriceOracleTest is Test {
    address constant OWNER = address(0xD1);
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(7)));

    SettablePriceOracle oracle;

    function setUp() public {
        oracle = new SettablePriceOracle(OWNER);
    }

    function test_unsetPool_isUnavailable() public view {
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_setThenRead() public {
        vm.prank(OWNER);
        oracle.setPrice(POOL, 1e18, true);
        (uint256 price, bool ok) = oracle.referencePrice(POOL);
        assertTrue(ok);
        assertEq(price, 1e18);
    }

    function test_canBeTakenOffline() public {
        vm.startPrank(OWNER);
        oracle.setPrice(POOL, 1e18, true);
        oracle.setPrice(POOL, 1e18, false);
        vm.stopPrank();
        (, bool ok) = oracle.referencePrice(POOL);
        assertFalse(ok);
    }

    function test_setPrice_RevertWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.setPrice(POOL, 1e18, true);
    }
}
