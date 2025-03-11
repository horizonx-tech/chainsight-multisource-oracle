// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/access/Ownable.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IChainSight {
    function readAsUint256WithTimestamp(
        address sender,
        bytes32 key
    ) external view returns (uint256, uint64);
}

interface IPyth {
    struct Price {
        // Price
        int64 price;
        // Confidence interval around the price
        uint64 conf;
        // Price exponent
        int32 expo;
        // Unix timestamp describing when the price was published
        uint publishTime;
    }
    function getPriceUnsafe(
        bytes32 id
    ) external view returns (Price memory price);
}

contract MultiSourceOracle {
    AggregatorV3Interface public immutable chainlinkFeed;
    IPyth public immutable pyth;
    IChainSight public immutable chainsight;

    bytes32 public immutable pythPriceId;
    bytes32 public immutable chainsightKey;
    address public immutable chainsightSender;

    uint256 public staleThreshold = 3600; // 1 hour default
    uint256 public lambda = 1925; // ~0.0001925 per second (~half-life = 1 hour), scaled by 1e6

    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

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

    function setStaleThreshold(uint256 _seconds) external onlyOwner {
        staleThreshold = _seconds;
    }

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
        uint256 aggregatedPrice = getAggregatedPrice();
        return (
            0,
            int256(aggregatedPrice),
            block.timestamp,
            block.timestamp,
            0
        );
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (IPyth.Price memory) {
        require(id == pythPriceId, "Invalid price ID");
        uint256 aggregatedPrice = getAggregatedPrice();
        return
            IPyth.Price(int64(int256(aggregatedPrice)), 0, -8, block.timestamp);
    }

    function readAsUint256WithTimestamp(
        address sender,
        bytes32 key
    ) external view returns (uint256 price, uint64 timestamp) {
        require(key == chainsightKey, "Invalid key");
        require(sender == chainsightSender, "Invalid sender");
        uint256 aggregatedPrice = getAggregatedPrice();
        return (aggregatedPrice, uint64(block.timestamp));
    }

    // Helper function to scale Chainlink price to 8 decimals.
    function scaleChainlinkPrice(
        int256 _price,
        uint8 _decimals
    ) internal pure returns (uint256) {
        uint256 scaled = uint256(_price);
        if (_decimals > 8) {
            scaled /= 10 ** (_decimals - 8);
        } else if (_decimals < 8) {
            scaled *= 10 ** (8 - _decimals);
        }
        return scaled;
    }

    // Helper function to scale Pyth price to 8 decimals.
    function scalePythPrice(
        int64 _price,
        int32 _expo
    ) internal pure returns (uint256) {
        if (8 + _expo >= 0) {
            return uint256(int256(_price)) * (10 ** uint256(uint32(8 + _expo)));
        } else {
            return
                uint256(int256(_price)) / (10 ** uint256(uint32(-(8 + _expo))));
        }
    }

    // Helper function to compute weight based on freshness.
    function validWeight(uint256 _timestamp) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - _timestamp;
        if (_timestamp <= block.timestamp && elapsed <= staleThreshold) {
            return expDecay(elapsed);
        }
        return 0;
    }

    function getAggregatedPrice() internal view returns (uint256) {
        // Retrieve Chainlink data.
        (, int256 clPrice, , uint256 clTimestamp, ) = chainlinkFeed
            .latestRoundData();
        // Retrieve Pyth price (using its struct directly without extra locals).
        IPyth.Price memory pyPrice = pyth.getPriceUnsafe(pythPriceId);
        // Retrieve Chainsight data.
        (uint256 csPrice, uint64 csTimestamp) = chainsight
            .readAsUint256WithTimestamp(chainsightSender, chainsightKey);

        require(clPrice >= 0, "Chainlink price negative");
        require(pyPrice.price >= 0, "Pyth price negative");

        // Scale prices.
        uint256 clScaledPrice = scaleChainlinkPrice(
            clPrice,
            chainlinkFeed.decimals()
        );
        uint256 pythScaledPrice = scalePythPrice(pyPrice.price, pyPrice.expo);
        uint256 csScaledPrice = csPrice; // Chainsight is assumed to be 8 decimals

        // Prepare arrays for prices and weights.
        uint256[3] memory prices;
        uint256[3] memory weights;
        uint256 validCount = 0;

        uint256 w = validWeight(clTimestamp);
        if (w != 0) {
            prices[validCount] = clScaledPrice;
            weights[validCount] = w;
            validCount++;
        }
        w = validWeight(pyPrice.publishTime);
        if (w != 0) {
            prices[validCount] = pythScaledPrice;
            weights[validCount] = w;
            validCount++;
        }
        w = validWeight(csTimestamp);
        if (w != 0) {
            prices[validCount] = csScaledPrice;
            weights[validCount] = w;
            validCount++;
        }

        require(validCount > 0, "No valid prices available");

        // Calculate weighted average price.
        uint256 weightedSum = 0;
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < validCount; i++) {
            weightedSum += prices[i] * weights[i];
            totalWeight += weights[i];
        }

        return weightedSum / totalWeight;
    }

    function expDecay(uint256 elapsed) internal view returns (uint256) {
        return 1e6 / (1e6 + lambda * elapsed); // Approximate exponential decay
    }
}
