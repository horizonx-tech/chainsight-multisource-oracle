// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MultiSourceOracle} from "../src/MultiSourceOracle.sol";
import {IChainSight} from "../src/interface/IChainSight.sol";

/**
 * @dev Example script to call addChainsightSource on an existing MultiSourceOracle.
 *
 * Environment variables used (you can adapt to your own style):
 * - ORACLE_ADDRESS: The deployed MultiSourceOracle address
 * - CHAINSIGHT_ORACLE: The chainsight oracle contract address
 * - CHAINSIGHT_SENDER: The 'sender' param
 * - CHAINSIGHT_KEY: The 'key' param (in bytes32)
 * forge script script/AddChainsightSource.s.sol \
 *  --rpc-url $RPC_URL \
 *  --private-key $PRIVATE_KEY \
 *  --broadcast \
 *  --chain-id $NETWORK_ID
 */
contract AddChainsightSourceScript is Script {
    function run() external {
        // 1) Load env variables (or you could hardcode them)
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address chainsightOracle = vm.envAddress("CHAINSIGHT_ORACLE_B");
        address chainsightSender = vm.envAddress("CHAINSIGHT_SENDER_B");
        bytes32 chainsightKey = vm.envBytes32("CHAINSIGHT_KEY_BTC_B");

        // 2) Start broadcasting (uses foundry's --private-key or --mnemonic flags if provided)
        vm.startBroadcast();

        // 3) Call addChainsightSource on the existing oracle
        MultiSourceOracle(oracleAddr).addChainsightSource(
            chainsightOracle,
            chainsightSender,
            chainsightKey
        );

        // 4) Optionally log the result
        console2.log("Added chainsight source to MultiSourceOracle:", oracleAddr);

        // 5) Stop broadcasting
        vm.stopBroadcast();
    }
}
