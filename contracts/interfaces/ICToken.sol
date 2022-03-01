// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;
import "./IERC20.sol";

interface ICToken is IERC20 {
    function mint(uint mintAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function exchangeRateCurrent() external returns (uint);
    function borrowRatePerBlock() external returns (uint);
    function balanceOfUnderlying(address account) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
}