# MultiSourceOracle

**MultiSourceOracle** is a Solidity 0.8 smart contract that aggregates price data
from multiple independent feeds—Chainlink, Pyth, and any number of on-chain
ChainSight oracles—to deliver a single, trustworthy price suitable for
production DeFi protocols.

---

## ✨ Features

| Capability | Detail |
|------------|--------|
| **Multi-provider** | Chainlink, Pyth, and N custom ChainSight feeds |
| **Timestamp-weighted averaging** | Exponential decay with configurable λ |
| **Median-based outlier filter** | Optional, kicks in when ≥3 fresh sources |
| **Stale-price fallback** | Toggleable newest-stale fallback mode |
| **Chainlink- & Pyth-compatible interfaces** | Seamless drop-in for existing integrations |
| **Owner controls** | Pause, update feeds, tweak params, manage sources |


Access prices just like native feeds:

```solidity
(int256 price,,,) = oracle.latestRoundData(); // Chainlink style
IPyth.Price memory p = oracle.getPrice(PYTH_PRICE_ID); // Pyth style
```

## Security Status
This contract suite was audited by Hacken (Report v1.0, 23 April 2025). The audit found 0 critical / 0 high / 1 medium / 2 low issues, all of which have been fixed in the current codebase. No new audit has been commissioned since that date; use in production remains at your own risk.

## Contributing
Pull requests are welcome! Please fork and open a PR.
By contributing you agree that your code is licensed under Apache 2.0 and that you have the right to license it.

## License
MultiSourceOracle is distributed under the Apache License 2.0.
See the NOTICE file for attribution notices.
