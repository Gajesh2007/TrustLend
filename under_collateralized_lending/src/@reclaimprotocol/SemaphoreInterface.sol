// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface SemaphoreInterface {
    function createGroup(
        uint256 groupId,
        uint256 merkleTreeDepth,
        address admin
    ) external;

    function addMember(uint256 groupId, uint256 identityCommitment) external;

    function verifyProof(
        uint256 groupId,
        uint256 merkleTreeRoot,
        uint256 signal,
        uint256 nullifierHash,
        uint256 externalNullifier,
        uint256[8] calldata proof
    ) external;

    function removeMember(
        uint256 groupId,
        uint256 identityCommitment,
        uint256[] calldata proofSiblings,
        uint8[] calldata proofPathIndices
    ) external;
}
