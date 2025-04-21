// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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
    uint256 constant INT64_MAX = uint256(uint64(type(int64).max));

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

    // Allow to the newest stale price when all sources are stale
    bool public allowStaleFallback = false;

    // ChainSight source (sender x key)
    mapping(bytes32 => bool) public csSourceExists;

    /// @notice Emitted when the Chainlink aggregator address is updated.
    event ChainlinkFeedUpdated(address indexed newFeed);

    /// @notice Emitted when the Pyth contract address or its price‑id is updated.
    event PythFeedUpdated(address indexed newPyth, bytes32 indexed priceId);

    /// @notice Emitted when a new ChainSight source is accepted
    event ChainSightSourceAdded(address indexed oracle, address indexed sender, bytes32 indexed key, uint8 decimals);

    /// @notice Emitted once when all ChainSight sources are cleared
    event AllChainSightSourcesCleared();

    /// @notice Emitted when the target output decimals are changed.
    event AggregatorDecimalsUpdated(uint8 newDecimals);

    /// @notice Emitted when the “stale threshold” (seconds) is changed.
    event StaleThresholdUpdated(uint256 newThreshold);

    /// @notice Emitted when the owner toggles stale-price fallback
    event AllowStaleFallbackSet(bool allowed);

    /// @notice Emitted when the exponential‑decay λ parameter is changed.
    event LambdaUpdated(uint256 newLambda);

    /// @notice Emitted when the ±maxPriceDeviationBps band is changed.
    event MaxPriceDeviationUpdated(uint256 newDeviationBps);

    /// @notice Emitted when outlier detection is enabled or disabled.
    event OutlierDetectionEnabledSet(bool enabled);

    /// @notice Emitted when the oracle is paused.
    event Paused();

    /// @notice Emitted when the oracle is unpaused.
    event Unpaused();

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
            bytes32 h = _sourceHash(_chainsightOracles[i].sender, _chainsightOracles[i].key);
            require(!csSourceExists[h], "MSO-1: duplicate ChainSight source");
            csSourceExists[h] = true;
            chainsightSources.push(_chainsightOracles[i]);
            emit ChainSightSourceAdded(
                address(_chainsightOracles[i].oracle),
                _chainsightOracles[i].sender,
                _chainsightOracles[i].key,
                _chainsightOracles[i].decimals
            );
        }
    }

    // ----------------------------------------------------
    // Owner-only configuration
    // ----------------------------------------------------

    function setChainlinkFeed(address _feed) external onlyOwner {
        chainlinkFeed = AggregatorV3Interface(_feed);
        emit ChainlinkFeedUpdated(_feed);
    }

    function setPythFeed(address _pyth, bytes32 _priceId) external onlyOwner {
        pyth = IPyth(_pyth);
        pythPriceId = _priceId;
        emit PythFeedUpdated(_pyth, _priceId);
    }

    function addChainSightSource(address oracle, address sender, bytes32 key, uint8 decimals) external onlyOwner {
        bytes32 h = _sourceHash(sender, key);
        require(!csSourceExists[h], "MSO-1: duplicate ChainSight source");
        csSourceExists[h] = true;

        ChainSightSource memory src =
            ChainSightSource({oracle: IChainSight(oracle), sender: sender, key: key, decimals: decimals});
        chainsightSources.push(src);
        emit ChainSightSourceAdded(oracle, sender, key, decimals);
    }

    function clearAllChainSightSources() external onlyOwner {
        // Remove each mapping bit & emit individual removal events
        for (uint256 i; i < chainsightSources.length; ++i) {
            ChainSightSource memory s = chainsightSources[i];
            bytes32 h = _sourceHash(s.sender, s.key);
            delete csSourceExists[h];
        }
        delete chainsightSources;
        emit AllChainSightSourcesCleared();
    }

    function setAggregatorDecimals(uint8 _decimals) external onlyOwner {
        require(_decimals <= 20, "MSO-2: decimals too large");
        aggregatorDecimals = _decimals;
        emit AggregatorDecimalsUpdated(_decimals);
    }

    function setStaleThreshold(uint256 _seconds) external onlyOwner {
        staleThreshold = _seconds;
        emit StaleThresholdUpdated(_seconds);
    }

    function setLambda(uint256 _lambda) external onlyOwner {
        lambda = _lambda;
        emit LambdaUpdated(_lambda);
    }

    function setMaxPriceDeviationBps(uint256 _bps) external onlyOwner {
        maxPriceDeviationBps = _bps;
        emit MaxPriceDeviationUpdated(_bps);
    }

    function setOutlierDetectionEnabled(bool _enabled) external onlyOwner {
        outlierDetectionEnabled = _enabled;
        emit OutlierDetectionEnabledSet(_enabled);
    }

    function setAllowStaleFallback(bool _allowed) external onlyOwner {
        allowStaleFallback = _allowed;
        emit AllowStaleFallbackSet(_allowed);
    }

    // ----------------------------------------------------
    // Pausing
    // ----------------------------------------------------
    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
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
        return getPrice(id);
    }

    function getPrice(bytes32 id) public view returns (IPyth.Price memory price) {
        require(id == pythPriceId, "MSO-6: invalid pyth id");
        uint256 raw = _getAggregatedPrice();
        int32 exp = -int32(uint32(aggregatorDecimals));

        // Scale down until the value fits into an int64.
        while (raw > INT64_MAX) {
            raw /= 10;
            exp += 1;
        }
        return IPyth.Price(
            int64(uint64(raw)), // price
            0, // confidence
            exp, // exponent
            uint64(block.timestamp) // publishTime
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
        require(!paused, "MSO-3: aggregator paused");

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
            require(allowStaleFallback, "MSO-4: all sources stale");
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
        // Upper‑bound array (max possible sources)
        uint256 max = 2 + chainsightSources.length; // chainlink + pyth + N
        SourceData[] memory tmp = new SourceData[](max);
        uint256 idx;

        // Chainlink
        if (address(chainlinkFeed) != address(0)) {
            try chainlinkFeed.latestRoundData() returns (uint80, int256 clAnswer, uint256, uint256 clTime, uint80) {
                if (clAnswer >= 0) {
                    tmp[idx++] = SourceData(
                        _scaleChainlinkPrice(clAnswer, chainlinkFeed.decimals()), _validWeight(clTime), clTime
                    );
                }
            } catch { /* skip */ }
        }

        // Pyth
        if (address(pyth) != address(0)) {
            try pyth.getPriceUnsafe(pythPriceId) returns (IPyth.Price memory pData) {
                if (pData.price >= 0) {
                    tmp[idx++] = SourceData(
                        _scalePythPrice(pData.price, pData.expo), _validWeight(pData.publishTime), pData.publishTime
                    );
                }
            } catch { /* skip */ }
        }

        // ChainSight
        for (uint256 i = 0; i < chainsightSources.length; i++) {
            try chainsightSources[i].oracle.readAsUint256WithTimestamp(
                chainsightSources[i].sender, chainsightSources[i].key
            ) returns (uint256 csPrice, uint64 csTime) {
                tmp[idx++] = SourceData(
                    _scaleChainSightPrice(csPrice, chainsightSources[i].decimals), _validWeight(csTime), csTime
                );
            } catch { /* skip */ }
        }

        require(idx > 0, "MSO-5: no live sources");
        // trim to exact length
        SourceData[] memory list = new SourceData[](idx);
        for (uint256 k; k < idx; ++k) {
            list[k] = tmp[k];
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

    function _sourceHash(address sender, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, key));
    }
}
