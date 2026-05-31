// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";

contract ReputationRegistry is IReputationRegistry, EIP712, Ownable {
    bytes32 public constant SCORE_TYPEHASH = keccak256(
        "Score(address wallet,uint16 value,uint32 nonce,uint64 deadline)"
    );

    mapping(address => Score) private _scores;
    mapping(address => bool)  private _authorizedHooks;
    mapping(address => bool)  private _authorizedAttestors;
    address public reactiveProxy;

    constructor(address _owner) EIP712("GlyphReputationRegistry", "1") Ownable(_owner) {}

    function reportToxicTrade(address wallet, address pool, uint16 localSeverity) external override {
        if (!_authorizedHooks[msg.sender]) revert Unauthorized();

        uint256 next = uint256(_scores[wallet].value) + uint256(localSeverity) / 2;
        if (next > 10_000) next = 10_000;

        _scores[wallet].value     = uint16(next);
        _scores[wallet].updatedAt = uint64(block.timestamp);

        emit ToxicTradeReported(wallet, pool, localSeverity, block.timestamp);
    }

    function updateScore(Attestation calldata attestation) external override {
        if (block.timestamp > attestation.deadline) revert ExpiredDeadline();
        if (attestation.value > 10_000) revert ScoreOutOfRange();

        address signer = ECDSA.recover(_buildDigest(attestation), attestation.signature);
        if (!_authorizedAttestors[signer]) revert InvalidSignature();

        Score storage stored = _scores[attestation.wallet];
        if (attestation.nonce != stored.nonce + 1) revert NonceTooLow();

        stored.value     = attestation.value;
        stored.updatedAt = uint64(block.timestamp);
        stored.nonce     = attestation.nonce;

        emit ScoreUpdated(attestation.wallet, attestation.value, attestation.nonce);
    }

    function updateScoreFromReactive(address wallet, uint16 aggregateScore) external override {
        if (msg.sender != reactiveProxy) revert Unauthorized();
        if (aggregateScore > 10_000) revert ScoreOutOfRange();

        Score storage stored = _scores[wallet];
        if (aggregateScore > stored.value) {
            stored.value     = aggregateScore;
            stored.updatedAt = uint64(block.timestamp);
            emit ScoreUpdated(wallet, aggregateScore, stored.nonce);
        }
    }

    function scoreOf(address wallet) external view override returns (uint16) {
        return _scores[wallet].value;
    }

    function scoreDataOf(address wallet) external view override returns (Score memory) {
        return _scores[wallet];
    }

    function isAuthorizedHook(address hook) external view override returns (bool) {
        return _authorizedHooks[hook];
    }

    function setHook(address hook, bool authorized) external onlyOwner {
        _authorizedHooks[hook] = authorized;
        emit HookAuthorized(hook, authorized);
    }

    function setAttestor(address attestor, bool authorized) external onlyOwner {
        _authorizedAttestors[attestor] = authorized;
    }

    function setReactiveProxy(address proxy) external onlyOwner {
        reactiveProxy = proxy;
    }

    function _buildDigest(Attestation calldata a) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(SCORE_TYPEHASH, a.wallet, a.value, a.nonce, a.deadline))
        );
    }
}
