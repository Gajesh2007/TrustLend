// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/TrustLend.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock Reclaim contract
contract MockReclaim {
    function verifyProof(Reclaim.Proof memory) public pure {}
}

// Mock ERC20 token
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract UnderCollateralizedLendingTest is Test {
    UnderCollateralizedLending lending;
    MockReclaim mockReclaim;
    MockERC20 mockToken;

    address owner = address(1);
    address borrower = address(2);
    address lender = address(3);

    function setUp() public {
        vm.startPrank(owner);
        string[] memory providersHashes = new string[](1);
        providersHashes[0] = "mockProviderHash";
        lending = new UnderCollateralizedLending(providersHashes);
        mockReclaim = new MockReclaim();
        mockToken = new MockERC20("Mock Token", "MTK");

        // Set mock Reclaim address
        vm.store(
            address(lending),
            bytes32(uint256(0)), // Assumes reclaimAddress is the first storage slot
            bytes32(uint256(uint160(address(mockReclaim))))
        );
        
        // Distribute tokens
        mockToken.transfer(borrower, 100000 * 10**18);
        mockToken.transfer(lender, 100000 * 10**18);

        vm.stopPrank();
    }

    function testRequestLoan() public {
        vm.startPrank(borrower);
        mockToken.approve(address(lending), 1000 * 10**18);
        lending.requestLoan(10000 * 10**18, 500, 30 days, address(mockToken), 1000 * 10**18);
        vm.stopPrank();

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, 10000 * 10**18);
        assertEq(loan.interestRate, 500);
        assertEq(loan.duration, 30 days);
        assertEq(loan.collateralToken, address(mockToken));
        assertEq(loan.collateralAmount, 1000 * 10**18);
        assertEq(uint(loan.status), uint(UnderCollateralizedLending.LoanStatus.Requested));
    }

    function testCancelLoan() public {
        testRequestLoan();

        vm.prank(borrower);
        lending.cancelLoan(0);

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(uint(loan.status), uint(UnderCollateralizedLending.LoanStatus.Cancelled));
        assertEq(mockToken.balanceOf(borrower), 100000 * 10**18);
    }

    function testPlaceOffer() public {
        testRequestLoan();

        vm.prank(lender);
        lending.placeOffer(0, 400);

        UnderCollateralizedLending.Offer memory offer = lending.getLoanOffers(0)[0];
        assertEq(offer.lender, lender);
        assertEq(offer.interestRate, 400);
    }

    function testAcceptOffer() public {
        testPlaceOffer();

        vm.startPrank(borrower);
        mockToken.approve(address(lending), 10000 * 10**18);
        lending.acceptOffer(0, 0);
        vm.stopPrank();

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(loan.lender, lender);
        assertEq(loan.interestRate, 400);
        assertEq(uint(loan.status), uint(UnderCollateralizedLending.LoanStatus.Active));
        assertEq(mockToken.balanceOf(borrower), 110000 * 10**18);
    }

    function testRepayLoan() public {
        testAcceptOffer();

        uint256 repaymentAmount = lending.calculateRepaymentAmount(0);

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(borrower);
        mockToken.approve(address(lending), repaymentAmount);
        lending.repayLoan(0);
        vm.stopPrank();

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(uint(loan.status), uint(UnderCollateralizedLending.LoanStatus.Repaid));
        assertEq(mockToken.balanceOf(lender), 100000 * 10**18 + repaymentAmount - 10000 * 10**18);
        assertEq(mockToken.balanceOf(borrower), 110000 * 10**18 - repaymentAmount + 1000 * 10**18);
    }

    function testLiquidateLoan() public {
        testAcceptOffer();

        vm.warp(block.timestamp + 31 days);

        vm.prank(lender);
        lending.liquidateLoan(0);

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(uint(loan.status), uint(UnderCollateralizedLending.LoanStatus.Liquidated));
        assertEq(mockToken.balanceOf(lender), 91000 * 10**18);
    }

    function testExtendLoanDuration() public {
        testAcceptOffer();

        vm.prank(lender);
        lending.extendLoanDuration(0, 45 days);

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(loan.duration, 45 days);
    }

    function testUpdateCreditScore() public {
        Reclaim.Proof memory proof;
        proof.claimInfo.provider = "mockProviderHash";
        proof.claimInfo.context = '{"CreditScore":"750"}';

        vm.prank(borrower);
        lending.updateCreditScore(proof);

        assertEq(lending.getUserCreditScore(borrower), 750);
    }

    function testAddCredential() public {
        vm.prank(owner);
        lending.setCredentialType("mockProviderHash", "TwitterHandle");

        Reclaim.Proof memory proof;
        proof.claimInfo.provider = "mockProviderHash";
        proof.claimInfo.context = '{"TwitterHandle":"@testuser"}';

        vm.prank(borrower);
        lending.addCredential(proof, "mockProviderHash");

        assertEq(lending.getUserCredential(borrower, "mockProviderHash"), "@testuser");
    }

    function testPause() public {
        vm.prank(owner);
        lending.pause();

        vm.expectRevert("Pausable: paused");
        vm.prank(borrower);
        lending.requestLoan(10000 * 10**18, 500, 30 days, address(mockToken), 1000 * 10**18);
    }

    function testUnpause() public {
        testPause();

        vm.prank(owner);
        lending.unpause();

        vm.startPrank(borrower);
        mockToken.approve(address(lending), 1000 * 10**18);
        lending.requestLoan(10000 * 10**18, 500, 30 days, address(mockToken), 1000 * 10**18);
        vm.stopPrank();

        UnderCollateralizedLending.Loan memory loan = lending.getLoan(0);
        assertEq(loan.borrower, borrower);
    }
}