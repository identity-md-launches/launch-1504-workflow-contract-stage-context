// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token for SafeERC20 failure/return conventions and callback attacks.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        RevertTransfer,
        NoReturn,
        RecipientFee,
        SenderFee,
        NoMovement
    }

    Mode public transferMode;
    Mode public transferFromMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransfer;
    bool public callbackOnTransferFrom;
    bool public bubbleCallbackFailure;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool private _insideCallback;

    error MockTransferReverted();

    constructor() ERC20("Adversarial test token", "TEST") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function configureModes(Mode newTransferMode, Mode newTransferFromMode) external {
        transferMode = newTransferMode;
        transferFromMode = newTransferFromMode;
    }

    function configureCallback(address target, bytes calldata data, bool onTransfer, bool onTransferFrom, bool bubble)
        external
    {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransfer = onTransfer;
        callbackOnTransferFrom = onTransferFrom;
        bubbleCallbackFailure = bubble;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode mode = transferMode;
        if (mode == Mode.RevertTransfer) revert MockTransferReverted();
        if (mode == Mode.ReturnFalse) return false;
        _move(msg.sender, to, amount, mode);
        if (callbackOnTransfer) _callback();
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        Mode mode = transferFromMode;
        if (mode == Mode.RevertTransfer) revert MockTransferReverted();
        if (mode == Mode.ReturnFalse) return false;
        _spendAllowance(from, msg.sender, amount);
        _move(from, to, amount, mode);
        if (callbackOnTransferFrom) _callback();
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _move(address from, address to, uint256 amount, Mode mode) private {
        if (mode == Mode.NoMovement) return;
        if (mode == Mode.RecipientFee) {
            _transfer(from, to, amount - 1);
            _burn(from, 1);
        } else {
            _transfer(from, to, amount);
            if (mode == Mode.SenderFee) _burn(from, 1);
        }
    }

    function _callback() private {
        if (_insideCallback) return;
        _insideCallback = true;
        (bool ok, bytes memory data) = callbackTarget.call(callbackData);
        callbackSucceeded = ok;
        callbackResult = data;
        if (!ok && bubbleCallbackFailure) {
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
        _insideCallback = false;
    }
}
