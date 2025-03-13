// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interface/IChainlink.sol";
import "./interface/IPyth.sol";
import "./interface/IChainSight.sol";

/**
 * @title MultiSourceOracle
 * @notice Aggregates prices from Chainlink, Pyth, and Chainsight.
 *         Includes outlier detection (now using a median approach for 3 fresh sources),
 *         and a fallback for stale data.
 */
contract MultiSourceOracle {
    // ---------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------
    AggregatorV3Interface public immutable chainlinkFeed;
    IPyth public immutable pyth;
    IChainSight public immutable chainsight;

    bytes32 public immutable pythPriceId;
    bytes32 public immutable chainsightKey;
    address public immutable chainsightSender;

    // ---------------------------------------------------------
    // Mutable parameters
    // ---------------------------------------------------------
    uint256 public staleThreshold = 3600; // 1 hour default
    uint256 public lambda = 1925;         // ~0.0001925 per second (~half-life=1 hour), scaled by 1e6
    uint256 public maxPriceDeviationBps = 2000; // 20% default for outlier detection

    // ---------------------------------------------------------
    // Owner
    // ---------------------------------------------------------
    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ---------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------
    constructor(
        address _chainlinkFeed,
        address _pyth,
        address _chainsight,
        address _chainsightSender,
        bytes32 _pythPriceId,
        bytes32 _chainsightKey
    ) {
        owner = msg.sender;
        chainlinkFeed = AggregatorV3Interface(_chainlinkFeed);
        pyth = IPyth(_pyth);
        chainsight = IChainSight(_chainsight);
        chainsightSender = _chainsightSender;
        pythPriceId = _pythPriceId;
        chainsightKey = _chainsightKey;
    }

    // ---------------------------------------------------------
    // Configuration setters
    // ---------------------------------------------------------
    function setStaleThreshold(uint256 _seconds) external onlyOwner {
        staleThreshold = _seconds;
    }

    function setMaxPriceDeviationBps(uint256 _bps) external onlyOwner {
        maxPriceDeviationBps = _bps;
    }

    // ---------------------------------------------------------
    // Chainlink-like interface
    // ---------------------------------------------------------
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        uint256 agg = _getAggregatedPrice();
        return (
            0,
            int256(agg),
            block.timestamp,
            block.timestamp,
            0
        );
    }

    // ---------------------------------------------------------
    // Pyth-like interface
    // ---------------------------------------------------------
    function getPriceUnsafe(bytes32 id) external view returns (IPyth.Price memory) {
        require(id == pythPriceId, "Invalid price ID");
        uint256 agg = _getAggregatedPrice();
        return IPyth.Price(
            int64(int256(agg)),
            0,    // dummy confidence
            -8,   // indicates we have scaled to 8 decimals
            block.timestamp
        );
    }

    // ---------------------------------------------------------
    // Chainsight-like interface
    // ---------------------------------------------------------
    function readAsUint256WithTimestamp(address sender, bytes32 key)
        external
        view
        returns (uint256 price, uint64 timestamp)
    {
        require(sender == chainsightSender, "Invalid sender");
        require(key == chainsightKey, "Invalid key");

        uint256 agg = _getAggregatedPrice();
        return (agg, uint64(block.timestamp));
    }

    // ---------------------------------------------------------
    // Internal aggregation logic
    // ---------------------------------------------------------

    struct SourceData {
        uint256 price;    // scaled to 8 decimals
        uint256 weight;   // exponential decay weight if fresh, else 0
        uint256 timestamp;
    }

    function _getAggregatedPrice() internal view returns (uint256) {
        SourceData[3] memory s;

        // 1) Chainlink
        {
            ( , int256 clAnswer, , uint256 clUpdatedAt,) = chainlinkFeed.latestRoundData();
            require(clAnswer >= 0, "Chainlink price negative");
            s[0].timestamp = clUpdatedAt;
            s[0].price = _scaleChainlinkPrice(clAnswer, chainlinkFeed.decimals());
            s[0].weight = _validWeight(clUpdatedAt);
        }

        // 2) Pyth
        {
            IPyth.Price memory p = pyth.getPriceUnsafe(pythPriceId);
            require(p.price >= 0, "Pyth price negative");
            s[1].timestamp = p.publishTime;
            s[1].price = _scalePythPrice(p.price, p.expo);
            s[1].weight = _validWeight(p.publishTime);
        }

        // 3) Chainsight
        {
            (uint256 cPrice, uint64 cTimestamp) = chainsight.readAsUint256WithTimestamp(
                chainsightSender,
                chainsightKey
            );
            s[2].timestamp = cTimestamp;
            s[2].price = cPrice; // assumed 8 decimals
            s[2].weight = _validWeight(cTimestamp);
        }

        // Count how many are fresh
        uint256 validCount;
        for (uint256 i = 0; i < 3; i++) {
            if (s[i].weight != 0) {
                validCount++;
            }
        }

        // 4) If none fresh => fallback to newest stale
        if (validCount == 0) {
            return _fallbackNewest(s);
        }

        // 5) Outlier detection
        //    We'll do a median approach if 3 are fresh, so that a single huge outlier won't skew average
        (uint256 freshCount, bool threeAreFresh) = _countFresh(s);
        if (threeAreFresh) {
            // If all 3 are fresh, find the median price among the 3
            uint256 med = _medianOfThree(s);
            // Then apply the outlier filter around that median
            _applyOutlierFilterMedian(s, med);
        } else if (freshCount == 2) {
            // Optionally skip outlier detection if exactly 2 fresh (original logic).
            // If you want some logic for 2-fresh outliers, add it here.
        }

        // 6) Re-check how many remain
        uint256 finalCount;
        for (uint256 i = 0; i < 3; i++) {
            if (s[i].weight > 0) {
                finalCount++;
            }
        }
        if (finalCount == 0) {
            // fallback
            return _fallbackNewest(s);
        }

        // 7) Weighted average
        uint256 weightedSum;
        uint256 totalWeight;
        for (uint256 i = 0; i < 3; i++) {
            if (s[i].weight > 0) {
                weightedSum += (s[i].price * s[i].weight);
                totalWeight += s[i].weight;
            }
        }
        return weightedSum / totalWeight;
    }

    // ---------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------

    function _countFresh(SourceData[3] memory s)
        internal
        pure
        returns (uint256 freshCount, bool threeAreFresh)
    {
        for (uint256 i = 0; i < 3; i++) {
            if (s[i].weight > 0) {
                freshCount++;
            }
        }
        threeAreFresh = (freshCount == 3);
    }

    /**
     * @dev Returns the median of the 3 prices that are fresh (weight>0).
     *      We assume all 3 are fresh. This is used for outlier detection.
     */
    function _medianOfThree(SourceData[3] memory s) internal pure returns (uint256) {
        // We only consider the .price of the sources with weight>0, but here we assume all 3 are fresh
        // Sort the array by .price
        uint256[3] memory arr;
        for (uint256 i = 0; i < 3; i++) {
            arr[i] = s[i].price;
        }
        // simple bubble or manual sort for 3 items
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = i+1; j < 3; j++) {
                if (arr[i] > arr[j]) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
        // median is arr[1]
        return arr[1];
    }

    /**
     * @dev If a source's price is more than `maxPriceDeviationBps` away from median, set weight=0.
     */
    function _applyOutlierFilterMedian(SourceData[3] memory s, uint256 median) internal view {
        uint256 dev = maxPriceDeviationBps; // e.g. 2000 => ±20%
        // lower bound
        uint256 low = (median * (10000 - dev)) / 10000;
        // upper bound
        uint256 high = (median * (10000 + dev)) / 10000;

        for (uint256 i = 0; i < 3; i++) {
            if (s[i].weight == 0) {
                continue; // not fresh anyway
            }
            if (s[i].price < low || s[i].price > high) {
                s[i].weight = 0;
            }
        }
    }

    /**
     * @dev Returns newest price among the 3 items, ignoring staleness/outliers.
     */
    function _fallbackNewest(SourceData[3] memory s) internal pure returns (uint256) {
        uint256 maxI = 0;
        for (uint256 i = 1; i < 3; i++) {
            if (s[i].timestamp > s[maxI].timestamp) {
                maxI = i;
            }
        }
        return s[maxI].price;
    }

    /**
     * @dev Scaling functions and weighting
     */
    function _scaleChainlinkPrice(int256 _price, uint8 _decimals) internal pure returns (uint256) {
        uint256 scaled = uint256(_price);
        if (_decimals > 8) {
            scaled /= 10 ** (_decimals - 8);
        } else if (_decimals < 8) {
            scaled *= 10 ** (8 - _decimals);
        }
        return scaled;
    }

    function _scalePythPrice(int64 _price, int32 _expo) internal pure returns (uint256) {
        int256 p = int256(_price);
        int32 diff = 8 + _expo;
        if (diff >= 0) {
            return uint256(p) * 10 ** uint256(uint32(diff));
        } else {
            return uint256(p) / 10 ** uint256(uint32(-diff));
        }
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
        // 1e12 / (1e6 + lambda * elapsed)
        return 1e12 / (1e6 + lambda * elapsed);
    }
}
