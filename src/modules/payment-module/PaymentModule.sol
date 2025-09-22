// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Lockup } from "@sablier/lockup/src/types/DataTypes.sol";
import { ISablierLockup } from "@sablier/lockup/src/interfaces/ISablierLockup.sol";
import { UD60x18 } from "@prb/math/src/ud60x18/ValueType.sol";

import { StreamManager } from "./sablier-lockup/StreamManager.sol";
import { Types } from "./libraries/Types.sol";
import { Errors } from "./libraries/Errors.sol";
import { IPaymentModule } from "./interfaces/IPaymentModule.sol";
import { Helpers } from "./libraries/Helpers.sol";

/// @title PaymentModule
/// @notice See the documentation in {IPaymentModule}
contract PaymentModule is IPaymentModule, StreamManager, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    /// @dev Version identifier for the current implementation of the contract
    string public constant VERSION = "1.0.0";

    /// @dev The address of the native token (ETH) following the ERC-7528 standard
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*//////////////////////////////////////////////////////////////////////////
                            NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:werk.storage.PaymentModule
    struct PaymentModuleStorage {
        /// @notice Payment requests details mapped by the `id` payment request ID
        mapping(uint256 id => Types.PaymentRequest) requests;
        /// @notice Counter to keep track of the next ID used to create a new payment request
        uint256 nextRequestId;
    }

    // keccak256(abi.encode(uint256(keccak256("werk.storage.PaymentModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAYMENT_MODULE_STORAGE_LOCATION =
        0x69242e762af97d314866e2398c5d39d67197520146b0e3b1471c97ebda768e00;

    /// @dev Retrieves the storage of the {PaymentModule} contract
    function _getPaymentModuleStorage() internal pure returns (PaymentModuleStorage storage $) {
        assembly {
            $.slot := PAYMENT_MODULE_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Deploys and locks the implementation contract
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() StreamManager() {
        _disableInitializers();
    }

    /// @dev Initializes the proxy and the {Ownable} contract
    function initialize(
        ISablierLockup _sablierLinear,
        address _initialOwner,
        address _brokerAccount,
        UD60x18 _brokerFee
    )
        public
        initializer
    {
        __StreamManager_init(_sablierLinear, _initialOwner, _brokerAccount, _brokerFee);
        __UUPSUpgradeable_init();

        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        // Start the first payment request ID from 1
        $.nextRequestId = 1;
    }

    /// @dev Allows only the owner to upgrade the contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentModule
    function getRequest(uint256 requestId) external view returns (Types.PaymentRequest memory request) {
        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        return $.requests[requestId];
    }

    /// @inheritdoc IPaymentModule
    function statusOf(uint256 requestId) public view returns (Types.Status status) {
        status = _statusOf(requestId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPaymentModule
    function createRequest(Types.PaymentRequest calldata request) public returns (uint256 requestId) {
        // Checks: the recipient address is not the zero address
        if (request.recipient == address(0)) {
            revert Errors.InvalidZeroAddressRecipient();
        }

        // Checks: the amount is non-zero
        if (request.config.amount == 0) {
            revert Errors.ZeroPaymentAmount();
        }

        // Checks: the start time is stricly lower than the end time
        if (request.startTime > request.endTime) {
            revert Errors.StartTimeGreaterThanEndTime();
        }

        // Checks: end time is not in the past
        uint40 currentTime = uint40(block.timestamp);
        if (currentTime >= request.endTime) {
            revert Errors.EndTimeInThePast();
        }

        // Checks: the recurrence type is not equal to one-off if dealing with a tranched stream-based request
        if (request.config.method == Types.Method.TranchedStream) {
            // The recurrence cannot be set to one-off
            if (request.config.recurrence == Types.Recurrence.OneOff) {
                revert Errors.TranchedStreamInvalidOneOffRecurence();
            }
        }

        // Checks: the payment method is transfer-based if the recurrence type is `Custom`
        if (request.config.recurrence == Types.Recurrence.Custom) {
            if (request.config.method != Types.Method.Transfer) {
                revert Errors.OnlyTransferAllowedForCustomRecurrence();
            }
        }

        // Checks: the asset is not the native token if dealing with either a linear or tranched stream-based payment
        if (request.config.method != Types.Method.Transfer) {
            if (request.config.asset == NATIVE_TOKEN) {
                revert Errors.OnlyERC20StreamsAllowed();
            }
        }

        // Effects: set the number of payments based on the recurrence type
        //
        // Notes:
        // - For `Custom` recurrence, the number of payments is set to the one provided in the request config `paymentsLeft` input
        // - The number of payments is validated only for requests with a payment method set to Tranched Stream or recurring Transfer
        // - There should be only one payment when dealing with a one-off transfer-based request
        // - When dealing with a recurring transfer, the number of payments must be calculated based
        // on the payment interval (endTime - startTime) and recurrence type
        uint40 numberOfPayments;
        if (request.config.recurrence == Types.Recurrence.Custom) {
            numberOfPayments = request.config.paymentsLeft;
        } else {
            numberOfPayments = 1;

            // Validates the payment request interval (endTime - startTime) and returns the number of payments
            // based on the payment method, interval and recurrence type only if the recurrence is not `Custom`
            if (
                request.config.method != Types.Method.LinearStream
                    && request.config.recurrence != Types.Recurrence.OneOff
            ) {
                numberOfPayments = _checkIntervalPayments({
                    recurrence: request.config.recurrence,
                    startTime: request.startTime,
                    endTime: request.endTime
                });
            }

            // Set the number of payments back to one if dealing with a tranched-based request
            // The `_checkIntervalPayment` method is still called for a tranched-based request just
            // to validate the interval and ensure it can support multiple payments based on the chosen recurrence
            if (request.config.method == Types.Method.TranchedStream) numberOfPayments = 1;
        }

        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        // Get the next payment request ID
        requestId = $.nextRequestId;

        // Effects: create the payment request
        $.requests[requestId] = Types.PaymentRequest({
            wasCanceled: false,
            wasAccepted: false,
            startTime: request.startTime,
            endTime: request.endTime,
            recipient: request.recipient,
            config: Types.Config({
                canExpire: request.config.canExpire,
                recurrence: request.config.recurrence,
                method: request.config.method,
                paymentsLeft: numberOfPayments,
                amount: request.config.amount,
                asset: request.config.asset,
                streamId: 0
            }),
            sender: request.sender
        });

        // Effects: increment the next payment request ID
        // Use unchecked because the request id cannot realistically overflow
        unchecked {
            ++$.nextRequestId;
        }

        // Log the payment request creation
        emit RequestCreated({
            requestId: requestId,
            sender: request.sender,
            recipient: request.recipient,
            startTime: request.startTime,
            endTime: request.endTime,
            config: request.config
        });
    }

    /// @inheritdoc IPaymentModule
    function payRequest(uint256 requestId) external payable {
        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        // Load the payment request state from storage
        Types.PaymentRequest storage request = $.requests[requestId];

        // Checks: the payment request is not null
        if (request.recipient == address(0)) {
            revert Errors.NullRequest();
        }

        // Retrieve the request status
        Types.Status requestStatus = _statusOf(requestId);

        // Checks: the payment request is not expired
        if (requestStatus == Types.Status.Expired) {
            revert Errors.RequestExpired();
        }

        // Checks: the payment request is not already paid or canceled
        // Note: for stream-based requests the `status` changes to `Paid` only after the funds are fully streamed
        if (
            requestStatus == Types.Status.Paid
                || (requestStatus == Types.Status.Ongoing && request.config.streamId != 0)
        ) {
            revert Errors.RequestPaid();
        } else if (requestStatus == Types.Status.Canceled) {
            revert Errors.RequestCanceled();
        }

        // A payment request can have request.sender already initialized in cases where the payer of the request is known from the start
        // If request.sender is address(0) initialize it with msg.sender
        if (request.sender == address(0)) {
            request.sender = msg.sender;
        }

        // Effects: decrease the number of payments left
        // Using unchecked because the number of payments left cannot underflow:
        // - For transfer-based requests, the status will be updated to `Paid` when `paymentsLeft` reaches zero;
        // - For stream-based requests, `paymentsLeft` is validated before decrementing;
        uint40 paymentsLeft;
        unchecked {
            paymentsLeft = request.config.paymentsLeft - 1;
            $.requests[requestId].config.paymentsLeft = paymentsLeft;
        }

        // Effects: mark the payment request as accepted
        $.requests[requestId].wasAccepted = true;

        // Handle the payment workflow depending on the payment method type
        if (request.config.method == Types.Method.Transfer) {
            // Effects: pay the request and update its status to `Paid` or `Ongoing` depending on the payment type
            _payByTransfer(request);
        } else {
            uint256 streamId;

            // Check to see whether the request must be paid through a linear or tranched stream
            if (request.config.method == Types.Method.LinearStream) {
                streamId = _payByLinearStream(request);
            } else {
                streamId = _payByTranchedStream(request);
            }

            // Effects: set the stream ID of the payment request
            $.requests[requestId].config.streamId = streamId;
        }

        // Log the payment transaction
        emit RequestPaid({ requestId: requestId, payer: msg.sender, config: $.requests[requestId].config });
    }

    /// @inheritdoc IPaymentModule
    function cancelRequest(uint256 requestId) external {
        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        // Load the payment request state from storage
        Types.PaymentRequest memory request = $.requests[requestId];

        // Checks: the payment request exists
        if (request.recipient == address(0)) {
            revert Errors.NullRequest();
        }

        // Retrieve the request status
        Types.Status requestStatus = _statusOf(requestId);

        // Checks: the payment request is already paid or canceled
        if (requestStatus == Types.Status.Paid) {
            revert Errors.RequestPaid();
        } else if (requestStatus == Types.Status.Canceled) {
            revert Errors.RequestCanceled();
        }

        // Checks: `msg.sender` is the recipient or the sender if the payment request status is `Pending`
        if (requestStatus == Types.Status.Pending) {
            if (msg.sender != request.recipient && msg.sender != request.sender) {
                revert Errors.OnlyRequestSenderOrRecipient();
            }
        }
        // Checks: `msg.sender` is the recipient or the sender if the payment request status is `Ongoing`
        // and the payment method is transfer-based
        else if (request.config.method == Types.Method.Transfer) {
            if (msg.sender != request.recipient && msg.sender != request.sender) {
                revert Errors.OnlyRequestSenderOrRecipient();
            }
        }
        // Checks, Effects, Interactions: cancel the stream if payment request has already been accepted
        // and the payment method is either linear or tranched stream
        //
        // Notes:
        // - Once a linear or tranched stream is created, the `msg.sender` is checked in the
        // {SablierV2Lockup} `cancel` method
        // - A linear or tranched stream MUST be canceled by calling the `cancel` method on the according
        // {ISablierV2Lockup} contract
        else {
            _cancelStream({ streamId: request.config.streamId });
        }

        // Effects: mark the payment request as canceled
        $.requests[requestId].wasCanceled = true;

        // Log the payment request cancelation
        emit RequestCanceled(requestId);
    }

    /// @inheritdoc IPaymentModule
    function withdrawRequestStream(uint256 requestId) public returns (uint128 withdrawnAmount) {
        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        // Load the payment request state from storage
        Types.PaymentRequest memory request = $.requests[requestId];

        // Check, Effects, Interactions: withdraw from the stream
        withdrawnAmount = _withdrawStream({ streamId: request.config.streamId, to: request.recipient });

        // Log the stream withdrawal
        emit RequestStreamWithdrawn(requestId, withdrawnAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    INTERNAL-METHODS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Pays the `id` request  by transfer
    function _payByTransfer(Types.PaymentRequest memory request) internal {
        // Check if the payment must be done in native token (ETH) or an ERC-20 token
        if (request.config.asset == NATIVE_TOKEN) {
            // Checks: the payment amount matches the request value
            if (msg.value < request.config.amount) {
                revert Errors.PaymentAmountLessThanRequestedAmount({ amount: request.config.amount });
            }

            // Interactions: pay the recipient with native token (ETH)
            (bool success,) = payable(request.recipient).call{ value: request.config.amount }("");
            if (!success) revert Errors.NativeTokenPaymentFailed();
        } else {
            // Interactions: pay the recipient with the ERC-20 token
            IERC20(request.config.asset).safeTransferFrom({
                from: msg.sender,
                to: request.recipient,
                value: request.config.amount
            });
        }
    }

    /// @dev Create the linear stream payment
    function _payByLinearStream(Types.PaymentRequest memory request) internal returns (uint256 streamId) {
        streamId = _createLinearStream({
            asset: IERC20(request.config.asset),
            totalAmount: request.config.amount,
            startTime: request.startTime,
            endTime: request.endTime,
            recipient: request.recipient
        });
    }

    /// @dev Create the tranched stream payment
    function _payByTranchedStream(Types.PaymentRequest memory request) internal returns (uint256 streamId) {
        uint40 numberOfTranches =
            Helpers.computeNumberOfPayments(request.config.recurrence, request.endTime - request.startTime);

        streamId = _createTranchedStream({
            asset: IERC20(request.config.asset),
            totalAmount: request.config.amount,
            startTime: request.startTime,
            recipient: request.recipient,
            numberOfTranches: numberOfTranches,
            recurrence: request.config.recurrence
        });
    }

    /// @notice Calculates the number of payments to be made for a recurring transfer and tranched stream-based request
    /// @dev Reverts if the number of payments is zero, indicating that either the interval or recurrence type was set incorrectly
    function _checkIntervalPayments(
        Types.Recurrence recurrence,
        uint40 startTime,
        uint40 endTime
    )
        internal
        pure
        returns (uint40 numberOfPayments)
    {
        // Checks: the request payment interval matches the recurrence type
        // This cannot underflow as the start time is stricly lower than the end time when this call executes
        uint40 interval;
        unchecked {
            interval = endTime - startTime;
        }

        // Check and calculate the expected number of payments based on the recurrence and payment interval
        numberOfPayments = Helpers.computeNumberOfPayments(recurrence, interval);

        // Revert if there are zero payments to be made since the payment method due to invalid interval and recurrence type
        if (numberOfPayments == 0) {
            revert Errors.PaymentIntervalTooShortForSelectedRecurrence();
        }
    }

    /// @notice Retrieves the status of the `requestId` payment request
    /// Note:
    /// - The status of a payment request is determined by the `wasCanceled` and `wasAccepted` flags and:
    /// - For a stream-based payment request, by the status of the underlying stream;
    /// - For a transfer-based payment request, by the number of payments left;
    function _statusOf(uint256 requestId) internal view returns (Types.Status status) {
        // Retrieve the contract storage
        PaymentModuleStorage storage $ = _getPaymentModuleStorage();

        // Load the payment request state from storage
        Types.PaymentRequest memory request = $.requests[requestId];

        // Check if the payment request has expired (if it's expirable) or is pending
        if (!request.wasAccepted && !request.wasCanceled) {
            if (request.config.canExpire && uint40(block.timestamp) > request.endTime) {
                return Types.Status.Expired;
            }
            return Types.Status.Pending;
        }

        // Check if dealing with a stream-based payment request
        if (request.config.streamId != 0) {
            Lockup.Status statusOfStream = statusOfStream({ streamId: request.config.streamId });

            if (statusOfStream == Lockup.Status.SETTLED) {
                return Types.Status.Paid;
            } else if (statusOfStream == Lockup.Status.DEPLETED) {
                // Retrieve the total streamed amount until now
                uint128 streamedAmount = streamedAmountOf({ streamId: request.config.streamId });

                // Check if the payment request is canceled or paid
                return streamedAmount < request.config.amount ? Types.Status.Canceled : Types.Status.Paid;
            } else if (statusOfStream == Lockup.Status.CANCELED) {
                return Types.Status.Canceled;
            } else {
                return Types.Status.Ongoing;
            }
        }

        // Otherwise, the payment request is transfer-based
        if (request.wasCanceled) {
            return Types.Status.Canceled;
        } else if (request.config.paymentsLeft == 0) {
            return Types.Status.Paid;
        }

        return Types.Status.Ongoing;
    }
}
