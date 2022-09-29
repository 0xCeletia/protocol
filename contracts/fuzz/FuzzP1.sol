// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "contracts/interfaces/IGnosis.sol";
import "contracts/interfaces/ITrade.sol";
import "contracts/libraries/Fixed.sol";

import "contracts/fuzz/IFuzz.sol";
import "contracts/fuzz/TradeMock.sol";
import "contracts/fuzz/Utils.sol";

import "contracts/p1/AssetRegistry.sol";
import "contracts/p1/BackingManager.sol";
import "contracts/p1/BasketHandler.sol";
import "contracts/p1/Broker.sol";
import "contracts/p1/Distributor.sol";
import "contracts/p1/Furnace.sol";
import "contracts/p1/Main.sol";
import "contracts/p1/RToken.sol";
import "contracts/p1/RevenueTrader.sol";
import "contracts/p1/StRSR.sol";
import "contracts/plugins/assets/RTokenAsset.sol";

// Every component must override _msgSender() in this one, common way!

contract AssetRegistryP1Fuzz is AssetRegistryP1 {
    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract BasketHandlerP1Fuzz is BasketHandlerP1 {
    using BasketLib for Basket;
    Basket internal prev;

    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }

    function savePrev() external {
        prev.setFrom(basket);
    }

    function prevEqualsCurr() external view returns (bool) {
        uint256 n = basket.erc20s.length;
        if (n != prev.erc20s.length) return false;
        for (uint256 i = 0; i < n; i++) {
            if (prev.erc20s[i] != basket.erc20s[i]) return false;
            if (prev.refAmts[prev.erc20s[i]] != basket.refAmts[basket.erc20s[i]]) return false;
        }
        return true;
    }
}

contract BackingManagerP1Fuzz is BackingManagerP1 {
    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract BrokerP1Fuzz is BrokerP1 {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSet for EnumerableSet.AddressSet;

    ITrade public lastOpenedTrade;
    EnumerableSet.AddressSet internal tradeSet;

    function _openTrade(TradeRequest memory req) internal virtual override returns (ITrade) {
        TradeMock trade = new TradeMock();

        IERC20Upgradeable(address(req.sell.erc20())).safeTransferFrom(
            _msgSender(),
            address(trade),
            req.sellAmount
        );

        trade.init(IMainFuzz(address(main)), _msgSender(), auctionLength, req);
        tradeSet.add(address(trade));
        lastOpenedTrade = trade;
        return trade;
    }

    function settleTrades() public {
        uint256 length = tradeSet.length();
        IMainFuzz m = IMainFuzz(address(main));
        for (uint256 i = 0; i < length; i++) {
            TradeMock trade = TradeMock(tradeSet.at(i));
            if (trade.canSettle()) {
                m.spoof(address(this), trade.origin());
                trade.settle();
                m.unspoof(address(this));
            }
        }
    }

    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract DistributorP1Fuzz is DistributorP1 {
    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract FurnaceP1Fuzz is FurnaceP1 {
    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract RevenueTraderP1Fuzz is RevenueTraderP1 {
    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract RTokenP1Fuzz is IRTokenFuzz, RTokenP1 {
    using FixLib for uint192;

    // The range of IDs that would be valid as endID in cancel() or vest()
    function idRange(address user) external view returns (uint256 left, uint256 right) {
        left = issueQueues[user].left;
        right = issueQueues[user].right;
    }

    // To be called only from MarketMock; this only works if MarketMock never enqueues any other
    // issuances.
    function fastIssue(uint256 amtRToken) external notPausedOrFrozen {
        require(amtRToken > 0, "Cannot issue zero");
        issue(amtRToken);

        IssueQueue storage queue = issueQueues[_msgSender()];
        if (queue.right > queue.left) {
            // We pushed a slow issuance, so rewrite that to be available now, and then vest it.
            queue.items[queue.right - 1].when = 0;
            vestUpTo(_msgSender(), queue.right);
        }
    }

    /// The tokens and underlying quantities needed to issue `amount` qRTokens.
    /// @dev this is distinct from basketHandler().quote() b/c the input is in RTokens, not BUs.
    /// @param amount {qRTok} quantity of qRTokens to quote.
    function quote(uint256 amount, RoundingMode roundingMode)
        external
        view
        returns (address[] memory tokens, uint256[] memory amts)
    {
        uint192 baskets = (totalSupply() > 0)
            ? basketsNeeded.muluDivu(amount, totalSupply()) // {BU * qRTok / qRTok}
            : uint192(amount); // {qRTok / qRTok}

        return main.basketHandler().quote(baskets, roundingMode);
    }

    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}

contract StRSRP1Fuzz is StRSRP1 {
    // A range of plausibly-valid IDs for withdraw()
    function idRange(address user) external view returns (uint256 left, uint256 right) {
        left = firstRemainingDraft[draftEra][user];
        right = draftQueues[draftEra][user].length;
    }

    function invariantsHold() external view returns (bool) {
        bool stakesProp = totalStakes == 0 ? stakeRSR == 0 && stakeRate == FIX_ONE : stakeRSR > 0;
        bool draftsProp = totalDrafts == 0 ? draftRSR == 0 && draftRate == FIX_ONE : draftRSR > 0;

        return stakesProp && draftsProp;
    }

    function _msgSender() internal view virtual override returns (address) {
        return IMainFuzz(address(main)).translateAddr(msg.sender);
    }
}