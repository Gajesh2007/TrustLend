// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./@reclaimprotocol/Reclaim.sol";
import "./@reclaimprotocol/Addresses.sol";
import "./@reclaimprotocol/Claims.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UnderCollateralizedLending is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public reclaimAddress;
    string[] public allowedProvidersHashes;

    struct Loan {
        address borrower;
        address lender;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        address collateralToken;
        uint256 collateralAmount;
        LoanStatus status;
        uint256 startTime;
    }

    struct User {
        uint256 creditScore;
        mapping(string => string) credentials;
    }

    struct Offer {
        address lender;
        uint256 interestRate;
    }

    enum LoanStatus { Requested, Active, Repaid, Defaulted, Liquidated, Cancelled }

    mapping(address => User) public users;
    mapping(string => string) public credentialTypes;
    mapping(uint256 => Loan) public loans;
    mapping(uint256 => Offer[]) public loanOffers;
    uint256 public nextLoanId;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 amount, uint256 interestRate, uint256 duration, address collateralToken, uint256 collateralAmount);
    event LoanFunded(uint256 indexed loanId, address indexed lender);
    event LoanRepaid(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);
    event LoanLiquidated(uint256 indexed loanId);
    event LoanCancelled(uint256 indexed loanId);
    event CreditScoreUpdated(address indexed user, uint256 newScore);
    event CredentialAdded(address indexed user, string credentialType, string credential);
    event OfferPlaced(uint256 indexed loanId, address indexed lender, uint256 interestRate);
    event LoanExtended(uint256 indexed loanId, uint256 newDuration);

    constructor(string[] memory _providersHashes) Ownable(msg.sender) {
        allowedProvidersHashes = _providersHashes;
        reclaimAddress = Addresses.BASE_MAINNET;
    }

    function updateCreditScore(Reclaim.Proof memory proof) external whenNotPaused {
        Reclaim(reclaimAddress).verifyProof(proof);
        require(
            keccak256(abi.encodePacked(proof.claimInfo.provider)) == 
            keccak256(abi.encodePacked(allowedProvidersHashes[0])), 
            "Invalid provider"
        );
        string memory creditScoreStr = Claims.extractFieldFromContext(proof.claimInfo.context, '"CreditScore":"');
        uint256 newCreditScore = stringToUint(creditScoreStr);
        users[msg.sender].creditScore = newCreditScore;
        emit CreditScoreUpdated(msg.sender, newCreditScore);
    }

    function addCredential(Reclaim.Proof memory proof, string memory providerHash) external whenNotPaused {
        Reclaim(reclaimAddress).verifyProof(proof);
        require(
            keccak256(abi.encodePacked(proof.claimInfo.provider)) == 
            keccak256(abi.encodePacked(credentialTypes[providerHash])), 
            "Invalid provider"
        );
        string memory credentialTypeStr = credentialTypes[providerHash];
        require(bytes(credentialTypeStr).length > 0, "Invalid credential type");
        string memory credential = Claims.extractFieldFromContext(proof.claimInfo.context, credentialTypeStr);
        users[msg.sender].credentials[providerHash] = credential;
        emit CredentialAdded(msg.sender, providerHash, credential);
    }

    function setCredentialType(string memory providerHash, string memory target) external onlyOwner {
        credentialTypes[providerHash] = target;
    }

    function requestLoan(uint256 amount, uint256 interestRate, uint256 duration, address collateralToken, uint256 collateralAmount) external whenNotPaused {
        uint256 loanId = nextLoanId++;
        loans[loanId] = Loan({
            borrower: msg.sender,
            lender: address(0),
            amount: amount,
            interestRate: interestRate,
            duration: duration,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            status: LoanStatus.Requested,
            startTime: 0
        });

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        emit LoanRequested(loanId, msg.sender, amount, interestRate, duration, collateralToken, collateralAmount);
    }

    function cancelLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        require(msg.sender == loan.borrower, "Only borrower can cancel");
        require(loan.status == LoanStatus.Requested, "Can only cancel requested loans");

        loan.status = LoanStatus.Cancelled;
        IERC20(loan.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        emit LoanCancelled(loanId);
    }

    function placeOffer(uint256 loanId, uint256 interestRate) external whenNotPaused {
        require(loans[loanId].status == LoanStatus.Requested, "Loan not available");
        loanOffers[loanId].push(Offer({
            lender: msg.sender,
            interestRate: interestRate
        }));
        emit OfferPlaced(loanId, msg.sender, interestRate);
    }

    function acceptOffer(uint256 loanId, uint256 offerIndex) external whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        require(msg.sender == loan.borrower, "Only borrower can accept offer");
        require(loan.status == LoanStatus.Requested, "Loan not available");

        Offer memory selectedOffer = loanOffers[loanId][offerIndex];
        loan.lender = selectedOffer.lender;
        loan.interestRate = selectedOffer.interestRate;
        loan.status = LoanStatus.Active;
        loan.startTime = block.timestamp;

        IERC20(loan.collateralToken).safeTransferFrom(loan.lender, loan.borrower, loan.amount);

        emit LoanFunded(loanId, loan.lender);
    }

    function repayLoan(uint256 loanId) external payable whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Active, "Loan not active");
        require(msg.sender == loan.borrower, "Only borrower can repay");

        uint256 repaymentAmount = calculateRepaymentAmount(loanId);
        IERC20(loan.collateralToken).safeTransferFrom(msg.sender, loan.lender, repaymentAmount);

        loan.status = LoanStatus.Repaid;
        IERC20(loan.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        emit LoanRepaid(loanId);
    }

    function liquidateLoan(uint256 loanId) external whenNotPaused nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Active, "Loan not active");
        require(block.timestamp > loan.startTime + loan.duration, "Loan not yet defaulted");

        loan.status = LoanStatus.Liquidated;
        IERC20(loan.collateralToken).safeTransfer(loan.lender, loan.collateralAmount);

        emit LoanLiquidated(loanId);
    }

    function extendLoanDuration(uint256 loanId, uint256 newDuration) external whenNotPaused {
        Loan storage loan = loans[loanId];
        require(msg.sender == loan.lender, "Only lender can extend duration");
        require(loan.status == LoanStatus.Active, "Loan not active");
        require(newDuration > loan.duration, "New duration must be longer");

        loan.duration = newDuration;
        emit LoanExtended(loanId, newDuration);
    }

    function getLoan(uint256 loanId) public view returns (Loan memory) {
        return loans[loanId];
    }

    function getLoanOffers(uint256 loanId) public view returns (Offer[] memory) {
        return loanOffers[loanId];
    }

    function getUserCreditScore(address user) public view returns (uint256) {
        return users[user].creditScore;
    }

    function getUserCredential(address user, string memory providerHash) public view returns (string memory) {
        return users[user].credentials[providerHash];
    }

    function calculateRepaymentAmount(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 interest = (loan.amount * loan.interestRate * loan.duration) / (365 days * 10000);
        return loan.amount + interest;
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

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }
}