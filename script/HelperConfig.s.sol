// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    address[5] priceFeeds;
    uint256[5] allocations;
    address[5] tokenAddresses;
    address vaultToken;
    address permit2;
    address universalRouter;
    address poolManager;
}