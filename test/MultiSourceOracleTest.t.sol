// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MultiSourceOracle.sol";

/**
 * @dev Simple mocks
 */
contract ChainlinkMock is AggregatorV3Interface {
    uint8 private _decimals = 8;
    int256 private _answer;
    uint256 private _updatedAt;

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, _answer, 0, _updatedAt, 0);
    }

    function setLatestAnswer(int256 ans, uint256 ts) external {
        _answer = ans;
        _updatedAt = ts;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }
}

contract PythMock is IPyth {
    Price private storedPrice;

    function setPrice(int64 _price, int32 _expo, uint256 _publishTime) external {
        storedPrice = Price(_price, 0, _expo, _publishTime);
    }

    function getPriceUnsafe(bytes32)
        external
        view
        override
        returns (Price memory)
    {
        return storedPrice;
    }
}

contract ChainsightMock is IChainSight {
    uint256 private _price;
    uint64 private _ts;

    function setPrice(uint256 p, uint64 t) external {
        _price = p;
        _ts = t;
    }

    function readAsUint256WithTimestamp(address, bytes32)
        external
        view
        override
        returns (uint256, uint64)
    {
        return (_price, _ts);
    }
}

/**
 * @title MultiSourceOracleTest
 * @notice Demonstrates the refined aggregator:
 *    - Deploy with or without chainlink, pyth, chainsight
 *    - Update chainlink or pyth after deployment
 *    - Add/clear chainsight sources
 *    - Outlier detection
 *    - Fallback if all stale
 *    - Pausing
 */
