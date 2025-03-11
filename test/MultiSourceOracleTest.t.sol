// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MultiSourceOracle.sol";

contract MultiSourceOracleTest is Test {
    MultiSourceOracle oracle;
    address oracle1 = address(0xA11ce);  // dummy oracle addresses
    address oracle2 = address(0xB0b);
    address oracle3 = address(0xC0de);
    
    // The stale period for tests (e.g., 1 day)
    uint256 constant STALE_PERIOD = 1 days;

    function setUp() public {

    }
}