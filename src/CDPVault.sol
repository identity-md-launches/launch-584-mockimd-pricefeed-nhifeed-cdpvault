// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CompToken} from "./CompToken.sol";
import {MockWorkOracle} from "./MockWorkOracle.sol";
import {IWorkOracle} from "./interfaces/IWorkOracle.sol";
import {ISwarmFeed} from "./interfaces/ISwarmFeed.sol";
import {FEE_RECIPIENT} from "./DeploymentConfig.sol";

/// @notice Price-aware COMP borrowing and independent work-credit minting on Sepolia.
/// @dev Both tokens use 18 decimals; price is COMP per IMD scaled by 1e18.
/// NHI alone determines collateral requirements and liquidation grace. There is no parameter admin.
/// Zero COMP and oracle arguments create permanently bound contracts with no post-deployment setup.
/// The requester has no initialization authority in this mode; the operator retains only the mock faucets.
contract CDPVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    struct LiquidationMark {
        uint256 markedAt;
        uint256 grace;
        bool marked;
        address marker;
    }

    error InvalidToken();
    error InvalidOracle();
    error InvalidFeed();
    error InvalidPrice();
    error NotInitialized();
    error StaleFeed();
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientRights();
    error UnsafeCollateralRatio();
    error HealthyPosition();
    error ExcessRepayment();
    error UnexpectedCollateralReceived();
    error PositionNotMarked();
    error GracePeriodNotElapsed();
    error MarkExpired();
    error UnderwaterPosition();
    error DebtCeilingReached();
    error PriceDivergence();
    error InvalidBasisPoints();

    event OracleSet(address indexed oracle);
    event CollateralDeposited(address indexed account, uint256 amount);
    event CollateralWithdrawn(address indexed account, uint256 amount);
    event COMPMinted(address indexed account, uint256 amount);
    event WorkMinted(address indexed account, uint256 amount);
    event COMPRepaid(address indexed account, uint256 amount);
    event Liquidated(address indexed owner, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);
    event UnderwaterMarked(address indexed owner, uint256 markedAt, uint256 grace);
    event UnderwaterMarkCleared(address indexed owner);
    event StabilityFeePaid(address indexed owner, uint256 amount);
    event BadDebtRecorded(address indexed owner, uint256 amount);

    uint256 public constant LIQUIDATION_BONUS_PERCENT = 10;

    /// @notice Maximum borrowed principal this vault will ever carry, in stablecoin units.
    /// @dev Unlimited by default so behaviour is unchanged; a deployment that wants a cap overrides
    /// this. There is no admin, so the value a deployment chooses is permanent for that vault —
    /// raising a ceiling means a new vault and a migration, which is the price of having no keys.
    function debtCeiling() public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Share of the liquidation bonus paid to FEE_RECIPIENT, in basis points of the bonus.
    /// @dev Zero by default. The borrower's loss is identical either way: this splits the existing
    /// 10% bonus rather than seizing more, so turning it on never makes liquidation harsher.
    function protocolBonusShareBps() public view virtual returns (uint256) {
        return 0;
    }

    /// @notice Outstanding borrowed principal; the unchanged debt ceiling caps this issuance.
    /// @dev Accrued, unminted stability fees are separate and do not create borrowing headroom.
    uint256 public totalDebt;

    IERC20 public immutable imdToken;
    CompToken public immutable compToken;
    IWorkOracle public immutable oracle;
    ISwarmFeed public immutable priceFeed;
    ISwarmFeed public immutable nhiFeed;
    ISwarmFeed public immutable spotFeed;
    uint256 public immutable maxDivergenceBps;
    uint256 public immutable markerShareBps;
    uint256 public immutable stabilityFeeBps;
    uint256 public immutable deployedAt;
    uint256 public totalFeesMinted;

    /// @notice Outstanding shortfalls recognized when liquidation exhausts collateral.
    /// @dev Checkpointed on debt changes, not a live sum of badDebtOf. Only repayment reduces a
    /// recognized shortfall; depositing collateral cannot hide it. There is no insurance or debt forgiveness.
    uint256 public totalBadDebt;
    mapping(address account => uint256 index) public debtIndexOf;
    mapping(address account => uint256 fees) private _fees;
    mapping(address account => uint256 remainder) private _feeRemainder;
    mapping(address account => uint256 debt) public recordedBadDebtOf;
    uint256 public totalWorkMinted;
    mapping(address account => Position position) private _positions;
    mapping(address account => LiquidationMark mark) public liquidationMarks;

    /// @param imdToken_ Deployed, nonrebasing, fee-free MockIMD collateral (18 decimals).
    /// @param compToken_ Zero creates a fresh CompToken bound to this vault; otherwise an existing token
    /// to be authorized separately through its reciprocal setVault check.
    /// @param oracle_ Zero creates a fresh MockWorkOracle bound to this vault during construction.
    /// A supplied oracle must already be deployed and, if it exposes vault(), bound to this vault.
    /// @param priceFeed_ Immutable collateral price feed, scaled by 1e18.
    /// @param nhiFeed_ Immutable network health feed, scaled by 1e18.
    /// @param spotFeed_ Spot price used only to bound disagreement with the primary average.
    /// @param maxDivergenceBps_ Maximum absolute difference as basis points of the primary price.
    /// @param markerShareBps_ Marker share of the existing liquidation bonus, in basis points.
    /// @param stabilityFeeBps_ Immutable annual simple interest rate; use zero for the default deployment.
    constructor(
        address imdToken_,
        address compToken_,
        address oracle_,
        address priceFeed_,
        address nhiFeed_,
        address spotFeed_,
        uint256 maxDivergenceBps_,
        uint256 markerShareBps_,
        uint256 stabilityFeeBps_
    ) {
        if (
            imdToken_.code.length == 0 || (compToken_ != address(0) && compToken_.code.length == 0)
                || imdToken_ == compToken_
        ) {
            revert InvalidToken();
        }
        if (priceFeed_.code.length == 0 || nhiFeed_.code.length == 0 || priceFeed_ == nhiFeed_) revert InvalidFeed();
        if (spotFeed_.code.length == 0 || spotFeed_ == nhiFeed_) revert InvalidFeed();
        if (maxDivergenceBps_ > 10_000 || markerShareBps_ > 10_000 || stabilityFeeBps_ > 10_000) {
            revert InvalidBasisPoints();
        }
        spotFeed = ISwarmFeed(spotFeed_);
        maxDivergenceBps = maxDivergenceBps_;
        markerShareBps = markerShareBps_;
        stabilityFeeBps = stabilityFeeBps_;
        deployedAt = block.timestamp;
        imdToken = IERC20(imdToken_);
        compToken = compToken_ == address(0) ? new CompToken(address(this)) : CompToken(compToken_);
        priceFeed = ISwarmFeed(priceFeed_);
        nhiFeed = ISwarmFeed(nhiFeed_);
        if (oracle_ == address(0)) {
            oracle_ = address(new MockWorkOracle(address(this)));
        }
        _validateOracle(oracle_);
        oracle = IWorkOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = imdToken.balanceOf(address(this));
        _positions[msg.sender].collateral += amount;
        imdToken.safeTransferFrom(msg.sender, address(this), amount);
        if (imdToken.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedCollateralReceived();
        _clearIfRecovered(msg.sender);
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = _positions[msg.sender];
        if (amount > position.collateral) revert InsufficientCollateral();
        uint256 remaining = position.collateral - amount;
        // A withdrawal with debt always lowers CR, so it cannot be allowed with stale feeds.
        // Debt-free collateral remains withdrawable: its ratio is infinite and no solvency depends on a feed.
        if (position.debt != 0) {
            _requireFreshFeeds();
            if (!_healthy(remaining, debtOf(msg.sender))) revert UnsafeCollateralRatio();
        }
        position.collateral = remaining;
        _clearMark(msg.sender);
        imdToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function mintCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        if (compToken.vault() != address(this)) revert NotInitialized();
        _accrue(msg.sender);
        Position storage position = _positions[msg.sender];
        uint256 resultingDebt = debtOf(msg.sender) + amount;
        if (!_healthy(position.collateral, resultingDebt)) revert UnsafeCollateralRatio();
        uint256 resultingTotal = totalDebt + amount;
        if (resultingTotal > debtCeiling()) revert DebtCeilingReached();
        totalDebt = resultingTotal;
        position.debt += amount;
        _clearMark(msg.sender);
        compToken.mint(msg.sender, amount);
        emit COMPMinted(msg.sender, amount);
    }

    /// @notice Mint earned COMP by consuming work rights, without collateral or a debt entry.
    /// @dev Supply = summed (debtOf - feeOf) + totalWorkMinted = totalDebt + totalWorkMinted.
    /// Accrued fees are unminted; burning a paid fee and minting it to FEE_RECIPIENT cancel in supply.
    /// totalFeesMinted records revenue, not an additional supply term. Neither repayment restores rights.
    function mintFromWork(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireFreshFeeds();
        if (compToken.vault() != address(this)) revert NotInitialized();
        if (oracle.mintingRights(msg.sender) < amount) revert InsufficientRights();
        totalWorkMinted += amount;
        oracle.consumeRights(msg.sender, amount);
        compToken.mint(msg.sender, amount);
        emit WorkMinted(msg.sender, amount);
    }

    /// @notice Repay the caller's debt by burning their COMP; no COMP approval is required.
    /// @dev Repayment does not restore consumed work credits.
    function repayCOMP(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        uint256 feePaid = _reduceDebt(msg.sender, amount);
        _burnRepayment(msg.sender, msg.sender, amount, feePaid);
        _clearIfRecovered(msg.sender);
        emit COMPRepaid(msg.sender, amount);
    }

    /// @notice Start an underwater position's grace window; repeated marks preserve an active snapshot.
    /// @dev A mark is actionable from markedAt + grace for one liquidationWindow(), then expires and must be
    /// retaken, which restarts grace. latestValue cannot reveal a recover-then-fall sequence nobody
    /// transacted through, so bounding a mark's lifetime is what keeps an old mark from turning a later
    /// dip into a same-block liquidation with no effective grace.
    function markUnderwater(address owner) external nonReentrant {
        _requireFreshFeeds();
        _requirePriceAgreement();
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner))) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (mark.marked && !_expired(mark)) return;
        uint256 grace = gracePeriod();
        liquidationMarks[owner] = LiquidationMark(block.timestamp, grace, true, msg.sender);
        emit UnderwaterMarked(owner, block.timestamp, grace);
    }

    /// @notice Anyone may clear a mark after observing recovery, including a recovery caused only by a feed.
    /// @dev latestValue cannot reveal an unobserved recover-then-fall sequence. Keepers should clear marks
    /// when recovery is observed; deposit, repayment and successful borrowing/withdrawal also clear them.
    /// Borrowers should call this while healthy: an unobserved recovery does not restart grace within
    /// the bounded mark lifetime, even if a subsequent dip happens before that lifetime ends.
    function clearRecoveredMark(address owner) external nonReentrant {
        _requireFreshFeeds();
        Position storage position = _positions[owner];
        if (!_healthy(position.collateral, debtOf(owner))) revert UnderwaterPosition();
        _clearMark(owner);
    }

    /// @notice Burn caller COMP against a marked, still-underwater position after its snapshotted grace.
    /// @dev Payout is floor(debtToRepay * 1.1e18 / price) IMD, i.e. collateral worth 110% of the COMP burned
    /// at the same accepted price the health check reads; collateral must cover the full payout.
    /// The mark must still be within its liquidation window (see markUnderwater).
    function liquidate(address owner, uint256 debtToRepay) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();
        _requireFreshFeeds();
        _requirePriceAgreement();
        _accrue(owner);
        Position storage position = _positions[owner];
        if (_healthy(position.collateral, debtOf(owner))) revert HealthyPosition();
        LiquidationMark storage mark = liquidationMarks[owner];
        if (!mark.marked) revert PositionNotMarked();
        if (block.timestamp - mark.markedAt < mark.grace) revert GracePeriodNotElapsed();
        if (_expired(mark)) revert MarkExpired();
        if (debtToRepay > debtOf(owner)) revert ExcessRepayment();
        uint256 price = _price();
        uint256 collateralSeized = Math.mulDiv(debtToRepay, (100 + LIQUIDATION_BONUS_PERCENT) * 1e16, price);
        if (collateralSeized > position.collateral) revert InsufficientCollateral();
        // The protocol's cut comes out of the bonus, never out of the principal, so a liquidator is
        // always made whole on the debt it burned.
        uint256 protocolShare = protocolBonusShareBps();
        if (protocolShare > 10_000 - markerShareBps) revert InvalidBasisPoints();
        uint256 bonus = collateralSeized - Math.mulDiv(debtToRepay, 1e18, price);
        uint256 protocolCut = Math.mulDiv(bonus, protocolShare, 10_000);
        uint256 markerCut = Math.mulDiv(bonus, markerShareBps, 10_000);
        address marker = mark.marker;
        uint256 feePaid = _reduceDebt(owner, debtToRepay);
        position.collateral -= collateralSeized;
        if (position.collateral == 0) _recordBadDebt(owner, debtOf(owner));
        _clearIfRecovered(owner);
        _burnRepayment(owner, msg.sender, debtToRepay, feePaid);
        if (marker == msg.sender) {
            imdToken.safeTransfer(msg.sender, collateralSeized - protocolCut);
        } else {
            imdToken.safeTransfer(msg.sender, collateralSeized - protocolCut - markerCut);
            if (markerCut != 0) imdToken.safeTransfer(marker, markerCut);
        }
        if (protocolCut != 0) imdToken.safeTransfer(FEE_RECIPIENT, protocolCut);
        emit Liquidated(owner, msg.sender, debtToRepay, collateralSeized);
    }

    /// @notice floor(collateral * price * 100 / (debt * 1e18)), using the latest accepted price.
    /// @dev Returns uint256.max for debt-free positions; unrepresentably large ratios also saturate at that value.
    function collateralRatio(address owner) external view returns (uint256) {
        Position storage position = _positions[owner];
        uint256 debt = debtOf(owner);
        if (debt == 0) return type(uint256).max;
        return _collateralRatio(position.collateral, debt, _price());
    }

    /// @notice Position collateral and current principal plus unpaid stability fees.
    function positions(address account) external view returns (uint256 collateral, uint256 debt) {
        return (_positions[account].collateral, debtOf(account));
    }

    /// @notice Deployment-indexed simple annual rate, scaled by 1e18; never compounds per second.
    function debtIndex() public view returns (uint256) {
        return 1e18 + Math.mulDiv(block.timestamp - deployedAt, stabilityFeeBps * 1e18, 365 days * 10_000);
    }

    function debtOf(address account) public view returns (uint256) {
        return _positions[account].debt + feeOf(account);
    }

    /// @notice Unpaid interest on borrowed principal; fees themselves do not earn interest.
    function feeOf(address account) public view returns (uint256) {
        (uint256 fee,) = _pendingFee(account);
        return _fees[account] + fee;
    }

    /// @notice Debt not coverable by the existing 110% liquidation payout at the latest primary price.
    /// @dev This measures shortfalls only: there is no insurance or permission to erase debt.
    /// Includes accrued fees and payout rounding, but does not assert feed freshness or actionable marks.
    function badDebtOf(address account) external view returns (uint256) {
        uint256 debt = debtOf(account);
        uint256 collateral = _positions[account].collateral;
        if (debt == 0 || collateral == 0) return debt;
        uint256 price = _price();
        if (_collateralRatio(collateral, debt, price) >= 100 + LIQUIDATION_BONUS_PERCENT) return 0;
        uint256 payoutScale = (100 + LIQUIDATION_BONUS_PERCENT) * 1e16;
        // floor(repayment * payoutScale / price) <= collateral allows up to
        // ceil((collateral + 1) * price / payoutScale) - 1 repayment. Split the product
        // to avoid overflowing collateral + 1 and cap the result before adding it.
        uint256 covered = Math.mulDiv(collateral, price, payoutScale);
        uint256 extra = price / payoutScale
            + (mulmod(collateral, price, payoutScale) + price % payoutScale + payoutScale - 1) / payoutScale - 1;
        return extra >= debt - covered ? 0 : debt - covered - extra;
    }

    /// @notice Minimum CR, derived only from NHI: 200 at/below .60; 150 at/above .85.
    /// @dev Linear interpolation rounds up to a whole percent, so rounding cannot weaken the threshold.
    function minCR() public view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        return _minCR(nhi);
    }

    /// @notice Grace derived only from NHI: zero at/below .60; six hours at/above .85.
    function gracePeriod() public view returns (uint256) {
        (uint256 nhi,) = nhiFeed.latestValue();
        return _gracePeriod(nhi);
    }

    /// @notice How long after its grace ends a mark stays actionable: the shorter feed lifetime.
    /// @dev Past that, at least one full feed cycle has elapsed in which nobody liquidated, and either
    /// feed may have moved the position through recovery unobserved; the mark is void and must be retaken.
    function liquidationWindow() public view returns (uint256) {
        return Math.min(priceFeed.maxAge(), nhiFeed.maxAge());
    }

    /// @dev Accepts only a deployed contract that answers `mintingRights(address)` as IWorkOracle requires.
    /// If the target additionally exposes `vault()` (as MockWorkOracle does), that consumer must be this vault;
    /// an oracle without that view is accepted so a drop-in IWorkOracle implementation remains compatible.
    function _validateOracle(address oracle_) private view {
        if (oracle_.code.length == 0) revert InvalidOracle();
        (bool ok, bytes memory data) = oracle_.staticcall(abi.encodeCall(IWorkOracle.mintingRights, (address(this))));
        if (!ok || data.length != 32) revert InvalidOracle();
        (ok, data) = oracle_.staticcall(abi.encodeWithSignature("vault()"));
        if (ok && data.length == 32 && abi.decode(data, (uint256)) != uint256(uint160(address(this)))) {
            revert InvalidOracle();
        }
    }

    function _requireFreshFeeds() private view {
        if (priceFeed.isStale() || nhiFeed.isStale()) revert StaleFeed();
        _price();
    }

    /// @dev A pinned closing block and an attestation valid for its TTL let an attacker know which
    /// block to push and act on the signature afterwards. Price off the primary window average;
    /// spot is only a disagreement bound, never a replacement price or a repayment/exit gate.
    function _requirePriceAgreement() private view {
        if (spotFeed.isStale()) revert StaleFeed();
        (uint256 spot,) = spotFeed.latestValue();
        if (spot == 0) revert InvalidPrice();
        uint256 price = _price();
        uint256 difference = spot > price ? spot - price : price - spot;
        if (difference > Math.mulDiv(price, maxDivergenceBps, 10_000)) revert PriceDivergence();
    }

    function _pendingFee(address account) private view returns (uint256 fee, uint256 remainder) {
        uint256 principal = _positions[account].debt;
        if (stabilityFeeBps == 0 || principal == 0) return (0, 0);
        uint256 delta = debtIndex() - debtIndexOf[account];
        fee = Math.mulDiv(principal, delta, 1e18);
        remainder = mulmod(principal, delta, 1e18) + _feeRemainder[account];
        fee += remainder / 1e18;
        remainder %= 1e18;
    }

    function _accrue(address account) private {
        if (stabilityFeeBps == 0) return;
        (uint256 fee, uint256 remainder) = _pendingFee(account);
        _fees[account] += fee;
        _feeRemainder[account] = remainder;
        debtIndexOf[account] = debtIndex();
        uint256 recorded = recordedBadDebtOf[account];
        if (recorded != 0 && fee != 0) {
            _recordBadDebt(account, recorded + fee);
        }
    }

    /// @dev Pay fees first, then principal. Only principal repayment frees issuance headroom.
    function _reduceDebt(address account, uint256 amount) private returns (uint256 feePaid) {
        Position storage position = _positions[account];
        if (amount > position.debt + _fees[account]) revert ExcessRepayment();
        feePaid = Math.min(amount, _fees[account]);
        _fees[account] -= feePaid;
        uint256 principalPaid = amount - feePaid;
        position.debt -= principalPaid;
        totalDebt -= principalPaid;
        if (position.debt == 0) delete _feeRemainder[account];
        uint256 recorded = recordedBadDebtOf[account];
        if (recorded != 0) _recordBadDebt(account, recorded - Math.min(recorded, amount));
    }

    function _burnRepayment(address owner, address payer, uint256 amount, uint256 feePaid) private {
        compToken.burn(payer, amount);
        if (feePaid != 0) {
            totalFeesMinted += feePaid;
            compToken.mint(FEE_RECIPIENT, feePaid);
            emit StabilityFeePaid(owner, feePaid);
        }
    }

    function _recordBadDebt(address account, uint256 amount) private {
        uint256 previous = recordedBadDebtOf[account];
        if (amount == previous) return;
        totalBadDebt = totalBadDebt - previous + amount;
        recordedBadDebtOf[account] = amount;
        emit BadDebtRecorded(account, amount);
    }

    function _price() private view returns (uint256 price) {
        (price,) = priceFeed.latestValue();
        if (price == 0) revert InvalidPrice();
    }

    function _minCR(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 150;
        if (nhi <= 0.6e18) return 200;
        return 150 + Math.mulDiv(0.85e18 - nhi, 50, 0.25e18, Math.Rounding.Ceil);
    }

    function _gracePeriod(uint256 nhi) private pure returns (uint256) {
        if (nhi >= 0.85e18) return 6 hours;
        if (nhi <= 0.6e18) return 0;
        return (nhi - 0.6e18) * 6 hours / 0.25e18;
    }

    function _healthy(uint256 collateral, uint256 debt) private view returns (bool) {
        return debt == 0 || _collateralRatio(collateral, debt, _price()) >= minCR();
    }

    function _clearIfRecovered(address owner) private {
        if (!liquidationMarks[owner].marked) return;
        Position storage position = _positions[owner];
        uint256 debt = debtOf(owner);
        if (debt == 0) {
            _clearMark(owner);
        } else if (!priceFeed.isStale() && !nhiFeed.isStale()) {
            (uint256 price,) = priceFeed.latestValue();
            if (price != 0 && _collateralRatio(position.collateral, debt, price) >= minCR()) {
                _clearMark(owner);
            }
        }
    }

    function _expired(LiquidationMark storage mark) private view returns (bool) {
        return block.timestamp > mark.markedAt + mark.grace + liquidationWindow();
    }

    function _clearMark(address owner) private {
        if (!liquidationMarks[owner].marked) return;
        delete liquidationMarks[owner];
        emit UnderwaterMarkCleared(owner);
    }

    /// @dev Divide collateral into whole/remainder debt units before pricing. This preserves fractions
    /// even for one-wei debt, avoids overflowing debt * 1e16, and saturates only an unrepresentable ratio.
    function _collateralRatio(uint256 collateral, uint256 debt, uint256 price) private pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 scale = 1e16;
        uint256 whole = collateral / debt;
        uint256 priceWhole = price / scale;
        if (priceWhole != 0 && whole > type(uint256).max / priceWhole) return type(uint256).max;
        uint256 ratio = whole * priceWhole;
        uint256 fraction = Math.mulDiv(collateral % debt, price, debt);
        ratio = _saturatingAdd(ratio, Math.mulDiv(whole, price % scale, scale));
        ratio = _saturatingAdd(ratio, fraction / scale);
        return _saturatingAdd(ratio, (mulmod(whole, price, scale) + fraction % scale) / scale);
    }

    function _saturatingAdd(uint256 a, uint256 b) private pure returns (uint256) {
        return b > type(uint256).max - a ? type(uint256).max : a + b;
    }
}
