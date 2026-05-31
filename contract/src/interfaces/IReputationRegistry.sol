// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IReputationRegistry {
    struct Score {
        uint16 value;
        uint64 updatedAt;
        uint32 nonce;
    }

    struct Attestation {
        address wallet;
        uint16  value;
        uint32  nonce;
        uint64  deadline;
        bytes   signature;
    }

    event ScoreUpdated(address indexed wallet, uint16 value, uint32 nonce);
    event ToxicTradeReported(address indexed wallet, address indexed pool, uint16 localSeverity, uint256 timestamp);
    event HookAuthorized(address indexed hook, bool authorized);

    error Unauthorized();
    error InvalidSignature();
    error ExpiredDeadline();
    error NonceTooLow();
    error ScoreOutOfRange();

    function reportToxicTrade(address wallet, address pool, uint16 localSeverity) external;
    function updateScore(Attestation calldata attestation) external;
    function updateScoreFromReactive(address wallet, uint16 aggregateScore) external;
    function scoreOf(address wallet) external view returns (uint16);
    function scoreDataOf(address wallet) external view returns (Score memory);
    function isAuthorizedHook(address hook) external view returns (bool);
}
