// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IRandomNumber {
    function requestRandomWords(bool enableNativePayment) external returns (uint256 requestId);

    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords);
}
