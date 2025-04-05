// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interface/IChainlink.sol";
import "./interface/IPyth.sol";
import "./interface/IChainSight.sol";

/**
 * @title MultiSourceOracle
 * @notice Aggregates prices from:
 *         - Chainlink feed (if chainlinkFeed != address(0))
 *         - Pyth feed (if pyth != address(0))
 *         - Zero or more ChainSight oracles (set in constructor or added later)
 *
 * Features:
 *  - Timestamp-weighted average price
 *  - Outlier detection (only if total sources >=3 and enabled)
 *  - Fallback if all data is stale (returns newest stale price)
 *  - Pausable by the owner (for security)
 *  - Owner can update chainlink feed, pyth feed, or chainsight sources at any time
 */
contract MultiSourceOracle is Ownable {
    // ----------------------------------------------------
    // Optional Chainlink feed
    // ----------------------------------------------------
    AggregatorV3Interface public chainlinkFeed; // if address(0), we skip chainlink

    // ----------------------------------------------------
    // Optional Pyth feed
    // ----------------------------------------------------
    IPyth public pyth; // if address(0), skip pyth
    bytes32 public pythPriceId; // only relevant if pyth != address(0)

    // ----------------------------------------------------
    // Multiple ChainSight sources
    // ----------------------------------------------------
    struct ChainSightSource {
        IChainSight oracle;
        address sender;
        bytes32 key;
        uint8 decimals;
    }

    ChainSightSource[] public chainsightSources;

    // ----------------------------------------------------
    // Configuration
    // ----------------------------------------------------
    uint256 public staleThreshold = 3600; // 1 hour
    uint256 public lambda = 1925; // weighting half-life ~1 hour
    uint256 public maxPriceDeviationBps = 2000; // ±20%

    // Outlier detection applies if:
    //   - outlierDetectionEnabled == true
    //   - total number of sources (chainlink + pyth + chainsight) >= 3
    bool public outlierDetectionEnabled = true;

    // Aggregator's final decimals setting
    //  - e.g., aggregatorDecimals=8 => unify everything to 8 decimals
    //  - e.g., aggregatorDecimals=18 => unify everything to 18 decimals
    uint8 public aggregatorDecimals = 8;

    // Can be paused in emergencies
    bool public paused = false;

    // ----------------------------------------------------
    // Constructor with optional feeds + optional chainsight sources
    // ----------------------------------------------------
    /**
     * @param _chainlinkFeed Chainlink aggregator address (0 to disable)
     * @param _pyth Pyth contract address (0 to disable)
     * @param _pythPriceId Price feed ID for Pyth
     * @param _chainsightOracles Initial ChainSight sources
     */
    constructor(
        address _chainlinkFeed,
        address _pyth,
        bytes32 _pythPriceId,
        ChainSightSource[] memory _chainsightOracles
    ) Ownable(msg.sender) {
        if (_chainlinkFeed != address(0)) {
            chainlinkFeed = AggregatorV3Interface(_chainlinkFeed);
        }
        if (_pyth != address(0)) {
            pyth = IPyth(_pyth);
            pythPriceId = _pythPriceId;
        }
        // Initialize ChainSight sources
        for (uint256 i = 0; i < _chainsightOracles.length; i++) {
            chainsightSources.push(_chainsightOracles[i]);
        }
    }

    // ----------------------------------------------------
    // Owner-only configuration
    // ----------------------------------------------------

    function setChainlinkFeed(address _feed) external onlyOwner {
        chainlinkFeed = AggregatorV3Interface(_feed);
    }

    function setPythFeed(address _pyth, bytes32 _priceId) external onlyOwner {
        pyth = IPyth(_pyth);
        pythPriceId = _priceId;
    }

    function addChainSightSource(address oracle, address sender, bytes32 key, uint8 decimals) external onlyOwner {
        ChainSightSource memory src =
            ChainSightSource({oracle: IChainSight(oracle), sender: sender, key: key, decimals: decimals});
        chainsightSources.push(src);
    }

    function clearAllChainSightSources() external onlyOwner {
        delete chainsightSources;
    }

    function setAggregatorDecimals(uint8 _decimals) external onlyOwner {
        require(_decimals <= 20, "Too large decimals");
        aggregatorDecimals = _decimals;
    }

    function setStaleThreshold(uint256 _seconds) external onlyOwner {
        staleThreshold = _seconds;
    }

    function setLambda(uint256 _lambda) external onlyOwner {
        lambda = _lambda;
    }

    function setMaxPriceDeviationBps(uint256 _bps) external onlyOwner {
        maxPriceDeviationBps = _bps;
    }

    function setOutlierDetectionEnabled(bool _enabled) external onlyOwner {
        outlierDetectionEnabled = _enabled;
    }

    // ----------------------------------------------------
    // Pausing
    // ----------------------------------------------------
    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    // ----------------------------------------------------
    // Chainlink-like interface
    // ----------------------------------------------------
    function latestRoundData()
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80)
    {
        uint256 agg = _getAggregatedPrice();
        return (0, int256(agg), block.timestamp, block.timestamp, 0);
    }

    // ----------------------------------------------------
    // Pyth-like interface
    // ----------------------------------------------------
    function getPriceUnsafe(bytes32 id) external view returns (IPyth.Price memory) {
        // If pyth is not used, this will revert anyway because pyth=address(0).
        require(address(pyth) != address(0), "No pyth");
        require(id == pythPriceId, "Invalid pyth ID");

        uint256 agg = _getAggregatedPrice();
        int256 dec = int256(uint256(aggregatorDecimals));
        int32 expo = int32(-dec); // negative exponent
        return IPyth.Price(
            int64(int256(agg)),
            0, // dummy confidence
            expo,
            block.timestamp
        );
    }

    function getPrice(bytes32 id) external view returns (IPyth.Price memory price) {
        require(address(pyth) != address(0), "No pyth");
        require(id == pythPriceId, "Invalid pyth ID");

        uint256 agg = _getAggregatedPrice();
        int256 dec = int256(uint256(aggregatorDecimals));
        int32 expo = int32(-dec);
        return IPyth.Price(
            int64(int256(agg)),
            0, // dummy confidence
            expo,
            block.timestamp
        );
    }

    // ----------------------------------------------------
    // ChainSight-like interface
    // ----------------------------------------------------
    /**
     * @notice Because this aggregator might combine many chainsight oracles,
     *         we do not strictly validate the sender/key passed in. Instead,
     *         we just return the aggregated price.
     */
    function readAsUint256WithTimestamp(
        address,
        /*sender*/
        bytes32 /*key*/
    ) external view returns (uint256, uint64) {
        uint256 agg = _getAggregatedPrice();
        return (agg, uint64(block.timestamp));
    }

    // ----------------------------------------------------
    // Internal aggregator logic
    // ----------------------------------------------------
    struct SourceData {
        uint256 price; // scaled to aggregatorDecimals
        uint256 weight; // 0 => stale or outlier
        uint256 timestamp;
    }

    function _getAggregatedPrice() internal view returns (uint256) {
        require(!paused, "Aggregator is paused");

        // 1) Collect all sources
        SourceData[] memory list = _collectAllSources();

        // 2) Count how many are fresh
        uint256 freshCount;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].weight > 0) {
                freshCount++;
            }
        }

        // 3) If none fresh => fallback newest stale
        if (freshCount == 0) {
            return _fallbackNewest(list);
        }

        // 4) If outlier detection is enabled and total sources >=3, apply it
        if (outlierDetectionEnabled && list.length >= 3) {
            _applyMedianBasedOutlierFilter(list);
        }

        // 5) Re-count how many remain
        uint256 finalCount;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].weight > 0) {
                finalCount++;
            }
        }
        if (finalCount == 0) {
            // fallback
            return _fallbackNewest(list);
        }

        // 6) Weighted average
        uint256 weightedSum;
        uint256 totalWeight;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].weight > 0) {
                weightedSum += (list[i].price * list[i].weight);
                totalWeight += list[i].weight;
            }
        }
        return weightedSum / totalWeight;
    }

    function _collectAllSources() internal view returns (SourceData[] memory) {
        // Calculate how many sources in total
        uint256 totalSources = 0;
        if (address(chainlinkFeed) != address(0)) totalSources++;
        if (address(pyth) != address(0)) totalSources++;
        totalSources += chainsightSources.length;

        SourceData[] memory list = new SourceData[](totalSources);

        uint256 idx = 0;

        // Chainlink
        if (address(chainlinkFeed) != address(0)) {
            (, int256 clAnswer,, uint256 clTime,) = chainlinkFeed.latestRoundData();
            require(clAnswer >= 0, "Chainlink negative");
            uint256 clScaled = _scaleChainlinkPrice(clAnswer, chainlinkFeed.decimals());
            uint256 clWeight = _validWeight(clTime);
            list[idx] = SourceData(clScaled, clWeight, clTime);
            idx++;
        }

        // Pyth
        if (address(pyth) != address(0)) {
            IPyth.Price memory pData = pyth.getPriceUnsafe(pythPriceId);
            require(pData.price >= 0, "Pyth negative");
            uint256 pyScaled = _scalePythPrice(pData.price, pData.expo);
            uint256 pyWeight = _validWeight(pData.publishTime);
            list[idx] = SourceData(pyScaled, pyWeight, pData.publishTime);
            idx++;
        }

        // ChainSight
        for (uint256 i = 0; i < chainsightSources.length; i++) {
            (uint256 csPrice, uint64 csTime) = chainsightSources[i].oracle.readAsUint256WithTimestamp(
                chainsightSources[i].sender, chainsightSources[i].key
            );

            // cPrice is unsigned => no negative check
            uint256 csScaled = _scaleChainSightPrice(csPrice, chainsightSources[i].decimals);
            uint256 csWeight = _validWeight(csTime);
            list[idx] = SourceData(csScaled, csWeight, csTime);
            idx++;
        }

        return list;
    }

    // ----------------------------------------------------
    // Outlier detection (median-based)
    // ----------------------------------------------------
    function _applyMedianBasedOutlierFilter(SourceData[] memory list) internal view {
        // gather fresh
        uint256 freshCount;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].weight > 0) {
                freshCount++;
            }
        }
        // if fewer than 3 fresh => skip outlier detection
        if (freshCount < 3) {
            return;
        }

        // gather fresh prices in a temp array
        uint256[] memory arr = new uint256[](freshCount);
        uint256 k;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].weight > 0) {
                arr[k] = list[i].price;
                k++;
            }
        }

        // find median
        uint256 med = _medianOf(arr);

        // apply bounding
        uint256 dev = maxPriceDeviationBps; // e.g. 2000 => ±20%
        uint256 low = (med * (10000 - dev)) / 10000;
        uint256 high = (med * (10000 + dev)) / 10000;

        // remove those outside
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].weight == 0) continue;
            uint256 p = list[i].price;
            if (p < low || p > high) {
                list[i].weight = 0;
            }
        }
    }

    function _medianOf(uint256[] memory arr) internal pure returns (uint256) {
        _quickSort(arr, int256(0), int256(arr.length - 1));
        uint256 n = arr.length;
        if (n % 2 == 1) {
            // odd
            return arr[n / 2];
        } else {
            // even
            uint256 m1 = arr[n / 2 - 1];
            uint256 m2 = arr[n / 2];
            return (m1 + m2) / 2;
        }
    }

    // simple quicksort for small arrays
    function _quickSort(uint256[] memory arr, int256 left, int256 right) internal pure {
        if (left >= right) return;
        int256 i = left;
        int256 j = right;
        uint256 pivot = arr[uint256(left + (right - left) / 2)];
        while (i <= j) {
            while (arr[uint256(i)] < pivot) i++;
            while (arr[uint256(j)] > pivot) j--;
            if (i <= j) {
                (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                i++;
                j--;
            }
        }
        if (left < j) _quickSort(arr, left, j);
        if (i < right) _quickSort(arr, i, right);
    }

    // ----------------------------------------------------
    // Fallback if all stale => pick newest
    // ----------------------------------------------------
    function _fallbackNewest(SourceData[] memory list) internal pure returns (uint256) {
        uint256 idx = 0;
        uint256 maxT = list[0].timestamp;
        for (uint256 i = 1; i < list.length; i++) {
            if (list[i].timestamp > maxT) {
                maxT = list[i].timestamp;
                idx = i;
            }
        }
        return list[idx].price;
    }

    // ----------------------------------------------------
    // Helpers
    // ----------------------------------------------------
    /**
     * @dev Scale Chainlink price to aggregatorDecimals
     */
    function _scaleChainlinkPrice(int256 _price, uint8 feedDecimals) internal view returns (uint256) {
        uint256 scaled = uint256(_price);
        if (feedDecimals < aggregatorDecimals) {
            scaled = scaled * (10 ** (aggregatorDecimals - feedDecimals));
        } else if (feedDecimals > aggregatorDecimals) {
            scaled = scaled / (10 ** (feedDecimals - aggregatorDecimals));
        }
        return scaled;
    }

    /**
     * @dev Scale Pyth price to aggregatorDecimals
     */
    function _scalePythPrice(int64 _price, int32 _expo) internal view returns (uint256) {
        int256 p = int256(_price);
        int256 aggDec = int256(uint256(aggregatorDecimals));
        int256 diff = aggDec + _expo;
        uint256 scaled;
        if (diff >= 0) {
            scaled = uint256(p) * (10 ** uint256(diff));
        } else {
            scaled = uint256(p) / (10 ** uint256(-diff));
        }
        return scaled;
    }

    /**
     * @dev Scale ChainSight price to aggregatorDecimals
     */
    function _scaleChainSightPrice(uint256 rawPrice, uint8 sourceDecimals) internal view returns (uint256) {
        if (sourceDecimals < aggregatorDecimals) {
            return rawPrice * (10 ** (aggregatorDecimals - sourceDecimals));
        } else if (sourceDecimals > aggregatorDecimals) {
            return rawPrice / (10 ** (sourceDecimals - aggregatorDecimals));
        }
        return rawPrice;
    }

    function _validWeight(uint256 ts) internal view returns (uint256) {
        if (ts == 0 || ts > block.timestamp) {
            return 0;
        }
        uint256 elapsed = block.timestamp - ts;
        if (elapsed > staleThreshold) {
            return 0;
        }
        return _expDecay(elapsed);
    }

    function _expDecay(uint256 elapsed) internal view returns (uint256) {
        // weight = 1e12 / (1e6 + lambda * elapsed)
        return 1e12 / (1e6 + lambda * elapsed);
    }
}
