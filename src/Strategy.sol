// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IStrategy} from "./IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {AutomationCompatibleInterface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

contract Strategy is IStrategy, AutomationCompatibleInterface{
    address[5] private priceFeeds;

    address[5] private tokenAddresses;

    uint256 private constant PRECISION = 1e18;

    uint256[5] private allocations;

    constructor(address[5] memory _priceFeeds, uint256[5] memory _allocations, address[5] memory _tokenAddresses) {
        priceFeeds = _priceFeeds;

        allocations = _allocations;

        tokenAddresses = _tokenAddresses;
    }

    function totalValue() external view returns (uint256) {
        uint256 totalUsdcValue;
        for (uint256 i = 0; i < priceFeeds.length; ++i) {
            (, int256 price,,,) = AggregatorV3Interface(priceFeeds[i]).latestRoundData();
            totalUsdcValue += uint256(price);
        }
        return totalUsdcValue;
    }

    function invest(uint256 assets) external view {
        uint256[5] memory usdcAmounts;
        for (uint256 i = 0; i < allocations.length; ++i) {
            usdcAmounts[i] = assets * allocations[i] / 100;
        }
        //Buy tokens
    }

    function withdraw(uint256 assets) external {}

    function rebase(uint256[5] memory tokenAmounts, uint256 totalAmount) public view {
        uint256 count = 0;
        uint256[4] memory buys;

        for (uint256 i = 0; i < tokenAmounts.length; ++i) {
            uint256 currentAllocation = allocations[i];
            uint256 allocatedAmount = currentAllocation * totalAmount;
            if (tokenAmounts[i] > allocatedAmount) {
                //Sell excess
            } else if (tokenAmounts[i] < allocatedAmount) {
                buys[count] = allocatedAmount - tokenAmounts[i];
                ++count;
            }
        }

        for (uint256 i = 0; i < buys.length; ++i) {
            if (buys[i] == 0) {
                break;
            }
            //Buy difference
        }
    }

    function checkUpkeep(bytes calldata /* check data */ ) external view returns (bool, bytes memory) 
    /**
     * perform daata
     */
    {
        uint256[5] memory tokenAmounts;
        uint256 totalAmount;
        for (uint256 i = 0; i < tokenAddresses.length; ++i) {
            tokenAmounts[i] = _valueInUsdc(IERC20(tokenAddresses[i]).balanceOf(address(this)), priceFeeds[i]);
            totalAmount += tokenAmounts[i];
        }
        bytes memory performData = abi.encode(tokenAmounts, totalAmount);
        for (uint256 i = 0; i < tokenAmounts.length; ++i) {
            if (SignedMath.abs(int256(tokenAmounts[i]) - int256(allocations[i] * totalAmount)) > (5 * totalAmount / 100)) {
                return (true, performData);
            }
        }
        return (false, "");
    }

    function performUpkeep(bytes memory performData) external view {
        (uint256[5] memory tokenAmounts, uint256 totalAmount) = abi.decode(performData, (uint256[5], uint256));
        rebase(tokenAmounts, totalAmount);
    }

    function _valueInUsdc(uint256 amount, address priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return uint256(price) * amount / 1e8;
    }
}
