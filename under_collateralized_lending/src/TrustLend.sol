// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@reclaimprotocol/verifier-solidity-sdk/contracts/Reclaim.sol";
import "@reclaimprotocol/verifier-solidity-sdk/contracts/Addresses.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract UnderCollateralizedLending is Ownable, ReentrancyGuard, Pausable {
    address public reclaimAddress;
    string[] public providersHashes;

    struct Loan {
        address borrower;
        address lender;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        uint256 collateralAmount;
        LoanStatus status;
        uint256 startTime;
    }

    struct User {
        uint256 creditScore;
        mapping(uint256 => string) credentials;
        bool isVerified;
    }

    enum LoanStatus { Requested, Active, Repaid, Defaulted, Liquidated }

    mapping(address => User) public users;
    mapping(uint256 => string) public credentialTypes;
    mapping(uint256 => Loan) public loans;
    uint256 public nextLoanId;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amount, uint256 interestRate, uint256 duration);
    event LoanFunded(uint256 indexed loanId, address indexed lender);
    event LoanRepaid(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);
    event LoanLiquidated(uint256 indexed loanId);
    event CreditScoreUpdated(address indexed user, uint256 newScore);
    event CredentialAdded(address indexed user, uint256 credentialType, string credential);

    constructor(string[] memory _providersHashes) {
        providersHashes = _providersHashes;
        reclaimAddress = Addresses.POLYGON_MUMBAI_TESTNET; // TODO: Replace with the network you are deploying on
    }

    function updateCreditScore(Reclaim.Proof memory proof) public whenNotPaused {
        Reclaim(reclaimAddress).verifyProof(proof);
        string memory creditScoreStr = extractFieldFromContext(proof.claimInfo.context, '"CreditScore":"');
        uint256 newCreditScore = stringToUint(creditScoreStr);
        users[msg.sender].creditScore = newCreditScore;
        emit CreditScoreUpdated(msg.sender, newCreditScore);
    }

    function addCredential(Reclaim.Proof memory proof, uint256 credentialType) public whenNotPaused {
        Reclaim(reclaimAddress).verifyProof(proof);
        string memory credentialTypeStr = credentialTypes[credentialType];
        require(bytes(credentialTypeStr).length > 0, "Invalid credential type");
        string memory credential = extractFieldFromContext(proof.claimInfo.context, string(abi.encodePacked('"', credentialTypeStr, '":"')));
        users[msg.sender].credentials[credentialType] = credential;
        emit CredentialAdded(msg.sender, credentialType, credential);
        updateVerificationStatus(msg.sender);
    }

    function setCredentialType(uint256 typeId, string memory typeName) public onlyOwner {
        credentialTypes[typeId] = typeName;
    }

    function requestLoan(uint256 amount, uint256 interestRate, uint256 duration, uint256 collateralAmount) public whenNotPaused {
        require(users[msg.sender].isVerified, "User not verified");
        require(users[msg.sender].creditScore >= getMinimumCreditScore(), "Credit score too low");

        uint256 loanId = nextLoanId++;
        loans[loanId] = Loan({
            borrower: msg.sender,
            lender: address(0),
            amount: amount,
            interestRate: interestRate,
            duration: duration,
            collateralAmount: collateralAmount,
            status: LoanStatus.Requested,
            startTime: 0
        });

        emit LoanRequested(loanId, msg.sender, amount, interestRate, duration);
    }

    function fundLoan(uint256 loanId) public payable whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Requested, "Loan not available");
        require(msg.value == loan.amount, "Incorrect loan amount");

        loan.lender = msg.sender;
        loan.status = LoanStatus.Active;
        loan.startTime = block.timestamp;

        payable(loan.borrower).transfer(loan.amount);

        emit LoanFunded(loanId, msg.sender);
    }

    function repayLoan(uint256 loanId) public payable whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Active, "Loan not active");
        require(msg.sender == loan.borrower, "Only borrower can repay");

        uint256 repaymentAmount = calculateRepaymentAmount(loanId);
        require(msg.value == repaymentAmount, "Incorrect repayment amount");

        loan.status = LoanStatus.Repaid;
        payable(loan.lender).transfer(repaymentAmount);

        emit LoanRepaid(loanId);
    }

    function liquidateLoan(uint256 loanId) public whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Active, "Loan not active");
        require(block.timestamp > loan.startTime + loan.duration, "Loan not yet defaulted");

        loan.status = LoanStatus.Liquidated;
        // TODO: Implement collateral liquidation logic

        emit LoanLiquidated(loanId);
    }

    function calculateRepaymentAmount(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 interest = (loan.amount * loan.interestRate * loan.duration) / (365 days * 10000);
        return loan.amount + interest;
    }

    function getMinimumCreditScore() public pure returns (uint256) {
        return 650; // Example minimum credit score
    }

    function updateVerificationStatus(address user) internal {
        // TODO: Implement logic to check if user has all required credentials
        users[user].isVerified = true; // Simplified for this example
    }

    function extractFieldFromContext(string memory data, string memory target) public pure returns (string memory) {
        bytes memory dataBytes = bytes(data);
        bytes memory targetBytes = bytes(target);

        uint256 i = indexOf(dataBytes, targetBytes);
        if (i == type(uint256).max) return "";

        i += targetBytes.length;
        uint256 j = i;
        while (j < dataBytes.length && dataBytes[j] != '"') j++;

        bytes memory result = new bytes(j - i);
        for (uint256 k = 0; k < j - i; k++) {
            result[k] = dataBytes[i + k];
        }

        return string(result);
    }

    function stringToUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 c = uint256(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }

    function indexOf(bytes memory haystack, bytes memory needle) internal pure returns (uint256) {
        for (uint256 i = 0; i < haystack.length - needle.length + 1; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }
}