// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MultiSourceOracle.sol";

/**
 * @dev Simple Chainlink mock.
 *      Typically, Chainlink feeds for ETH/USD use 8 decimals, and the answer might be in the range
 *      of 1,500 * 1e8 => 150000000000 to 4,000 * 1e8 => 400000000000, etc.
 */
contract ChainlinkMock is AggregatorV3Interface {
    uint8 private _decimals = 8;
    int256 private _answer; // e.g. 1,920 * 1e8 => 192000000000
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

/**
 * @dev Simple Pyth mock. Typically for USD pairs, expo = -8.
 */
contract PythMock is IPyth {
    Price private storedPrice;
    uint256 public validTimePeriod = 300;

    function setPrice(
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        storedPrice = Price(_price, 0, _expo, _publishTime);
    }

    function getPrice(
        bytes32
    ) external view override returns (Price memory price) {
        if (block.timestamp > storedPrice.publishTime + validTimePeriod) {
            revert("StalePrice");
        }
        return storedPrice;
    }

    function getPriceUnsafe(
        bytes32
    ) external view override returns (Price memory) {
        return storedPrice;
    }
}

/**
 * @dev Simple Chainsight mock. Typically returns a large integer for ETH/USD, e.g. 1,922,130,00000, etc.
 */
contract ChainsightMock is IChainSight {
    uint256 private _price;
    uint64 private _ts;

    function setPrice(uint256 p, uint64 t) external {
        _price = p;
        _ts = t;
    }

    function readAsUint256WithTimestamp(
        address,
        bytes32
    ) external view override returns (uint256, uint64) {
        return (_price, _ts);
    }
}

/**
 * @title MultiSourceOracleTest
 */
contract MultiSourceOracleTest is Test {
    // Mocks
    ChainlinkMock chainlink;
    PythMock pyth;
    ChainsightMock cs1;
    ChainsightMock cs2;

    MultiSourceOracle oracle;

    // Helpers to read aggregator
    function _readOracleChainlinkStyle() internal view returns (uint256) {
        (, int256 ans, , , ) = oracle.latestRoundData();
        return uint256(ans);
    }

    function _readOraclePythSafe(
        bytes32 id
    ) internal view returns (IPyth.Price memory) {
        return oracle.getPrice(id);
    }

    function _readOraclePythUnsafe(
        bytes32 id
    ) internal view returns (IPyth.Price memory) {
        return oracle.getPriceUnsafe(id);
    }

    function _readOracleChainsightStyle()
        internal
        view
        returns (uint256, uint64)
    {
        return oracle.readAsUint256WithTimestamp(address(0), bytes32(0));
    }

    function setUp() public {
        // Deploy mock oracles
        chainlink = new ChainlinkMock();
        chainlink.setDecimals(8);

        pyth = new PythMock();
        cs1 = new ChainsightMock();
        cs2 = new ChainsightMock();

        // Prepare initial Chainsight array [cs1 only]
        MultiSourceOracle.ChainsightSource[]
            memory initCs = new MultiSourceOracle.ChainsightSource[](1);
        initCs[0] = MultiSourceOracle.ChainsightSource({
            oracle: IChainSight(address(cs1)),
            sender: address(this),
            key: bytes32("cs1")
        });

        // Deploy aggregator with chainlink + pyth + cs1
        oracle = new MultiSourceOracle(
            address(chainlink),
            address(pyth),
            bytes32("TestPrice"),
            initCs
        );

        // fix time
        vm.warp(1700000000);
    }

    // ----------------------------------------------------
    // Single Provider Tests
    // ----------------------------------------------------

    /**
     * @notice Only Chainlink => aggregator must match chainlink's scaled data
     *
     * Let's set chainlink to e.g. 1,920.13 => 192013000000 in 8 decimals
     */
    function test_SingleProvider_Chainlink() public {
        // disable pyth + chainsight
        oracle.setPythFeed(address(0), bytes32(0));
        oracle.clearAllChainsightSources();

        // chainlink => 1,920.13 * 1e8 => 192013000000
        chainlink.setLatestAnswer(int256(192013000000), block.timestamp);

        uint256 agg = _readOracleChainlinkStyle();
        // Expect aggregator == chainlink
        assertEq(agg, 192013000000, "Chainlink-only aggregator mismatch");

        // pyth-like getPrice => revert with "No pyth"
        vm.expectRevert("No pyth");
        oracle.getPrice(bytes32("TestPrice"));
    }

    /**
     * @notice Only Pyth => aggregator must match Pyth's scaled data
     *         If we store e.g. price=192671999500, expo=-8 => aggregator sees ~ 192671999500
     *         Because aggregator will call _scalePythPrice with expo=-8 => no further scaling => aggregator = 192671999500
     */
    function test_SingleProvider_Pyth() public {
        // disable chainlink
        oracle.setChainlinkFeed(address(0));
        // disable chainsight
        oracle.clearAllChainsightSources();

        // Suppose we set Pyth => price=192671999500, expo=-8 => actual ~ 1926.71999500
        pyth.setPrice(
            int64(192671999500), // caution: int64 can hold up to ~9.22e18; be mindful of overflow
            -8,
            block.timestamp
        );

        // aggregator => chainlink-like => expects 192671999500
        uint256 chainlinkStyle = _readOracleChainlinkStyle();
        assertEq(
            chainlinkStyle,
            192671999500,
            "Pyth-only aggregator mismatch (chainlink-like interface)"
        );

        // aggregator => pyth-like => same
        IPyth.Price memory pData = _readOraclePythSafe(bytes32("TestPrice"));
        assertEq(int256(pData.price), 192671999500, "Pyth aggregator mismatch");
        assertEq(pData.expo, -8, "Should reflect aggregator's -8 exponent");
    }

    /**
     * @notice Only Chainsight => aggregator must match the single Chainsight's returned price
     *         Example: 1,922.13 => 192213000000
     */
    function test_SingleProvider_Chainsight() public {
        // disable chainlink + pyth
        oracle.setChainlinkFeed(address(0));
        oracle.setPythFeed(address(0), bytes32(0));

        // Chainsight => e.g. 1,922.13 => 192213000000 for 8 decimals
        cs1.setPrice(192213000000, uint64(block.timestamp));

        uint256 chainlinkStyle = _readOracleChainlinkStyle();
        assertEq(
            chainlinkStyle,
            192213000000,
            "Chainsight-only aggregator mismatch"
        );
    }

    /**
     * @notice No chainlink, no pyth, 2 or more chainsight sources => aggregator uses those only.
     */
    function test_MultipleChainsightOnly() public {
        // disable chainlink + pyth
        oracle.setChainlinkFeed(address(0));
        oracle.setPythFeed(address(0), bytes32(0));
        // remove cs1 from constructor
        oracle.clearAllChainsightSources();

        // Add 2 chainsight oracles
        oracle.addChainsightSource(address(cs1), address(this), bytes32("cs1"));
        oracle.addChainsightSource(address(cs2), address(this), bytes32("cs2"));

        // e.g. cs1 => 1,900.00 => 190000000000
        cs1.setPrice(190000000000, uint64(block.timestamp - 5));
        // cs2 => 1,950.00 => 195000000000
        cs2.setPrice(195000000000, uint64(block.timestamp - 10));

        // aggregator => ~1,925 or so, weighted by time decay
        uint256 cStyle = _readOracleChainlinkStyle();
        assertGt(cStyle, 189999999999);
        assertLt(cStyle, 196000000001);

        // can't read pyth => revert
        vm.expectRevert("No pyth");
        oracle.getPrice(bytes32("TestPrice"));
    }

    // ----------------------------------------------------
    // Double Provider Tests
    // ----------------------------------------------------

    /**
     * @notice aggregator has chainlink + 2 chainsight => 3 total => outlier detection possible
     *         Confirm aggregator is consistent across chainlink-like, chainsight-like
     */
    function test_ChainlinkAnd2Chainsight() public {
        // disable pyth
        oracle.setPythFeed(address(0), bytes32(0));

        // clear existing cs1 => re-add multiple
        oracle.clearAllChainsightSources();
        oracle.addChainsightSource(address(cs1), address(this), bytes32("cs1"));
        oracle.addChainsightSource(address(cs2), address(this), bytes32("cs2"));

        // chainlink => e.g. 1,800 => 180000000000
        chainlink.setLatestAnswer(int256(180000000000), block.timestamp - 3);

        // cs1 => 1,850 => 185000000000
        cs1.setPrice(185000000000, uint64(block.timestamp - 6));
        // cs2 => 2,000 => 200000000000
        cs2.setPrice(200000000000, uint64(block.timestamp - 4));

        // aggregator => chainlink-like read
        uint256 cStyle = _readOracleChainlinkStyle();
        // Should be ~ >185e9 if cs2 is not outlier, or ~190 if weighting. Outlier detection might exclude 2e11
        // We can just check it's above 180e9 and below 210e9
        assertGt(cStyle, 180000000000, "Expected aggregator >1,800");
        assertLt(cStyle, 210000000000, "Expected aggregator <2,100");

        // pyth => revert
        vm.expectRevert("No pyth");
        oracle.getPrice(bytes32("TestPrice"));

        // aggregator => chainsight-like read
        (uint256 csVal, ) = _readOracleChainsightStyle();
        assertEq(cStyle, csVal, "Chainlink-like vs chainsight-like mismatch");
    }

    /**
     * @notice aggregator with pyth + 2 chainsight => 3 total => outlier detection possible
     *         Confirm aggregator is consistent across chainlink-like, pyth-like, chainsight-like
     */
    function test_PythAnd2Chainsight() public {
        // disable chainlink
        oracle.setChainlinkFeed(address(0));

        // clear existing cs1 => re-add multiple
        oracle.clearAllChainsightSources();
        oracle.addChainsightSource(address(cs1), address(this), bytes32("cs1"));
        oracle.addChainsightSource(address(cs2), address(this), bytes32("cs2"));

        // pyth => 1,840 => 184000000000 (expo=-8)
        pyth.setPrice(184000000000, -8, block.timestamp - 3);

        // cs1 => 1,830 => 183000000000
        cs1.setPrice(183000000000, uint64(block.timestamp - 5));
        // cs2 => 1,900 => 190000000000
        cs2.setPrice(190000000000, uint64(block.timestamp - 4));

        // aggregator => chainlink-like read
        uint256 aggregatorVal = _readOracleChainlinkStyle();

        // aggregator => pyth-like
        IPyth.Price memory pSafe = _readOraclePythSafe(bytes32("TestPrice"));
        IPyth.Price memory pUnsafe = _readOraclePythUnsafe(bytes32("TestPrice"));

        // aggregator => chainsight-like
        (uint256 csVal, ) = _readOracleChainsightStyle();

        // all should match
        assertEq(
            aggregatorVal,
            uint256(int256(pSafe.price)),
            "Mismatch aggregator vs Pyth.getPrice"
        );
        assertEq(
            aggregatorVal,
            uint256(int256(pUnsafe.price)),
            "Mismatch aggregator vs Pyth.getPriceUnsafe"
        );
        assertEq(
            aggregatorVal,
            csVal,
            "Mismatch aggregator vs chainsight-like read"
        );
    }

    /**
     * @notice aggregator with chainlink + pyth + 2 or 3 Chainsight => large combination
     *         We can confirm cross-interface consistency, outlier detection, etc.
     */
    function test_ChainlinkPythAnd2Chainsight() public {
        // We already have chainlink + pyth + cs1 from setUp. Let's add cs2
        oracle.addChainsightSource(address(cs2), address(this), bytes32("cs2"));

        // chainlink => ~1,840 => 184000000000
        chainlink.setLatestAnswer(int256(184000000000), block.timestamp - 10);

        // pyth => ~1,850 => 185000000000, expo=-8
        pyth.setPrice(185000000000, -8, block.timestamp - 8);

        // cs1 => ~1,820 => 182000000000
        cs1.setPrice(182000000000, uint64(block.timestamp - 7));

        // cs2 => big outlier => ~2,300 => 230000000000
        cs2.setPrice(230000000000, uint64(block.timestamp - 3));

        // aggregator => if outlier detection is on, likely excludes 2,300 => final ~1,830–1,850
        // read aggregator chainlink-like
        uint256 aggregatorVal = _readOracleChainlinkStyle();

        // read aggregator pyth-like
        IPyth.Price memory pSafe = oracle.getPrice(bytes32("TestPrice"));
        IPyth.Price memory pUnsafe = oracle.getPriceUnsafe(bytes32("TestPrice"));

        // read aggregator chainsight-like
        (uint256 csVal, ) = oracle.readAsUint256WithTimestamp(address(0), bytes32(0));

        // cross-check all
        assertEq(aggregatorVal, csVal, "Mismatch aggregator vs chainsight-like");
        assertEq(aggregatorVal, uint256(int256(pSafe.price)), "Aggregator vs pSafe");
        assertEq(aggregatorVal, uint256(int256(pUnsafe.price)), "Aggregator vs pUnsafe");
    }

    /**
     * @notice Consistency across chainlink-like, pyth-like, and chainsight-like
     */
    function test_ConsistencyAcrossAllInterfaces() public {
        // chainlink => 1,839.166 => 183916600000
        chainlink.setLatestAnswer(int256(183916600000), block.timestamp - 3);

        // pyth => 1,926.72 => 192672000000, expo=-8
        pyth.setPrice(192672000000, -8, block.timestamp - 2);

        // cs1 => 1,922.13 => 192213000000
        cs1.setPrice(192213000000, uint64(block.timestamp - 1));

        // aggregator => Weighted average among (183916600000, 192672000000, 192213000000)
        uint256 chainlinkStyle = _readOracleChainlinkStyle();

        IPyth.Price memory pSafe = _readOraclePythSafe(bytes32("TestPrice"));
        IPyth.Price memory pUnsafe = _readOraclePythUnsafe(
            bytes32("TestPrice")
        );
        (uint256 csVal, ) = _readOracleChainsightStyle();

        assertEq(
            chainlinkStyle,
            uint256(int256(pSafe.price)),
            "Mismatch aggregator vs Pyth.getPrice"
        );
        assertEq(
            chainlinkStyle,
            uint256(int256(pUnsafe.price)),
            "Mismatch aggregator vs Pyth.getPriceUnsafe"
        );
        assertEq(
            chainlinkStyle,
            csVal,
            "Mismatch aggregator vs Chainsight read"
        );

        // aggregator sets pSafe.publishTime = block.timestamp
        // aggregator sets pUnsafe.publishTime= block.timestamp as well
        // just confirm they match
        assertEq(
            uint256(pSafe.publishTime),
            uint256(pUnsafe.publishTime),
            "Expected pyth safe/unsafe timestamps match"
        );
    }

    // ----------------------------------------------------
    // Outlier, Stale, and Pausing Tests
    // ----------------------------------------------------

    /**
     * @notice Test aggregator with chainlink + pyth + 1 chainsight => total 3 => outlier detection can apply.
     *         We set a REALLY large outlier so it's excluded by ±20% band.
     */
    function test_OutlierDetection() public {
        // chainlink => ~183.9166
        chainlink.setLatestAnswer(int256(183916600000), block.timestamp - 10);

        // pyth => ~183.9000
        pyth.setPrice(183900000000, -8, block.timestamp - 15);

        // cs1 => big outlier => 240,000,000,000 (definitely >120% of ~184e9 => excluded)
        cs1.setPrice(240000000000, uint64(block.timestamp - 5));

        // aggregator => exclude 240e9 => result near average(183916600000, 183900000000) => ~1839
        uint256 agg = _readOracleChainlinkStyle();

        // Just check bounds => want it between e.g. 180e9 and 185e9
        assertGt(agg, 180000000000, "Expect aggregator >1,800");
        assertLt(agg, 185000000000, "Expect aggregator <1,850");
    }

    /**
     * @notice If we disable outlier detection, the outlier is included => result is huge.
     */
    function test_OutlierOff() public {
        oracle.setOutlierDetectionEnabled(false);

        // same data as above
        chainlink.setLatestAnswer(int256(183916600000), block.timestamp - 10);
        pyth.setPrice(183900000000, -8, block.timestamp - 15);

        // outlier => 240,000,000,000
        cs1.setPrice(240000000000, uint64(block.timestamp - 5));

        // aggregator => includes 240e9 => final should exceed 190e9
        uint256 agg = _readOracleChainlinkStyle();
        // e.g. average(183.9166 +183.9 +240)= ~202, we want >190
        assertGt(agg, 190000000000, "Should be huge if no outlier detection");
    }

    function test_AllStaleFallback() public {
        chainlink.setLatestAnswer(int256(183916600000), block.timestamp - 7200);
        pyth.setPrice(183900000000, -8, block.timestamp - 7300);
        cs1.setPrice(183950000000, uint64(block.timestamp - 7400));

        // All stale => fallback to newest => chainlink
        uint256 agg = _readOracleChainlinkStyle();
        assertEq(
            agg,
            183916600000,
            "Should fallback to chainlink as newest stale"
        );
    }

    function test_PauseUnpause() public {
        oracle.pause();
        vm.expectRevert("Aggregator is paused");
        _readOracleChainlinkStyle();

        oracle.unpause();
        chainlink.setLatestAnswer(int256(192213000000), block.timestamp);
        uint256 agg = _readOracleChainlinkStyle();
        assertEq(agg, 192213000000);
    }

    function test_SetChainlinkFeed() public {
        chainlink.setLatestAnswer(int256(183916600000), block.timestamp);
        uint256 agg1 = _readOracleChainlinkStyle();
        assertEq(agg1, 183916600000);

        ChainlinkMock chainlink2 = new ChainlinkMock();
        chainlink2.setLatestAnswer(int256(192213000000), block.timestamp);
        chainlink2.setDecimals(8);

        oracle.setChainlinkFeed(address(chainlink2));
        uint256 agg2 = _readOracleChainlinkStyle();
        assertEq(agg2, 192213000000);
    }

    function test_SetPythFeed() public {
        // start => pyth=183900000000
        pyth.setPrice(183900000000, -8, block.timestamp);
        uint256 agg1 = _readOracleChainlinkStyle();
        assertEq(agg1, 183900000000);

        // new pyth => 192213000000
        PythMock pyth2 = new PythMock();
        pyth2.setPrice(192213000000, -8, block.timestamp);

        oracle.setPythFeed(address(pyth2), bytes32("NewPriceId"));
        uint256 agg2 = _readOracleChainlinkStyle();
        assertEq(agg2, 192213000000);
    }

    function test_GetPrice() public {
        // chainlink => 1839.166 => 183916600000
        chainlink.setLatestAnswer(int256(183916600000), block.timestamp);

        // pyth => 1,926.72 => 192672000000, expo=-8
        pyth.setPrice(192672000000, -8, block.timestamp);

        // cs1 => 1,922.13 => 192213000000
        cs1.setPrice(192213000000, uint64(block.timestamp));

        // aggregator => ~1,929 or so
        IPyth.Price memory unsafePrice = oracle.getPriceUnsafe(
            bytes32("TestPrice")
        );
        IPyth.Price memory safePrice = oracle.getPrice(bytes32("TestPrice"));

        // aggregator doesn't revert if stale in this code => both calls match
        assertEq(
            unsafePrice.price,
            safePrice.price,
            "Should match aggregator price"
        );
        assertEq(
            unsafePrice.publishTime,
            safePrice.publishTime,
            "Publish time should match"
        );
        assertEq(unsafePrice.expo, safePrice.expo, "Exponent should match");
        assertEq(unsafePrice.conf, safePrice.conf, "Confidence should match");
    }
}
