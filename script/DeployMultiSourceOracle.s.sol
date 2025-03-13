// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MultiSourceOracle} from "../src/MultiSourceOracle.sol";
import {IChainSight} from "../src/interface/IChainSight.sol";

/**
 * @dev A typical foundry script to deploy MultiSourceOracle to a testnet like Sepolia.
 *
 * Usage (example):
 *   forge script script/DeployMultiSourceOracle.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * You can also do:
 *   forge script script/DeployMultiSourceOracle.s.sol --broadcast -vvvv
 *   to see more verbose logs.
 */
contract DeployMultiSourceOracleScript is Script {
    // We can define environment variables or constants for your feeds
    // e.g. SEPOLIA addresses:
    //   - Chainlink feed for ETH/USD on Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306
    //   - Let's say Pyth is not used, or if used, some testnet address

    // Hardcoded or read from env:
    address public chainlinkFeed = vm.envOr("CHAINLINK_FEED_BTC", address(0));
    address public pythAddr = vm.envOr("PYTH_ADDRESS", address(0));
    bytes32 public pythPriceId = vm.envOr("PYTH_PRICE_ID_BTC", bytes32(0));

    // We could read an integer that indicates how many Chainsight sources we want to set in constructor.
    // For simplicity, let's do zero or one. If you have more, parse them in a loop:
    address public chainsightOracle = vm.envOr("CHAINSIGHT_ORACLE_A", address(0));
    address public chainsightSender = vm.envOr("CHAINSIGHT_SENDER_A", address(0));
    bytes32 public chainsightKey = vm.envOr("CHAINSIGHT_KEY_BTC_A", bytes32(0));

    // Deployed oracle address (after run)
    MultiSourceOracle public oracle;

    function setUp() public {
        // (Optional) any pre-setup logic
    }

    function run() public {
        // Start broadcasting with the private key
        vm.startBroadcast();

        // Prepare an array for the constructor if needed:
        MultiSourceOracle.ChainsightSource[] memory initChainsight = new MultiSourceOracle.ChainsightSource[](0);

        // If user provided a nonzero address for chainsightOracle, let's push it:
        if (chainsightOracle != address(0)) {
            initChainsight = new MultiSourceOracle.ChainsightSource[](1);
            initChainsight[0] = MultiSourceOracle.ChainsightSource({
                oracle: IChainSight(chainsightOracle),
                sender: chainsightSender,
                key: chainsightKey
            });
        }

        // Deploy with constructor
        oracle = new MultiSourceOracle(chainlinkFeed, pythAddr, pythPriceId, initChainsight);

        console2.log("MultiSourceOracle deployed at:", address(oracle));

        vm.stopBroadcast();
    }
}
