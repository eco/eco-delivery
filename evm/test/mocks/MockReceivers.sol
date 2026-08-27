// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deliver} from "../../src/Deliver.sol";
import {ITokenHookReceiver} from "./MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A token recipient that re-enters {Deliver.deliverToken} from its transfer hook, and
///         records what the world looked like at the moment it re-entered.
contract ReentrantTokenRecipient is ITokenHookReceiver {
    Deliver public deliver;
    IERC20 public token;

    /// @dev `min` the re-entrant call passes. 0 exercises the no-op path, > 0 the revert path.
    uint256 public reentrantMin;

    bool public reentered;
    /// @dev Deliver's token balance observed from inside the hook.
    uint256 public observedDeliverBalance;
    bool public reentrantCallReverted;
    bytes public reentrantRevertData;

    bool private _inHook;

    constructor(
        Deliver deliver_,
        IERC20 token_,
        uint256 reentrantMin_
    ) {
        deliver = deliver_;
        token = token_;
        reentrantMin = reentrantMin_;
    }

    function onTokenHook(
        address,
        address,
        uint256
    ) external override {
        if (_inHook) return;
        _inHook = true;

        reentered = true;
        observedDeliverBalance = token.balanceOf(address(deliver));

        try deliver.deliverToken(token, address(this), reentrantMin) {}
        catch (bytes memory err) {
            reentrantCallReverted = true;
            reentrantRevertData = err;
        }

        _inHook = false;
    }
}

/// @notice A native recipient that refuses ETH. Used to prove the native path fails closed.
contract RejectingNativeRecipient {
    error RejectedNative();

    receive() external payable {
        revert RejectedNative();
    }
}

/// @notice A native recipient that re-enters {Deliver.deliverNative} on receipt, and records what
///         the world looked like at the moment it re-entered.
contract ReentrantNativeRecipient {
    Deliver public deliver;

    /// @dev `min` the re-entrant call passes. 0 exercises the no-op path, > 0 the revert path.
    uint256 public reentrantMin;

    uint256 public totalReceived;
    uint256 public receiveCount;
    bool public reentered;
    /// @dev Deliver's ETH balance observed from inside the re-entrant callback.
    uint256 public observedDeliverBalance;
    bool public reentrantCallReverted;
    bytes public reentrantRevertData;

    bool private _inCallback;

    constructor(
        Deliver deliver_,
        uint256 reentrantMin_
    ) {
        deliver = deliver_;
        reentrantMin = reentrantMin_;
    }

    receive() external payable {
        totalReceived += msg.value;
        receiveCount += 1;

        if (_inCallback) return;
        _inCallback = true;

        reentered = true;
        observedDeliverBalance = address(deliver).balance;

        try deliver.deliverNative(address(this), reentrantMin) {}
        catch (bytes memory err) {
            reentrantCallReverted = true;
            reentrantRevertData = err;
        }

        _inCallback = false;
    }
}

/// @notice A plain contract recipient that accepts ETH without doing anything.
contract PassiveNativeRecipient {
    receive() external payable {}
}
