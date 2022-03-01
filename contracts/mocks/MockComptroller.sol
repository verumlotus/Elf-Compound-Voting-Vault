// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "../interfaces/IComptroller.sol";

contract MockComptroller is IComptroller {
    function enterMarkets(address[] calldata cTokens) external pure override returns (uint[] memory) {
        uint[] memory result = new uint[](cTokens.length);
        for (uint i = 0; i < cTokens.length; i++) {
            result[i] = 0;
        }
        return result;
    }
}