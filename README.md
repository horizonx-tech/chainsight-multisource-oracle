# ChainSight Multi-Source Oracle

ChainSight’s Oracle Aggregator is a hybrid price feed that combines data from Chainlink, Pyth, and ChainSight to produce a single robust price on an EVM-compatible blockchain. The design uses a weighted aggregation of these feeds, with weights dynamically adjustable by ChainSight’s Relayer. The aggregator runs as an on-chain Solidity contract that ingests the latest prices from each oracle source, applies the specified weights, and stores a consolidated price for use by other contracts. By leveraging multiple oracles, the system gains redundancy and accuracy – if one data source is slow or faulty, the others can compensate. 

