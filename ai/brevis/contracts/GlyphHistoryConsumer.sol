// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal slice of the Brevis `BrevisApp` base. The production build
/// imports the real one from `brevis-network/brevis-contracts`
/// (`sdk/apps/framework/BrevisApp.sol`); it is inlined here so this consumer
/// compiles and tests standalone in the scaffold. The external surface
/// (`brevisCallback` / `handleProofResult`) is identical, so swapping the import
/// is a one-line change.
abstract contract BrevisAppBase {
    address public brevisRequest;

    error NotBrevisRequest();

    constructor(address _brevisRequest) {
        brevisRequest = _brevisRequest;
    }

    modifier onlyBrevisRequest() {
        if (msg.sender != brevisRequest) revert NotBrevisRequest();
        _;
    }

    /// @dev Brevis relays a verified proof here after the network checks it.
    function brevisCallback(bytes32 _appVkHash, bytes calldata _appCircuitOutput)
        external
        onlyBrevisRequest
    {
        handleProofResult(_appVkHash, _appCircuitOutput);
    }

    function handleProofResult(bytes32 _appVkHash, bytes calldata _appCircuitOutput)
        internal
        virtual;
}

/// @title GlyphHistoryConsumer
/// @notice On-chain sink for the Glyph Brevis history circuit. The circuit proves
/// the clamped sum of a wallet's past `ToxicTradeReported.localSeverity`; the Brevis
/// network verifies that proof and calls `brevisCallback`, which records a trustless,
/// replay-proof `histToxScore[wallet]`. The off-chain detector (`ai/detector/brevis.py`)
/// reads it as the `hist_tox_score_7d` feature, so a malicious attestor cannot fake a
/// wallet's history.
///
/// Circuit output layout (see app_circuit.go `OutputAddress` then `OutputUint(248,...)`):
///   bytes[ 0..20) = wallet address (20 bytes)
///   bytes[20..51) = uint248 score, big-endian (low 16 bits = histToxScore, <= MAX_SCORE)
contract GlyphHistoryConsumer is BrevisAppBase {
    /// @notice Mirror of ReputationRegistry.MAX_SCORE — proven scores never exceed this.
    uint16 public constant MAX_SCORE = 10_000;

    address public owner;

    /// @notice The verifying-key hash of the *approved* Glyph history circuit. Only proofs
    /// produced by this exact circuit are accepted; set once after the circuit is compiled.
    bytes32 public vkHash;

    /// @notice ZK-proven historical toxicity per wallet, in basis points [0, MAX_SCORE].
    mapping(address => uint16) public histToxScore;
    /// @notice Block timestamp of the latest accepted proof; 0 means "never proven".
    mapping(address => uint64) public provenAt;

    event VkHashSet(bytes32 indexed vkHash);
    event HistoryProven(address indexed wallet, uint16 score, uint64 provenAt);

    error NotOwner();
    error UnknownVk(bytes32 got);
    error BadOutputLength(uint256 len);
    error ScoreTooHigh(uint16 score);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _brevisRequest) BrevisAppBase(_brevisRequest) {
        owner = msg.sender;
    }

    /// @notice Pin the approved circuit's verifying-key hash. Callable by the owner;
    /// re-callable to rotate to a recompiled circuit.
    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
        emit VkHashSet(_vkHash);
    }

    function transferOwnership(address _owner) external onlyOwner {
        owner = _owner;
    }

    /// @inheritdoc BrevisAppBase
    function handleProofResult(bytes32 _appVkHash, bytes calldata _appCircuitOutput)
        internal
        override
    {
        if (_appVkHash != vkHash) revert UnknownVk(_appVkHash);
        if (_appCircuitOutput.length != 51) revert BadOutputLength(_appCircuitOutput.length);

        address wallet = address(bytes20(_appCircuitOutput[0:20]));
        // The uint248 occupies bytes[20..51); its low 16 bits hold the clamped score.
        uint16 score = uint16(bytes2(_appCircuitOutput[49:51]));
        if (score > MAX_SCORE) revert ScoreTooHigh(score);

        histToxScore[wallet] = score;
        provenAt[wallet] = uint64(block.timestamp);
        emit HistoryProven(wallet, score, uint64(block.timestamp));
    }
}
