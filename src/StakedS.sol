// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "openzeppelin-contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

/**
 * @title StakedS Contract
 * @author Beethoven X
 * @notice The ERC20 contract for the sSONICx token
 */
contract StakedS is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() ERC20("Staked S", "stkS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    /**
     * @notice Mints stkS when called by an authorized caller
     * @param to the account to mint to
     * @param amount the amount of stkS to mint
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Burns stkS when called by an authorized caller
     * @param account the account to burn from
     * @param amount the amount of stkS to burn
     */
    function burnFrom(address account, uint256 amount) public override onlyRole(MINTER_ROLE) {
        _burn(account, amount);
    }
}
