// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBudgetToken} from "../interfaces/IBudgetToken.sol";

/// @title MockLedger
/// @notice 테스트 전용. BudgetToken 단위 테스트에서 원장 자리에 넣어 spend / refund 를 직접 부른다.
/// @dev setLedger 가 확인하는 roleManager()·budgetToken() 만 흉내 낸다. 배포 스크립트는 이 컨트랙트를 쓰지 않는다.
contract MockLedger {
    address public immutable roleManager;
    address public immutable budgetToken;

    constructor(address roleManager_, address budgetToken_) {
        roleManager = roleManager_;
        budgetToken = budgetToken_;
    }

    function spend(uint256 budgetId, uint256 amount, uint256 entryId) external {
        IBudgetToken(budgetToken).spend(budgetId, amount, entryId);
    }

    function refund(uint256 budgetId, uint256 amount, uint256 entryId) external {
        IBudgetToken(budgetToken).refund(budgetId, amount, entryId);
    }
}
