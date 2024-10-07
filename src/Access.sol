// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

abstract contract Access is AccessControl {
    constructor(address admin_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }
}
