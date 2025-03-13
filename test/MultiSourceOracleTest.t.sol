// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MultiSourceOracle.sol";

/**
 * @dev Mocks
 */
contract ChainlinkMock is AggregatorV3Interface {
    uint8 private _decimals = 8;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }

    function setLatestAnswer(
        uint80 roundId,
        int256 answer,
        uint256 timestamp,
        bool answered
    ) external {
        _roundId = roundId;
        _answer = answer;
        _updatedAt = timestamp;
        _answeredInRound = answered ? roundId : roundId - 1;
    }

    function setDecimals(uint8 dec) external {
        _decimals = dec;
    }
}

contract PythMock is IPyth {
    Price private priceData;

    function setPrice(
        int64 _price,
        int32 _expo,
        uint256 _publishTime,
        bool /*_stale*/
    ) external {
        priceData = Price(_price, 0, _expo, _publishTime);
    }

    function getPriceUnsafe(
        bytes32 /*id*/
    ) external view override returns (Price memory) {
        return priceData;
    }
}

contract ChainsightMock is IChainSight {
    uint256 private _price;
    uint64 private _timestamp;

    function setPrice(uint256 price, uint64 timestamp) external {
        _price = price;
        _timestamp = timestamp;
    }

    function readAsUint256WithTimestamp(
        address /*sender*/,
        bytes32 /*key*/
    ) external view override returns (uint256, uint64) {
        return (_price, _timestamp);
    }
}

/**
 * @title MultiSourceOracleTest
 */
contract MultiSourceOracleTest is Test {
    MultiSourceOracle oracle;
    ChainlinkMock chainlink;
    PythMock pyth;
    ChainsightMock chainsight;

    address constant CHAINSIGHT_SENDER = address(0xBEEF);
    bytes32 constant PYTH_PRICE_ID = bytes32(uint256(1));
    bytes32 constant CHAINSIGHT_KEY = bytes32(uint256(2));

    uint256 constant STALE_THRESHOLD = 3600; // 1 hour
    uint256 constant LAMBDA = 1925;

    function setUp() public {
        chainlink = new ChainlinkMock();
        pyth = new PythMock();
        chainsight = new ChainsightMock();

        oracle = new MultiSourceOracle(
            address(chainlink),
            address(pyth),
            address(chainsight),
            CHAINSIGHT_SENDER,
            PYTH_PRICE_ID,
            CHAINSIGHT_KEY
        );
        // set initial config
        oracle.setStaleThreshold(STALE_THRESHOLD);
        oracle.setMaxPriceDeviationBps(2000);

        // block time
        vm.warp(1741855435);
    }

    /**
     * @notice Test that the same aggregated price is returned through
     *         Chainlink-like, Pyth-like, and Chainsight-like interfaces.
     */
    function testConsistentAggregatedPriceFromAllInterfaces() public {
        uint256 nowTs = block.timestamp;

        // Example: 80,000 (fresh)
        pyth.setPrice(80000, 0, nowTs - 10, false);
        chainlink.setDecimals(8);
        chainlink.setLatestAnswer(1, 80000 * 1e8, nowTs - 10, true);
        chainsight.setPrice(80000 * 1e8, uint64(nowTs - 10));

        // 1) Chainlink-like interface => latestRoundData
        ( , int256 answer, , , ) = oracle.latestRoundData();
        uint256 aggregatorPrice = uint256(answer);

        // 2) Pyth-like interface => getPriceUnsafe
        IPyth.Price memory pythPrice = oracle.getPriceUnsafe(PYTH_PRICE_ID);
        // pythPrice.price is int64, expo = -8 => to scale back up:
        // final = pythPrice.price * 10^(-8)
        // But in "raw integer" form, it should match aggregatorPrice
        uint256 pythAggregated = uint256(int256(pythPrice.price));

        // 3) Chainsight-like interface => readAsUint256WithTimestamp
        (uint256 csPrice, ) = oracle.readAsUint256WithTimestamp(
            CHAINSIGHT_SENDER,
            CHAINSIGHT_KEY
        );

        assertEq(aggregatorPrice, pythAggregated, "Mismatch: aggregator vs pyth");
        assertEq(aggregatorPrice, csPrice, "Mismatch: aggregator vs chainsight");
    }

    /**
     * @notice Test that an obvious outlier (Chainlink too large) is ignored.
     */
    function testOutlierDetection() public {
        uint256 nowTs = block.timestamp;

        // Let Pyth = $80,000, Chainsight = $79,900 (both fresh)
        pyth.setPrice(80000, 0, nowTs - 30, false);
        chainlink.setDecimals(8);

        chainsight.setPrice(79900 * 1e8, uint64(nowTs - 20));

        // Chainlink is an outlier: $200,000
        chainlink.setLatestAnswer(1, 200000 * 1e8, nowTs - 10, true);

        // By default, outlier detection is maxPriceDeviationBps=2000 => 20% from avg
        // The average of [80,000, 79,900] is ~79,950, 20% above that is ~95,940
        // So 200,000 is definitely outside that range => ignore Chainlink

        uint256 aggregated = _getAggregatedPriceViaOracle();
        // Weighted average of [80,000, 79,900] => ~79,950
        // They have close timestamps, so weights will be similar => final ~79,950
        // We just do a rough check:
        assertGt(aggregated, 79000 * 1e8, "Should be near 79,950 * 1e8");
        assertLt(aggregated, 80100 * 1e8, "Should be near 79,950 * 1e8");
    }

    /**
     * @notice Test the fallback logic: if all sources are stale,
     *         it should NOT revert, but return the newest stale price.
     */
    function testAllStaleButFallback() public {
        uint256 nowTs = block.timestamp;

        // All sources are stale (2 hours old)
        pyth.setPrice(80010, 0, nowTs - 2 hours, false);
        chainlink.setDecimals(8);
        chainlink.setLatestAnswer(1, 80020 * 1e8, nowTs - 130 minutes, true);
        chainsight.setPrice(80030 * 1e8, uint64(nowTs - 150 minutes));

        // Because all are stale, the aggregator should pick the newest among them
        // We have:
        //  pyth timestamp = now - 120 minutes
        //  chainlink timestamp = now - 130 minutes
        //  chainsight timestamp = now - 150 minutes
        // => the newest is pyth (2 hours = 120 minutes is the largest timestamp)
        // => aggregator should return pyth's price => 80010 * 1e8
        uint256 price = _getAggregatedPriceViaOracle();
        assertEq(price, 80010 * 1e8, "Should fallback to Pyth as the newest stale data");
    }

    // ------------------------------------------------------------------------
    // Internal helper to get aggregator price
    // ------------------------------------------------------------------------
    function _getAggregatedPriceViaOracle() internal view returns (uint256) {
        (
            ,
            int256 answer,
            ,
            ,
        ) = oracle.latestRoundData();
        return uint256(answer);
    }
}
