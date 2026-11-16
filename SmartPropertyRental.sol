// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SmartPropertyRental
 * @notice Educational example for SmartLiving Property.
 *         Deposit and rent are paid in native ETH.
 *         Deploy on Remix VM or a testnet first; not audited for production.
 */
contract SmartPropertyRental {
    uint256 public propertyCount;
    uint256 public agreementCount;
    bool private entered;

    struct Property {
        address payable owner;
        string description;
        uint256 monthlyRentWei;
        uint256 securityDepositWei;
        bool exists;
    }

    struct Agreement {
        uint256 propertyId;
        address payable owner;
        address payable tenant;
        address arbitrator;
        uint256 startDate;
        uint256 endDate;
        string terms;
        bool ownerConfirmed;
        bool tenantConfirmed;
        bool depositPaid;
        bool closed;
        bool disputeOpen;
        bool settlementProposed;
        uint256 proposedDeduction;
        string deductionReason;
        uint256 rentPaymentsCount;
    }

    mapping(uint256 => Property) public properties;
    mapping(uint256 => Agreement) private agreements;
    mapping(uint256 => mapping(uint256 => bool)) public rentPeriodPaid;

    event PropertyRegistered(uint256 indexed propertyId, address indexed owner);
    event AgreementCreated(uint256 indexed agreementId, uint256 indexed propertyId, address indexed tenant);
    event AgreementConfirmed(uint256 indexed agreementId, address indexed signer);
    event SecurityDeposited(uint256 indexed agreementId, address indexed tenant, uint256 amount);
    event RentPaid(uint256 indexed agreementId, uint256 indexed period, uint256 amount);
    event SettlementProposed(uint256 indexed agreementId, uint256 deduction, string reason);
    event DisputeOpened(uint256 indexed agreementId, address indexed openedBy, string reason);
    event DisputeResolved(uint256 indexed agreementId, uint256 approvedDeduction, string reason);
    event DepositRefunded(uint256 indexed agreementId, uint256 refund, uint256 deduction);

    modifier nonReentrant() {
        require(!entered, "Reentrancy blocked");
        entered = true;
        _;
        entered = false;
    }

    modifier agreementExists(uint256 agreementId) {
        require(agreementId > 0 && agreementId <= agreementCount, "Agreement not found");
        _;
    }

    /// @param monthlyRentWei Rental amount in wei (1 ETH = 10^18 wei).
    /// @param securityDepositWei Deposit amount in wei.
    function registerProperty(
        string calldata description,
        uint256 monthlyRentWei,
        uint256 securityDepositWei
    ) external returns (uint256 propertyId) {
        require(bytes(description).length > 0, "Description required");
        require(monthlyRentWei > 0, "Rent must be positive");
        require(securityDepositWei > 0, "Deposit must be positive");
        propertyId = ++propertyCount;
        properties[propertyId] = Property(
            payable(msg.sender), description, monthlyRentWei, securityDepositWei, true
        );
        emit PropertyRegistered(propertyId, msg.sender);
    }

    /// @dev Arbitrator must be an independent wallet agreed by both parties.
    ///      Dates are Unix timestamps in seconds.
    function createAgreement(
        uint256 propertyId,
        address payable tenant,
        address arbitrator,
        uint256 startDate,
        uint256 endDate,
        string calldata terms
    ) external returns (uint256 agreementId) {
        Property storage p = properties[propertyId];
        require(p.exists, "Property not found");
        require(msg.sender == p.owner, "Only property owner");
        require(tenant != address(0) && tenant != p.owner, "Invalid tenant");
        require(arbitrator != address(0) && arbitrator != p.owner && arbitrator != tenant, "Independent arbitrator required");
        require(startDate < endDate && endDate > block.timestamp, "Invalid dates");
        require(bytes(terms).length > 0, "Terms required");

        agreementId = ++agreementCount;
        Agreement storage a = agreements[agreementId];
        a.propertyId = propertyId;
        a.owner = p.owner;
        a.tenant = tenant;
        a.arbitrator = arbitrator;
        a.startDate = startDate;
        a.endDate = endDate;
        a.terms = terms;
        emit AgreementCreated(agreementId, propertyId, tenant);
    }

    /// @notice Both parties confirm separately by signing transactions with their wallets.
    function confirmAgreement(uint256 agreementId) external agreementExists(agreementId) {
        Agreement storage a = agreements[agreementId];
        require(!a.closed && !a.depositPaid, "Confirmation locked");
        require(msg.sender == a.owner || msg.sender == a.tenant, "Not a party");
        if (msg.sender == a.owner) {
            require(!a.ownerConfirmed, "Owner already confirmed");
            a.ownerConfirmed = true;
        } else {
            require(!a.tenantConfirmed, "Tenant already confirmed");
            a.tenantConfirmed = true;
        }
        emit AgreementConfirmed(agreementId, msg.sender);
    }

    /// @notice Tenant locks exactly the required ETH deposit in this contract.
    function depositSecurity(uint256 agreementId) external payable agreementExists(agreementId) {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.tenant, "Only tenant");
        require(a.ownerConfirmed && a.tenantConfirmed, "Both must confirm");
        require(!a.closed && !a.depositPaid, "Deposit not available");
        require(block.timestamp < a.endDate, "Agreement already ended");
        uint256 requiredDeposit = properties[a.propertyId].securityDepositWei;
        require(msg.value == requiredDeposit, "Wrong deposit amount");
        a.depositPaid = true;
        emit SecurityDeposited(agreementId, msg.sender, msg.value);
    }

    /// @notice Pay one rent period. Period is a 1-based index, e.g. 1, 2, 3.
    ///         Rent goes directly to the owner, not to the security deposit pool.
    function payRent(uint256 agreementId, uint256 period)
        external payable agreementExists(agreementId) nonReentrant
    {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.tenant, "Only tenant");
        require(a.depositPaid && !a.closed, "Agreement not active");
        require(period > 0 && !rentPeriodPaid[agreementId][period], "Period already paid or invalid");
        uint256 rent = properties[a.propertyId].monthlyRentWei;
        require(msg.value == rent, "Wrong rent amount");
        rentPeriodPaid[agreementId][period] = true;
        a.rentPaymentsCount++;
        (bool sent, ) = a.owner.call{value: msg.value}("");
        require(sent, "Rent transfer failed");
        emit RentPaid(agreementId, period, msg.value);
    }

    /// @notice Owner records inspection outcome and any proposed deduction.
    ///         Tenant must accept; otherwise the arbitrator can resolve a dispute.
    function proposeSettlement(uint256 agreementId, uint256 deduction, string calldata reason)
        external agreementExists(agreementId)
    {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.owner, "Only owner");
        _requireReadyForSettlement(a);
        require(!a.disputeOpen, "Dispute pending");
        require(deduction <= properties[a.propertyId].securityDepositWei, "Deduction too large");
        require(deduction == 0 || bytes(reason).length > 0, "Deduction reason required");
        a.settlementProposed = true;
        a.proposedDeduction = deduction;
        a.deductionReason = reason;
        emit SettlementProposed(agreementId, deduction, reason);
    }

    /// @notice Tenant accepts proposed deduction and gets the remaining deposit.
    function approveAndRefund(uint256 agreementId)
        external agreementExists(agreementId) nonReentrant
    {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.tenant, "Only tenant");
        _requireReadyForSettlement(a);
        require(a.settlementProposed && !a.disputeOpen, "No acceptable proposal");
        _paySettlement(agreementId, a.proposedDeduction);
    }

    /// @notice Either party can initiate review once the lease has ended.
    function openDispute(uint256 agreementId, string calldata reason)
        external agreementExists(agreementId)
    {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.owner || msg.sender == a.tenant, "Not a party");
        _requireReadyForSettlement(a);
        require(!a.disputeOpen, "Dispute already open");
        require(bytes(reason).length > 0, "Dispute reason required");
        a.disputeOpen = true;
        emit DisputeOpened(agreementId, msg.sender, reason);
    }

    /// @notice Independent arbitrator approves final deduction and pays both parties.
    function resolveDispute(
        uint256 agreementId,
        uint256 approvedDeduction,
        string calldata reason
    ) external agreementExists(agreementId) nonReentrant {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.arbitrator, "Only arbitrator");
        _requireReadyForSettlement(a);
        require(a.disputeOpen, "No dispute open");
        require(approvedDeduction <= properties[a.propertyId].securityDepositWei, "Deduction too large");
        require(bytes(reason).length > 0, "Decision reason required");
        emit DisputeResolved(agreementId, approvedDeduction, reason);
        _paySettlement(agreementId, approvedDeduction);
    }

    function getAgreement(uint256 agreementId)
        external view agreementExists(agreementId) returns (Agreement memory)
    {
        return agreements[agreementId];
    }

    function getDepositBalance(uint256 agreementId)
        external view agreementExists(agreementId) returns (uint256)
    {
        Agreement storage a = agreements[agreementId];
        return a.depositPaid && !a.closed
            ? properties[a.propertyId].securityDepositWei : 0;
    }

    function _requireReadyForSettlement(Agreement storage a) internal view {
        require(a.depositPaid && !a.closed, "No refundable deposit");
        require(block.timestamp >= a.endDate, "Lease not yet ended");
    }

    function _paySettlement(uint256 agreementId, uint256 deduction) internal {
        Agreement storage a = agreements[agreementId];
        uint256 depositAmount = properties[a.propertyId].securityDepositWei;
        require(deduction <= depositAmount, "Deduction too large");
        uint256 refund = depositAmount - deduction;

        // Checks-effects-interactions and reentrancy guard.
        a.closed = true;
        a.depositPaid = false;
        a.disputeOpen = false;

        if (refund > 0) {
            (bool refunded, ) = a.tenant.call{value: refund}("");
            require(refunded, "Tenant refund failed");
        }
        if (deduction > 0) {
            (bool deducted, ) = a.owner.call{value: deduction}("");
            require(deducted, "Owner payout failed");
        }
        emit DepositRefunded(agreementId, refund, deduction);
    }
}
