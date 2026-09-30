// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// 세 컨트랙트가 같은 값을 써야 하는 상수. 한 곳에서만 정의한다 (값이 어긋나면 일부 항목이 PENDING 에 묶인다).

/// @dev 롤 식별자 = keccak256(롤 이름). docs/enums.md role 표에서 STUDENT 를 뺀 셋.
bytes32 constant ROLE_TREASURER = keccak256("TREASURER");
bytes32 constant ROLE_AUDITOR = keccak256("AUDITOR");
bytes32 constant ROLE_PRESIDENT = keccak256("PRESIDENT");

/// @dev 금액 상한 (원). 원장의 |amount| 와 예산 한도가 같은 값을 쓴다.
uint256 constant MAX_AMOUNT_WON = 1e15;

/// @title Signatures
/// @notice EIP-712 digest 에서 서명자를 복구한다. 서명 바이트가 깨졌으면 address(0).
/// @dev 각 컨트랙트는 0 이면 자기 InvalidSignature 로 revert 한다 (에러를 컨트랙트 ABI 에 두기 위해 라이브러리는 revert 하지 않는다).
library Signatures {
    function recoverOrZero(bytes32 digest, bytes calldata signature) internal pure returns (address signer) {
        ECDSA.RecoverError err;
        (signer, err, ) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) signer = address(0);
    }
}
