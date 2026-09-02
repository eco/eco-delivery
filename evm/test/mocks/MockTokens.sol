// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Callback a hook token invokes on a contract counterparty, ERC-777 `tokensReceived` /
///         `tokensToSend` in spirit but without the ERC-1820 registry ceremony.
interface ITokenHookReceiver {
    function onTokenHook(
        address from,
        address to,
        uint256 value
    ) external;
}

/// @notice A plain, well-behaved ERC-20 that returns `true` from `transfer`.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(
        address to,
        uint256 value
    ) external {
        _mint(to, value);
    }
}

/// @notice USDT-style: `transfer` moves the tokens but returns **nothing**. Not `IERC20`-compatible
///         at the ABI level, which is exactly why `SafeERC20` is required.
contract NoReturnERC20 {
    // ERC-20 metadata is lowercase by the standard, so the SCREAMING_SNAKE_CASE lint is wrong here.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "NoReturn";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "NORET";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(
        address to,
        uint256 value
    ) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    /// @dev Deliberately declares no return value.
    function transfer(
        address to,
        uint256 value
    ) external {
        uint256 fromBalance = balanceOf[msg.sender];
        require(fromBalance >= value, "NoReturnERC20: insufficient balance");
        unchecked {
            balanceOf[msg.sender] = fromBalance - value;
            balanceOf[to] += value;
        }
        emit Transfer(msg.sender, to, value);
    }

    function approve(
        address spender,
        uint256 value
    ) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
}

/// @notice Returns `false` from `transfer` instead of reverting, and moves nothing. `SafeERC20` must
///         turn this into a revert.
contract FalseReturningERC20 {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "FalseReturn";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "FALSE";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address account => uint256) public balanceOf;

    function mint(
        address to,
        uint256 value
    ) external {
        totalSupply += value;
        balanceOf[to] += value;
    }

    function transfer(
        address,
        uint256
    ) external pure returns (bool) {
        return false;
    }
}

/// @notice Takes a fee on every transfer between non-zero addresses, so the recipient always
///         receives strictly less than the amount sent. This is the token class the contract-level
///         fee-on-transfer WARNING is about.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant BPS = 10_000;

    uint256 public feeBps;
    address public feeSink;

    constructor(
        uint256 feeBps_,
        address feeSink_
    ) ERC20("FeeOnTransfer", "FEE") {
        feeBps = feeBps_;
        feeSink = feeSink_;
    }

    function mint(
        address to,
        uint256 value
    ) external {
        _mint(to, value);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / BPS;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, feeSink, fee);
    }
}

/// @notice ERC-777-style token whose recipient hook fires **after** balances are updated. A
///         re-entrant recipient therefore observes the post-transfer world.
contract RecipientHookERC20 is ERC20 {
    constructor() ERC20("RecipientHook", "RHOOK") {}

    function mint(
        address to,
        uint256 value
    ) external {
        _mint(to, value);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);

        if (from != address(0) && to != address(0) && to.code.length > 0) {
            ITokenHookReceiver(to).onTokenHook(from, to, value);
        }
    }
}

/// @notice ERC-777 `tokensToSend`-style token whose hook fires **before** balances are updated — the
///         nastier ordering, because a re-entrant counterparty observes the *pre*-transfer world and
///         can see a balance that is about to be spent. The hook fires at most once per transaction
///         so the recursion is bounded and the test is deterministic.
contract PreUpdateHookERC20 is ERC20 {
    bool private _hookFired;

    constructor() ERC20("PreUpdateHook", "PHOOK") {}

    function mint(
        address to,
        uint256 value
    ) external {
        _mint(to, value);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && to != address(0) && to.code.length > 0 && !_hookFired) {
            _hookFired = true;
            ITokenHookReceiver(to).onTokenHook(from, to, value);
        }

        super._update(from, to, value);
    }
}

/// @notice Charges the fee **on top**: the recipient receives the full `amount` and the sender is
///         debited `amount + fee`. The mirror image of {FeeOnTransferERC20}, and the reason a
///         sweep-everything contract cannot deliver such a token at all — it holds exactly its
///         balance, and the transfer demands more than that.
///
///         Note this makes the token broken far beyond this contract: no holder can ever transfer
///         their entire balance, at any size, to anyone.
contract SenderSurchargeERC20 is ERC20 {
    uint256 public constant BPS = 10_000;

    uint256 public feeBps;
    address public feeSink;

    constructor(
        uint256 feeBps_,
        address feeSink_
    ) ERC20("SenderSurcharge", "SUR") {
        feeBps = feeBps_;
        feeSink = feeSink_;
    }

    function mint(
        address to,
        uint256 value
    ) external {
        _mint(to, value);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        uint256 fee = (amount * feeBps) / BPS;
        if (fee > 0) _transfer(msg.sender, feeSink, fee);
        return true;
    }
}
