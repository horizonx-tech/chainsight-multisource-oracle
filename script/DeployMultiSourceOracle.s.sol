// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MultiSourceOracle} from "../src/MultiSourceOracle.sol";
import {IChainSight} from "../src/interface/IChainSight.sol";

/**
 * @dev Deploy script for MultiSourceOracle on Base mainnet (chainId=8453).
 * Usage:
 *  forge script script/DeployMultiSourceOracle.s.sol \
 *    --rpc-url $RPC_URL \
 *    --private-key $PRIVATE_KEY \
 *    --broadcast \
 *    --chain-id $NETWORK_ID \
 *    --verify \
 *    --verifier etherscan \
 *    --etherscan-api-key $BASESCAN_API_KEY
 */
contract DeployMultiSourceOracleScript is Script {
    // Hardcoded or read from env:
    address public chainlinkFeed = vm.envOr("CHAINLINK_FEED_BTC", address(0));
    address public pythAddr = vm.envOr("PYTH_ADDRESS", address(0));
    bytes32 public pythPriceId = vm.envOr("PYTH_PRICE_ID_BTC", bytes32(0));

    address public chainsightOracle = vm.envOr("CHAINSIGHT_ORACLE_A", address(0));
    address public chainsightSender = vm.envOr("CHAINSIGHT_SENDER_A", address(0));
    bytes32 public chainsightKey = vm.envOr("CHAINSIGHT_KEY_BTC_A", bytes32(0));

    MultiSourceOracle public oracle;

    function setUp() public {
        // Optional pre-setup logic here.
    }

    function run() public {
        vm.startBroadcast();

        // Prepare an array for constructor
        MultiSourceOracle.ChainSightSource[] memory initChainSight = new MultiSourceOracle.ChainSightSource[](0);

        // If user provided a nonzero address for chainsightOracle, let's push it:
        if (chainsightOracle != address(0)) {
            initChainSight = new MultiSourceOracle.ChainSightSource[](1);
            initChainSight[0] = MultiSourceOracle.ChainSightSource({
                oracle: IChainSight(chainsightOracle),
                sender: chainsightSender,
                key: chainsightKey,
                decimals: 8
            });
        }

        // Deploy
        oracle = new MultiSourceOracle(chainlinkFeed, pythAddr, pythPriceId, initChainSight);

        console2.log("MultiSourceOracle deployed at:", address(oracle));

        vm.stopBroadcast();
    }
}