contract MultiSourceOracleTest is Test {
    // Mocks
    ChainlinkMock chainlink;
    PythMock pyth;
    ChainsightMock cs1;
    ChainsightMock cs2;

    MultiSourceOracle oracle;

    function setUp() public {
        chainlink = new ChainlinkMock();
        chainlink.setDecimals(8);
        pyth = new PythMock();
        cs1 = new ChainsightMock();
        cs2 = new ChainsightMock();

        // Example: Deploy with an **initial** chainsight array of length=1
        MultiSourceOracle.ChainsightSource[] memory initCs = new MultiSourceOracle.ChainsightSource[](1);
        initCs[0] = MultiSourceOracle.ChainsightSource({
            oracle: IChainSight(address(cs1)),
            sender: address(this),
            key: bytes32("cs1")
        });

        // constructor(address chainlinkFeed, address pyth, bytes32 pythPriceId, ChainsightSource[] memory)
        oracle = new MultiSourceOracle(
            address(chainlink),
            address(pyth),
            bytes32("TestPrice"),
            initCs
        );

        vm.warp(1700000000); // set block.timestamp
    }

    function _readOracle() internal view returns (uint256) {
        // call chainlink-like interface
        (, int256 ans, , , ) = oracle.latestRoundData();
        return uint256(ans);
    }

    /**
     * @notice Test aggregator with chainlink + pyth + 1 chainsight => total 3 => outlier detection can apply.
     */
    function test_OutlierDetection() public {
        // chainlink ~ 80,000
        chainlink.setLatestAnswer(int256(80000 * 1e8), block.timestamp - 10);

        // pyth ~ 79,900
        pyth.setPrice(79900, 0, block.timestamp - 15);

        // cs1 => big outlier: 200,000
        cs1.setPrice(200000 * 1e8, uint64(block.timestamp - 5));

        // total sources=3 => outlier detection => exclude the 200k
        uint256 agg = _readOracle();
        // should be near 79,950
        assertGt(agg, 79000 * 1e8, "Expect ~79,950 or so");
        assertLt(agg, 80500 * 1e8, "Expect ~79,950 or so");
    }

    /**
     * @notice If we disable outlier detection, the outlier is included => result is huge.
     */
    function test_OutlierOff() public {
        oracle.setOutlierDetectionEnabled(false);

        chainlink.setLatestAnswer(int256(80000 * 1e8), block.timestamp - 10);
        pyth.setPrice(79900, 0, block.timestamp - 15);

        // cs1 => big outlier
        cs1.setPrice(200000 * 1e8, uint64(block.timestamp - 5));

        // no outlier detection => aggregated ~120k
        uint256 agg = _readOracle();
        assertGt(agg, 100000 * 1e8, "Should be huge if no outlier detection");
    }

    /**
     * @notice If total sources <3, outlier detection is skipped anyway.
     *         Let's pretend we have only chainlink + pyth disabled + no chainsight => total=1 => no outlier detection.
     */
    function test_OnlyChainlink() public {
        // We'll set pyth=address(0) so it's not used
        oracle.setPythFeed(address(0), bytes32(0));
        // We'll also clear chainsight
        oracle.clearAllChainsightSources();

        // Now only chainlink is used => total=1 => no outlier detection
        chainlink.setLatestAnswer(int256(100000 * 1e8), block.timestamp);
        uint256 agg = _readOracle();
        assertEq(agg, 100000 * 1e8, "Single chainlink source");
    }

    /**
     * @notice Test that we can add a new chainsight source after deployment.
     */
    function test_AddSecondChainsight() public {
        // chainlink => ~50,000
        chainlink.setLatestAnswer(int256(50000 * 1e8), block.timestamp - 10);
        // pyth => ~49,900
        pyth.setPrice(49900, 0, block.timestamp - 12);

        // cs1 => ~49,800
        cs1.setPrice(49800 * 1e8, uint64(block.timestamp - 8));

        // aggregator => ~49,900-ish
        uint256 baseAgg = _readOracle();
        assertGt(baseAgg, 49000 * 1e8);
        assertLt(baseAgg, 51000 * 1e8);

        // Now add second chainsight => e.g. 50,500 => 5s old
        oracle.addChainsightSource(address(cs2), address(this), bytes32("cs2"));
        cs2.setPrice(50500 * 1e8, uint64(block.timestamp - 5));

        // Now total=4 => outlier detection still possible. Let's see final.
        uint256 newAgg = _readOracle();
        // Weighted average among 4 near [49,800..50,500], all fresh => ~49, something
        // Just check it's in a reasonable range
        assertGt(newAgg, 49000 * 1e8);
        assertLt(newAgg, 51000 * 1e8);
    }

    /**
     * @notice Demonstrates fallback logic if all are stale => picks newest stale.
     */
    function test_AllStaleFallback() public {
        // chainlink => 2 hours old
        chainlink.setLatestAnswer(int256(40000 * 1e8), block.timestamp - 7200);
        pyth.setPrice(41000, 0, block.timestamp - 7500);
        cs1.setPrice(42000 * 1e8, uint64(block.timestamp - 7400));

        // All stale => aggregator should fallback to newest (which is chainlink at -7200 vs pyth -7500 vs cs1 -7400)
        uint256 agg = _readOracle();
        assertEq(agg, 40000 * 1e8, "Should fallback to chainlink as newest stale");
    }

    /**
     * @notice Demonstrates the pause/unpause feature.
     */
    function test_PauseUnpause() public {
        // pause
        oracle.pause();
        vm.expectRevert("Aggregator is paused");
        _readOracle();

        // unpause
        oracle.unpause();

        chainlink.setLatestAnswer(int256(12345 * 1e8), block.timestamp);
        uint256 agg = _readOracle();
        assertEq(agg, 12345 * 1e8, "Should read normally after unpause");
    }

    /**
     * @notice Demonstrates updating chainlink feed to a new address post-deployment.
     */
    function test_SetChainlinkFeed() public {
        // Start with old chainlink => 80k
        chainlink.setLatestAnswer(int256(80000 * 1e8), block.timestamp);
        uint256 agg1 = _readOracle();
        assertEq(agg1, 80000 * 1e8);

        // Deploy new chainlink mock
        ChainlinkMock chainlink2 = new ChainlinkMock();
        chainlink2.setLatestAnswer(int256(100000 * 1e8), block.timestamp);
        chainlink2.setDecimals(8);

        // Update aggregator
        oracle.setChainlinkFeed(address(chainlink2));

        // aggregator now uses new chainlink => 100k
        uint256 agg2 = _readOracle();
        assertEq(agg2, 100000 * 1e8, "Should read new chainlink feed");
    }

    /**
     * @notice Demonstrates updating pyth feed post-deployment.
     */
    function test_SetPythFeed() public {
        pyth.setPrice(50000, 0, block.timestamp);
        uint256 agg1 = _readOracle();
        assertEq(agg1, 50000 * 1e8, "Starting pyth=50k");

        // Deploy new pyth
        PythMock pyth2 = new PythMock();
        pyth2.setPrice(60000, 0, block.timestamp);

        // Update aggregator
        oracle.setPythFeed(address(pyth2), bytes32("NewPriceId"));

        uint256 agg2 = _readOracle();
        assertEq(agg2, 60000 * 1e8, "Should read new pyth feed");
    }
}
