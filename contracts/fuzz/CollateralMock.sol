// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "contracts/fuzz/AssetMock.sol";
import "contracts/fuzz/ERC20Fuzz.sol";
import "contracts/fuzz/OracleErrorMock.sol";
import "contracts/fuzz/PriceModel.sol";
import "contracts/fuzz/Utils.sol";
import "contracts/interfaces/IAsset.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/plugins/assets/FiatCollateral.sol";

contract CollateralMock is OracleErrorMock, FiatCollateral {
    using FixLib for uint192;
    using PriceModelLib for PriceModel;

    PriceModel public refPerTokModel;
    PriceModel public targetPerRefModel;
    PriceModel public uoaPerTargetModel;
    PriceModel public deviationModel;

    constructor(
        // Collateral base-class arguments
        IERC20Metadata erc20_,
        uint192 maxTradeVolume_,
        uint48 priceTimeout_,
        uint192 oracleError_,
        uint192 defaultThreshold_,
        uint256 delayUntilDefault_,
        bytes32 targetName_,
        // Price Models
        PriceModel memory refPerTokModel_, // Ref units per token
        PriceModel memory targetPerRefModel_, // Target units per ref unit
        PriceModel memory uoaPerTargetModel_, // Units-of-account per target unit
        PriceModel memory deviationModel_
    )
        // deviationModel is the deviation of price() from the combination of the above.
        // that is: price() = deviation * uoaPerTarget * targetPerRef * refPerTok
        FiatCollateral(
            CollateralConfig({
                priceTimeout: priceTimeout_,
                chainlinkFeed: AggregatorV3Interface(address(1)),
                oracleError: oracleError_,
                erc20: erc20_,
                maxTradeVolume: maxTradeVolume_,
                oracleTimeout: 1, //stub
                targetName: targetName_,
                defaultThreshold: defaultThreshold_,
                delayUntilDefault: delayUntilDefault_
            })
        )
    {
        refPerTokModel = refPerTokModel_;
        targetPerRefModel = targetPerRefModel_;
        uoaPerTargetModel = uoaPerTargetModel_;
        deviationModel = deviationModel_;
    }

    function tryPrice()
        external
        view
        virtual
        override
        returns (
            uint192 low,
            uint192 high,
            uint192 pegPrice
        )
    {
        maybeFail();

        pegPrice = targetPerRefModel.price();

        uint192 p = deviationModel.price().mul(uoaPerTargetModel.price()).mul(pegPrice).mul(
            refPerTokModel.price()
        );

        (low, high) = errRange(p, oracleError);
    }

    /// @return {ref/tok} Quantity of whole reference units per whole collateral tokens
    function refPerTok() public view virtual override returns (uint192) {
        return refPerTokModel.price();
    }

    /// @return {target/ref} Quantity of whole target units per whole reference unit in the peg
    function targetPerRef() public view virtual override returns (uint192) {
        return targetPerRefModel.price();
    }

    function update(
        uint192 a,
        uint192 b,
        uint192 c,
        uint192 d
    ) public virtual {
        refPerTokModel.update(a);
        targetPerRefModel.update(b);
        uoaPerTargetModel.update(c);
        deviationModel.update(d);
    }

    function partialUpdate(uint192 a, uint192 b) public {
        uoaPerTargetModel.update(a);
        deviationModel.update(b);
    }
}
