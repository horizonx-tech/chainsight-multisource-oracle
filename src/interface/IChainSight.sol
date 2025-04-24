// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.20;

interface IChainSight {
    function readAsUint256WithTimestamp(address sender, bytes32 key) external view returns (uint256, uint64);
}
