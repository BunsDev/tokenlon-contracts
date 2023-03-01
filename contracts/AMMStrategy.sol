// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";

import { Ownable } from "./abstracts/Ownable.sol";
import { IAMMStrategy } from "./interfaces/IAMMStrategy.sol";
import { UniswapV3 } from "./libraries/UniswapV3.sol";
import { LibBytes } from "./utils/LibBytes.sol";
import { IUniswapRouterV2 } from "./interfaces/IUniswapRouterV2.sol";
import { IBalancerV2Vault } from "./interfaces/IBalancerV2Vault.sol";
import { ICurveFi } from "./interfaces/ICurveFi.sol";
import { ICurveFiV2 } from "./interfaces/ICurveFiV2.sol";

contract AMMStrategy is IAMMStrategy, Ownable {
    using SafeERC20 for IERC20;
    using LibBytes for bytes;
    using SafeMath for uint256;

    address public genericSwap;
    address public immutable sushiswapRouter;
    address public immutable uniswapV2Router;
    address public immutable uniswapV3Router;
    address public immutable balancerV2Vault;

    constructor(
        address _owner,
        address _genericSwap,
        address _sushiswapRouter,
        address _uniswapV2Router,
        address _uniswapV3Router,
        address _balancerV2Vault
    ) Ownable(_owner) {
        genericSwap = _genericSwap;
        sushiswapRouter = _sushiswapRouter;
        uniswapV2Router = _uniswapV2Router;
        uniswapV3Router = _uniswapV3Router;
        balancerV2Vault = _balancerV2Vault;
    }

    modifier onlyGenericSwap() {
        require(msg.sender == genericSwap, "not from GenericSwap contract");
        _;
    }

    /// @inheritdoc IAMMStrategy
    function setGenericSwap(address newGenericSwap) external override onlyOwner {
        genericSwap = newGenericSwap;
        emit SetGenericSwap(newGenericSwap);
    }

    /// @inheritdoc IAMMStrategy
    function approveTokenList(
        address[] calldata tokenList,
        address[] calldata spenderList,
        uint256 amount
    ) external override onlyOwner {
        for (uint256 i = 0; i < tokenList.length; ++i) {
            for (uint256 j = 0; j < spenderList.length; ++j) {
                IERC20(tokenList[i]).safeApprove(spenderList[j], amount);
            }
        }
    }

    function executeStrategy(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        bytes calldata data
    ) external override onlyGenericSwap {
        (address[] memory routerAddrList, bytes[] memory dataList) = abi.decode(data, (address[], bytes[]));
        require(routerAddrList.length > 0 && routerAddrList.length == dataList.length, "wrong array lengths");
        (uint256 actualOutputAmount, uint256 actualInputAmount) = (0, 0);
        for (uint256 i = 0; i < routerAddrList.length; ++i) {
            (uint256 inputAmountPerSwap, uint256 outputAmountPerSwap) = (0, 0);
            if (routerAddrList[i] == sushiswapRouter) {
                (inputAmountPerSwap, outputAmountPerSwap) = _tradeSushiwapTokenToToken(inputToken, outputToken, dataList[i]);
            } else if (routerAddrList[i] == uniswapV2Router) {
                (inputAmountPerSwap, outputAmountPerSwap) = _tradeUniswapV2TokenToToken(inputToken, outputToken, dataList[i]);
            } else if (routerAddrList[i] == uniswapV3Router) {
                (inputAmountPerSwap, outputAmountPerSwap) = _tradeUniswapV3TokenToToken(inputToken, outputToken, dataList[i]);
            } else if (routerAddrList[i] == balancerV2Vault) {
                (inputAmountPerSwap, outputAmountPerSwap) = _tradeBalancerV2TokenToToken(inputToken, outputToken, dataList[i]);
            } else {
                // Try to match maker with Curve pool list
                (inputAmountPerSwap, outputAmountPerSwap) = _tradeCurveTokenToToken(routerAddrList[i], outputToken, dataList[i]);
            }
            require(outputAmountPerSwap > 0, "empty output token in single swap");
            actualInputAmount = actualInputAmount.add(inputAmountPerSwap);
            actualOutputAmount = actualOutputAmount.add(outputAmountPerSwap);
        }
        require(actualInputAmount == inputAmount, "inputAmount not match");
        IERC20(outputToken).safeTransfer(genericSwap, actualOutputAmount);
        emit Swapped(inputToken, inputAmount, routerAddrList, outputToken, actualOutputAmount);
    }

    function _tradeSushiwapTokenToToken(
        address _inputToken,
        address _outputToken,
        bytes memory _data
    ) internal returns (uint256, uint256) {
        (uint256 inputAmount, uint256 deadline, address[] memory path) = abi.decode(_data, (uint256, uint256, address[]));
        _validateAMMPath(_inputToken, _outputToken, path);
        uint256[] memory amounts = IUniswapRouterV2(sushiswapRouter).swapExactTokensForTokens(inputAmount, 0, path, address(this), deadline);
        return (inputAmount, amounts[amounts.length - 1]);
    }

    function _tradeUniswapV2TokenToToken(
        address _inputToken,
        address _outputToken,
        bytes memory _data
    ) internal returns (uint256, uint256) {
        (uint256 inputAmount, uint256 deadline, address[] memory path) = abi.decode(_data, (uint256, uint256, address[]));
        _validateAMMPath(_inputToken, _outputToken, path);
        uint256[] memory amounts = IUniswapRouterV2(uniswapV2Router).swapExactTokensForTokens(inputAmount, 0, path, address(this), deadline);
        return (inputAmount, amounts[amounts.length - 1]);
    }

    function _tradeUniswapV3TokenToToken(
        address _inputToken,
        address _outputToken,
        bytes memory _data
    ) internal returns (uint256, uint256) {
        UniswapV3.SwapType swapType = UniswapV3.SwapType(uint256(_data.readBytes32(0)));

        // exactInputSingle
        if (swapType == UniswapV3.SwapType.ExactInputSingle) {
            (, uint256 inputAmount, uint24 poolFee, uint256 deadline) = abi.decode(_data, (uint256, uint256, uint24, uint256));
            return (
                inputAmount,
                UniswapV3.exactInputSingle(
                    uniswapV3Router,
                    UniswapV3.ExactInputSingleParams({
                        tokenIn: _inputToken,
                        tokenOut: _outputToken,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: inputAmount,
                        amountOutMinimum: 0
                    })
                )
            );
        }

        // exactInput
        if (swapType == UniswapV3.SwapType.ExactInput) {
            (, uint256 inputAmount, uint256 deadline, bytes memory path) = abi.decode(_data, (uint256, uint256, uint256, bytes));
            return (
                inputAmount,
                UniswapV3.exactInput(
                    uniswapV3Router,
                    UniswapV3.ExactInputParams({
                        tokenIn: _inputToken,
                        tokenOut: _outputToken,
                        path: path,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: inputAmount,
                        amountOutMinimum: 0
                    })
                )
            );
        }

        revert("AMMStrategy: unsupported UniswapV3 swap type");
    }

    function _tradeBalancerV2TokenToToken(
        address _inputToken,
        address _outputToken,
        bytes memory _data
    ) internal returns (uint256, uint256) {
        (uint256 inputAmount, uint256 deadline, address[] memory path, IBalancerV2Vault.BatchSwapStep[] memory swapSteps) = abi.decode(
            _data,
            (uint256, uint256, address[], IBalancerV2Vault.BatchSwapStep[])
        );
        _validateBalancerV2(_inputToken, _outputToken, inputAmount, path, swapSteps);
        int256[] memory limits = _buildBalancerV2Limits(path, int256(inputAmount), 0);
        int256[] memory amountDeltas = IBalancerV2Vault(balancerV2Vault).batchSwap(
            IBalancerV2Vault.SwapKind.GIVEN_IN,
            swapSteps,
            path,
            // Balancer supports internal balance which keeps user balance in their contract to skip actual token transfer for efficiency.
            // AMM user should receive tokens right away after swap, so we need to turn off internal balance flag here.
            IBalancerV2Vault.FundManagement({ sender: address(this), fromInternalBalance: false, recipient: payable(address(this)), toInternalBalance: false }),
            limits,
            deadline
        );
        // amount swapped out from balancer will denoted with negative sign
        return (inputAmount, uint256(-amountDeltas[amountDeltas.length - 1]));
    }

    function _tradeCurveTokenToToken(
        address _routerAddr,
        address _outputToken,
        bytes memory _data
    ) internal returns (uint256, uint256) {
        (uint256 inputAmount, uint8 version, int128 inputTokenIndex, int128 outputTokenIndex, uint16 swapMethod) = abi.decode(
            _data,
            (uint256, uint8, int128, int128, uint16)
        );
        uint256 balanceBefore = IERC20(_outputToken).balanceOf(address(this));
        require(version == 1 || version == 2, "AMMStrategy: Invalid Curve version");
        require(inputTokenIndex >= 0 && outputTokenIndex >= 0, "AMMStrategy: Invalid Curve index");
        if (version == 1) {
            require(swapMethod == 1 || swapMethod == 2, "AMMStrategy: Invalid swapMethod for CurveV1");
            ICurveFi curve = ICurveFi(_routerAddr);
            if (swapMethod == 1) {
                curve.exchange(inputTokenIndex, outputTokenIndex, inputAmount, 0);
            } else {
                curve.exchange_underlying(inputTokenIndex, outputTokenIndex, inputAmount, 0);
            }
        } else {
            ICurveFiV2 curve = ICurveFiV2(_routerAddr);
            require(swapMethod == 1, "AMMStrategy: Curve v2 no underlying");
            curve.exchange(uint128(inputTokenIndex), uint128(outputTokenIndex), inputAmount, 0, true);
        }
        uint256 balanceAfter = IERC20(_outputToken).balanceOf(address(this));
        return (inputAmount, balanceAfter.sub(balanceBefore));
    }

    function _validateAMMPath(
        address _inputToken,
        address _outputToken,
        address[] memory _path
    ) internal pure {
        require(_path.length >= 2, "path length must be at least two");
        require(_path[0] == _inputToken, "invalid path");
        require(_path[_path.length - 1] == _outputToken, "invalid path");
    }

    function _validateBalancerV2(
        address _inputToken,
        address _outputToken,
        uint256 _inputAmount,
        address[] memory _path,
        IBalancerV2Vault.BatchSwapStep[] memory _swapSteps
    ) internal pure {
        require(_inputAmount <= uint256(type(int256).max), "AMMStrategy: InputAmount of BalancerV2 should be int256");
        _validateAMMPath(_inputToken, _outputToken, _path);
        require(_swapSteps.length > 0, "AMMStrategy: BalancerV2 requires at least one swap step");
        require(_path[_swapSteps[0].assetInIndex] == _inputToken, "AMMStrategy: BalancerV2 first step asset in should match taker asset");
        require(_path[_swapSteps[_swapSteps.length - 1].assetOutIndex] == _outputToken, "AMMStrategy: BalancerV2 last step asset out should match maker asset");

        require(_swapSteps[0].amount <= _inputAmount, "AMMStrategy: BalancerV2 cannot swap more than taker asset amount");
        for (uint256 i = 1; i < _swapSteps.length; ++i) {
            require(_swapSteps[i].amount == 0, "AMMStrategy: BalancerV2 can only specify amount at first step");
        }
    }

    function _buildBalancerV2Limits(
        address[] memory _path,
        int256 inputAmount,
        int256 _minOutputAmount
    ) internal pure returns (int256[] memory) {
        int256[] memory limits = new int256[](_path.length);
        // amount swapped in to balancer will denoted with positive sign
        limits[0] = inputAmount;
        for (uint256 i = 1; i < _path.length - 1; ++i) {
            // we only care final maker asset out amount
            limits[i] = type(int256).max;
        }
        // amount swapped out from balancer will denoted with negative sign
        limits[_path.length - 1] = -_minOutputAmount;
        return limits;
    }
}