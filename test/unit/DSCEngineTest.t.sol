// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";


contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed,btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    //////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;


    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    
    }

    /////////////////
    // Price Tests //
    /////////////////
    
    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        //15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether; 
        //$2,000 / ETH, $100
        uint256 expectedweth = 0.05 ether;
        uint256 actualweth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedweth, actualweth);
    }

     ////////////////////////////
    // depositCollateral Tests //
    ////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }


    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        // 10 ether * 2000 = $20,000
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    /////////////////////////
    // Health Factor Tests //
    /////////////////////////

    function testHealthFactorWithNoDscMinted() public depositedCollateral {
    uint256 healthFactor = dsce.getHealthFactor(USER);
    assertEq(healthFactor, type(uint256).max);
    }

    function testCanRedeemCollateralWithNoDscMinted() public depositedCollateral {
    vm.startPrank(USER);
    dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
    vm.stopPrank();

    assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_ERC20_BALANCE);
    }

    ////////////////////
    // mintDsc Tests  //
    ////////////////////

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
    // $20,000 collateral, 50% threshold => health factor = 10,000 / 20,000 = 0.5e18
    uint256 expectedHealthFactor = 0.5 ether;
    vm.startPrank(USER);
    vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
    dsce.mintDsc(20000 ether);
    vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100 ether);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 100 ether);
    }

    ////////////////////
    // burnDsc Tests  //
    ////////////////////

    function testRevertsIfBurnMoreThanMinted() public {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100 ether);
        dsc.approve(address(dsce), 100 ether);
        dsce.burnDsc(100 ether);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ///////////////////////////

    function testCanRedeemPartOfCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, 1 ether);
        vm.stopPrank();

        assertEq(ERC20Mock(weth).balanceOf(USER), 1 ether);
    }

    function testRevertsIfRedeemBreaksHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        // $10,000 DSC is the max safe mint for $20,000 collateral (health factor = 1.0)
        dsce.mintDsc(10000 ether);
        // Redeeming any collateral now drops the health factor below 1
        vm.expectRevert();
        dsce.redeemCollateral(weth, 1 ether);
        vm.stopPrank();
    }

    function testCanRedeemCollateralForDsc() public depositedCollateral {
    vm.startPrank(USER);
    dsce.mintDsc(100 ether);
    dsc.approve(address(dsce), 100 ether);
    dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, 100 ether);
    vm.stopPrank();

    assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_ERC20_BALANCE);
    }

    /////////////////////
    // liquidate Tests //
    ////////////////////

    function testCantLiquidateHealthyUser() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100 ether);
        vm.stopPrank();

        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, 100 ether);
        vm.stopPrank();
    }

    function testCanLiquidateUnhealthyUser() public depositedCollateral {
        // USER mints the max safe amount: $10,000 DSC against $20,000 collateral (health factor = 1.0)
        vm.startPrank(USER);
        dsce.mintDsc(10000 ether);
        vm.stopPrank();

        // ETH price crashes from $2,000 to $1,500, so collateral is now worth $15,000.
        // Health factor = (15,000 * 50%) / 10,000 = 0.75, which is below 1.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1500e8);

        // Set up the liquidator with collateral and DSC
        address liquidator = makeAddr("liquidator");
        uint256 collateralToCover = 20 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, 10000 ether);
        dsc.approve(address(dsce), 10000 ether);
        dsce.liquidate(weth, USER, 10000 ether);
        vm.stopPrank();

        // USER's debt should be wiped out
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, 10000 ether) * 110 / 100;
        assertEq(ERC20Mock(weth).balanceOf(liquidator), expectedWeth);
    }

    function testLiquidateRevertsIfHealthFactorNotImproved() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(10000 ether);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8);

        address liquidator = makeAddr("liquidator");
        ERC20Mock(weth).mint(liquidator, 100 ether);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), 100 ether);
        dsce.depositCollateralAndMintDsc(weth, 100 ether, 10000 ether);
        dsc.approve(address(dsce), 10000 ether);
        vm.expectRevert();
        dsce.liquidate(weth, USER, 1 ether);
        vm.stopPrank();
    }

     ///////////////////////////////////
    // DecentralizedStableCoin Tests //
    //////////////////////////////////

    function testMintRevertsIfAmountZero() public {
        vm.prank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(USER, 0);
    }

    function testMintRevertsIfZeroAddress() public {
        vm.prank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        dsc.mint(address(0), 1 ether);
    }

    function testBurnRevertsIfAmountZero() public {
        vm.prank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }

    function testBurnRevertsIfExceedsBalance() public {
        vm.prank(address(dsce));
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(1 ether);
    }

}