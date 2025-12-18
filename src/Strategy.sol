// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IStrategy} from "./IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {AutomationCompatibleInterface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey, IHooks} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract Strategy is IStrategy, AutomationCompatibleInterface {
    using StateLibrary for IPoolManager;

    IPermit2 private immutable PERMIT2;
    IUniversalRouter private immutable UNIVERSAL_ROUTER;
    IPoolManager private immutable POOL_MANAGER;

    address private immutable VAULT_TOKEN;

    address[5] private priceFeeds;

    address[5] private tokenAddresses;

    uint256 private constant PRECISION = 1e18;

    uint256[5] private allocations;


    constructor(
        address[5] memory _priceFeeds,
        uint256[5] memory _allocations,
        address[5] memory _tokenAddresses,
        address vaultToken,
        address permit2,
        address universalRouter,
        address poolManager
    ) {
        priceFeeds = _priceFeeds;

        allocations = _allocations;

        tokenAddresses = _tokenAddresses;

        VAULT_TOKEN = vaultToken;

        PERMIT2 = IPermit2(permit2);
        UNIVERSAL_ROUTER = IUniversalRouter(universalRouter);
        POOL_MANAGER = IPoolManager(poolManager);

        IERC20(VAULT_TOKEN).approve(address(PERMIT2), type(uint256).max);
    }

    /**
     * @dev Returns the total value of the strategy's assets in USDC.
     */
    function totalValue() external view returns (uint256) {
        uint256 totalUsdcValue;
        for (uint256 i = 0; i < priceFeeds.length; ++i) {
            totalUsdcValue += _valueInUsdc(IERC20(tokenAddresses[i]).balanceOf(address(this)), priceFeeds[i]);
        }
        return totalUsdcValue;
    }

    /**
     * @dev Invests the specified amount of assets according to the predefined allocations.
     * @param assets The amount of assets to invest.
     */
    function invest(uint256 assets) external {
        for (uint256 i = 0; i < allocations.length; ++i) {
            uint256 usdcAmount = assets * allocations[i] / 100;
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(VAULT_TOKEN),
                currency1: Currency.wrap(tokenAddresses[i]),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });

            _swap(key, uint128(usdcAmount), uint128(_valueInUsdc(usdcAmount, priceFeeds[i])), 2 minutes);
        }
    }

    /**
     * @dev Withdraws the specified amount of assets by converting held tokens back to USDC.
     * @param assets The amount of assets to withdraw.
     */
    function withdraw(uint256 assets) external {
        for (uint256 i = 0; i < 5; ++i) {
            uint256 usdAmountOfAsset = assets * allocations[i] / 100;
            uint256 amountOfAsset = _amountOfAsset(usdAmountOfAsset, priceFeeds[i]);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(tokenAddresses[i]),
                currency1: Currency.wrap(VAULT_TOKEN),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });

            _swap(key, uint128(amountOfAsset), uint128(_tokenValue(amountOfAsset, priceFeeds[i])), 2 minutes);
        }
    }

    /**
     * @dev Rebalances the portfolio to match the target allocations.
     * @param tokenAmounts The current amounts of each token held.
     * @param totalAmount The total value of all tokens held.
     */
    function rebase(uint256[5] memory tokenAmounts, uint256 totalAmount) public {
        uint256 count = 0;
        uint256[4][2] memory buys;

        for (uint256 i = 0; i < tokenAmounts.length; ++i) {
            uint256 currentAllocation = allocations[i];
            uint256 allocatedAmount = currentAllocation * totalAmount;
            if (tokenAmounts[i] > allocatedAmount) {
                
                PoolKey memory key = PoolKey({
                    currency0: Currency.wrap(tokenAddresses[i]),
                    currency1: Currency.wrap(VAULT_TOKEN),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: IHooks(address(0))
                });
                uint256 amountOfAsset = _amountOfAsset(tokenAmounts[i] - allocatedAmount, priceFeeds[i]);
                _swap(key, uint128(amountOfAsset), uint128(_tokenValue(amountOfAsset, priceFeeds[i])), 2 minutes);


            } else if (tokenAmounts[i] < allocatedAmount) {
                buys[count][0] = allocatedAmount - tokenAmounts[i];
                buys[count][1] = i;
                ++count;
            }
        }

        for (uint256 i = 0; i < buys.length; ++i) {
            if (buys[i][0] == 0) {
                break;
            }
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(VAULT_TOKEN),
                currency1: Currency.wrap(tokenAddresses[i]),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });

            _swap(key, uint128(buys[i][0]), uint128(_valueInUsdc(buys[i][0], priceFeeds[buys[i][1]])), 2 minutes); //revisit
        }
    }

    /**
     * @dev Checks if the strategy needs to perform upkeep.
     * @return shouldPerformUpkeep
     * @return performData
     */
    function checkUpkeep(bytes calldata /* check data */ ) external view returns (bool, bytes memory) 
    {
        uint256[5] memory tokenAmounts;
        uint256 totalAmount;
        for (uint256 i = 0; i < tokenAddresses.length; ++i) {
            tokenAmounts[i] = _valueInUsdc(IERC20(tokenAddresses[i]).balanceOf(address(this)), priceFeeds[i]);
            totalAmount += tokenAmounts[i];
        }
        bytes memory performData = abi.encode(tokenAmounts, totalAmount);
        for (uint256 i = 0; i < tokenAmounts.length; ++i) {
            if (
                SignedMath.abs(int256(tokenAmounts[i]) - int256(allocations[i] * totalAmount)) > (5 * totalAmount / 100)
            ) {
                return (true, performData);
            }
        }
        return (false, "");
    }

    /**
     * @dev Performs the upkeep by rebalancing the portfolio.
     * @param performData The data needed to perform the upkeep.
     */
    function performUpkeep(bytes memory performData) external {
        (uint256[5] memory tokenAmounts, uint256 totalAmount) = abi.decode(performData, (uint256[5], uint256));
        rebase(tokenAmounts, totalAmount);
    }

    /**
     * @dev Helper function to get the amount of asset equivalent to a given USDC amount.
     * @param usdcAmount The amount in USDC.
     * @param priceFeed The address of the price feed for the asset.
     * @return The equivalent amount of the asset.
     */
    function _amountOfAsset(uint256 usdcAmount, address priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return usdcAmount * 1e8 / uint256(price);
    }

    /**
     * @dev Helper function to get the USDC value of a given amount of asset.
     * @param amount The amount of the asset.
     * @param priceFeed The address of the price feed for the asset.
     * @return The USDC value of the asset amount.
     */
    function _valueInUsdc(uint256 amount, address priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return uint256(price) * amount / 1e8;
    }

    /**
     * @dev Helper function that approves the specified amount of tokens to be spent by the Universal Router.
     * @param amount The amount to approve
     * @param expiration The expiration time of the approval
     */
    function _approve(uint160 amount, uint48 expiration) internal {
        PERMIT2.approve(VAULT_TOKEN, address(UNIVERSAL_ROUTER), amount, expiration);
    }

    /**
     * @dev Helper function to perform a token swap using Uniswap V4's Universal Router.
     * @param key PoolKey struct that identifies the v4 pool
     * @param amountIn Exact amount of tokens to swap
     * @param minAmountOut Minimum amount of output tokens expected
     * @param deadline Timestamp after which the transaction will revert
     */
    function _swap(
        PoolKey memory key, // PoolKey struct that identifies the v4 pool
        uint128 amountIn, // Exact amount of tokens to swap
        uint128 minAmountOut, // Minimum amount of output tokens expected
        uint256 deadline // Timestamp after which the transaction will revert
    ) internal returns (uint256 amountOut) {
        bytes memory commands = abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_IN));
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );

        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, amountOut);

        inputs[0] = abi.encode(actions, params);

        uint256 initialBalance = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));

        UNIVERSAL_ROUTER.execute(commands, inputs, deadline);
        uint256 finalBalance = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        amountOut = finalBalance - initialBalance;
        if (amountOut < minAmountOut) {
            revert IV4Router.V4TooLittleReceived(minAmountOut, amountOut);
        }
        return amountOut;
    }

    /**
     * @dev Helper function to get the token value equivalent to a given USDC amount.
     * @param usdcAmount The amount of USDC to convert.
     * @param priceFeed The address of the price feed for the token.
     */
    function _tokenValue(uint256 usdcAmount, address priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return usdcAmount * 1e8 / uint256(price);
    }
}
