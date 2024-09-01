// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TrustLend.sol";

contract TrustLendScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string[] memory providersHashes = new string[](1);
        providersHashes[0] = "example_provider_hash";

        UnderCollateralizedLending lendingContract = new UnderCollateralizedLending(providersHashes);

        vm.stopBroadcast();
    }
}