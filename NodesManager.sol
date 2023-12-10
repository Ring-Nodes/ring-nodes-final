// SPDX-License-Identifier: UNLICENSED


pragma solidity ^0.8.11;

// Optimizations:
// - Cleaner code, uses modifiers instead of repetitive code
// - Properly isolated contracts
// - Uses external instead of public (less gas)
// - Add liquidity once instead of dumping coins constantly (less gas)
// - Accept any amount for node, not just round numbers
// - Safer, using reetrancy protection and more logical-thinking code

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./helpers/OwnerRecoveryUpgradeable.sol";
import "../implementations/output/UniverseImplementationPointerUpgradeable.sol";
import "../implementations/output/LiquidityPoolManagerImplementationPointerUpgradeable.sol";

contract NodesManager is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721URIStorageUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    OwnerRecoveryUpgradeable,
    ReentrancyGuardUpgradeable,
    UniverseImplementationPointerUpgradeable,
    LiquidityPoolManagerImplementationPointerUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;

    struct RingInfoEntity {
        RingEntity Ring;
        uint256 id;
        uint256 pendingRewards;
        uint256 rewardPerDay;
        uint256 compoundDelay;
    }

    struct RingEntity {
        uint256 id;
        string name;
        uint256 creationTime;
        uint256 lastProcessingTimestamp;
        uint256 rewardMult;
        uint256 RingValue;
        uint256 totalClaimed;
        bool exists;
    }

    struct TierStorage {
        uint256 rewardMult;
        uint256 amountLockedInTier;
        bool exists;
    }

    CountersUpgradeable.Counter private _RingCounter;
    mapping(uint256 => RingEntity) private _Rings;
    mapping(uint256 => TierStorage) private _tierTracking;
    uint256[] _tiersTracked;

    uint256 public rewardPerDay;
    uint256 public creationMinPrice;
    uint256 public compoundDelay;
    uint256 public processingFee;

    uint24[6] public tierLevel;
    uint16[6] public tierSlope;

    uint256 private constant ONE_DAY = 86400;
    uint256 public totalValueLocked;

    modifier onlyRingOwner() {
        address sender = _msgSender();
        require(
            sender != address(0),
            "Rings: Cannot be from the zero address"
        );
        require(
            isOwnerOfRings(sender),
            "Rings: No Ring owned by this account"
        );
        require(
            !liquidityPoolManager.isFeeReceiver(sender),
            "Rings: Fee receivers cannot own Rings"
        );
        _;
    }

    modifier checkPermissions(uint256 _RingId) {
        address sender = _msgSender();
        require(RingExists(_RingId), "Rings: This Ring doesn't exist");
        require(
            isOwnerOfRing(sender, _RingId),
            "Rings: You do not control this Ring"
        );
        _;
    }

    modifier universeSet() {
        require(
            address(universe) != address(0),
            "Rings: Universe is not set"
        );
        _;
    }

    event Compound(
        address indexed account,
        uint256 indexed RingId,
        uint256 amountToCompound
    );
    event Cashout(
        address indexed account,
        uint256 indexed RingId,
        uint256 rewardAmount
    );

    event CompoundAll(
        address indexed account,
        uint256[] indexed affectedRings,
        uint256 amountToCompound
    );
    event CashoutAll(
        address indexed account,
        uint256[] indexed affectedRings,
        uint256 rewardAmount
    );

    event Create(
        address indexed account,
        uint256 indexed newRingId,
        uint256 amount
    );

    function initialize() external initializer {
        __ERC721_init("Universe Ecosystem", "Ring");
        __Ownable_init();
        __ERC721Enumerable_init();
        __ERC721URIStorage_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Initialize contract
        changeRewardPerDay(46299); // 4% per day
        changeNodeMinPrice(42_000 * (10**18)); // 42,000 UNIV
        changeCompoundDelay(14400); // 4h
        changeProcessingFee(28); // 28%
        changeTierSystem(
            [100000, 105000, 110000, 120000, 130000, 140000],
            [1000, 500, 100, 50, 10, 0]
        );
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override(ERC721URIStorageUpgradeable, ERC721Upgradeable)
        returns (string memory)
    {
        // return Strings.strConcat(
        //     _baseTokenURI(),
        //     Strings.uint2str(tokenId)
        // );

        // ToDo: fix this
        // To fix: https://andyhartnett.medium.com/solidity-tutorial-how-to-store-nft-metadata-and-svgs-on-the-blockchain-6df44314406b
        // Base64 support for names coming: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/2884/files
        //string memory tokenURI = "test";
        //_setTokenURI(newRingId, tokenURI);

        return ERC721URIStorageUpgradeable.tokenURI(tokenId);
    }

    function createRingWithTokens(
        string memory RingName,
        uint256 RingValue
    ) external nonReentrant whenNotPaused universeSet returns (uint256) {
        address sender = _msgSender();

        require(
            bytes(RingName).length > 3 && bytes(RingName).length < 32,
            "Rings: Name size invalid"
        );
        require(
            RingValue >= creationMinPrice,
            "Rings: Ring value set below creationMinPrice"
        );
        require(
            isNameAvailable(sender, RingName),
            "Rings: Name not available"
        );
        require(
            universe.balanceOf(sender) >= creationMinPrice,
            "Rings: Balance too low for creation"
        );

        // Burn the tokens used to mint the NFT
        universe.accountBurn(sender, RingValue);

        // Send processing fee to liquidity
        (, uint256 feeAmount) = getProcessingFee(RingValue);
        universe.liquidityReward(feeAmount);

        // Increment the total number of tokens
        _RingCounter.increment();

        uint256 newRingId = _RingCounter.current();
        uint256 currentTime = block.timestamp;

        // Add this to the TVL
        totalValueLocked += RingValue;
        logTier(tierLevel[0], int256(RingValue));

        // Add Ring
        _Rings[newRingId] = RingEntity({
            id: newRingId,
            name: RingName,
            creationTime: currentTime,
            lastProcessingTimestamp: currentTime,
            rewardMult: tierLevel[0],
            RingValue: RingValue,
            totalClaimed: 0,
            exists: true
        });

        // Assign the Ring to this account
        _mint(sender, newRingId);

        emit Create(sender, newRingId, RingValue);

        return newRingId;
    }

    function cashoutReward(uint256 _RingId)
        external
        nonReentrant
        onlyRingOwner
        checkPermissions(_RingId)
        whenNotPaused
        universeSet
    {
        address account = _msgSender();
        uint256 reward = _getRingCashoutRewards(_RingId);
        _cashoutReward(reward);

        emit Cashout(account, _RingId, reward);
    }

    function cashoutAll()
        external
        nonReentrant
        onlyRingOwner
        whenNotPaused
        universeSet
    {
        address account = _msgSender();
        uint256 rewardsTotal = 0;

        uint256[] memory RingsOwned = getRingIdsOf(account);
        for (uint256 i = 0; i < RingsOwned.length; i++) {
            rewardsTotal += _getRingCashoutRewards(RingsOwned[i]);
        }
        _cashoutReward(rewardsTotal);

        emit CashoutAll(account, RingsOwned, rewardsTotal);
    }

    function compoundReward(uint256 _RingId)
        external
        nonReentrant
        onlyRingOwner
        checkPermissions(_RingId)
        whenNotPaused
        universeSet
    {
        address account = _msgSender();

        (
            uint256 amountToCompound,
            uint256 feeAmount
        ) = _getRingCompoundRewards(_RingId);
        require(
            amountToCompound > 0,
            "Rings: You must wait until you can compound again"
        );
        if (feeAmount > 0) {
            universe.liquidityReward(feeAmount);
        }

        emit Compound(account, _RingId, amountToCompound);
    }

    function compoundAll()
        external
        nonReentrant
        onlyRingOwner
        whenNotPaused
        universeSet
    {
        address account = _msgSender();
        uint256 feesAmount = 0;
        uint256 amountsToCompound = 0;
        uint256[] memory RingsOwned = getRingIdsOf(account);
        uint256[] memory RingsAffected = new uint256[](RingsOwned.length);

        for (uint256 i = 0; i < RingsOwned.length; i++) {
            (
                uint256 amountToCompound,
                uint256 feeAmount
            ) = _getRingCompoundRewards(RingsOwned[i]);
            if (amountToCompound > 0) {
                RingsAffected[i] = RingsOwned[i];
                feesAmount += feeAmount;
                amountsToCompound += amountToCompound;
            } else {
                delete RingsAffected[i];
            }
        }

        require(amountsToCompound > 0, "Rings: No rewards to compound");
        if (feesAmount > 0) {
            universe.liquidityReward(feesAmount);
        }

        emit CompoundAll(account, RingsAffected, amountsToCompound);
    }

    // Private reward functions

    function _getRingCashoutRewards(uint256 _RingId)
        private
        returns (uint256)
    {
        RingEntity storage Ring = _Rings[_RingId];
        uint256 reward = calculateReward(Ring);
        Ring.totalClaimed += reward;

        if (Ring.rewardMult != tierLevel[0]) {
            logTier(Ring.rewardMult, -int256(Ring.RingValue));
            logTier(tierLevel[0], int256(Ring.RingValue));
        }

        Ring.rewardMult = tierLevel[0];
        Ring.lastProcessingTimestamp = block.timestamp;
        return reward;
    }

    function _getRingCompoundRewards(uint256 _RingId)
        private
        returns (uint256, uint256)
    {
        RingEntity storage Ring = _Rings[_RingId];

        if (!isCompoundable(Ring)) {
            return (0, 0);
        }

        uint256 reward = calculateReward(Ring);
        if (reward > 0) {
            (uint256 amountToCompound, uint256 feeAmount) = getProcessingFee(
                reward
            );
            totalValueLocked += amountToCompound;

            logTier(Ring.rewardMult, -int256(Ring.RingValue));

            Ring.lastProcessingTimestamp = block.timestamp;
            Ring.RingValue += amountToCompound;
            Ring.rewardMult += increaseMultiplier(Ring.rewardMult);

            logTier(Ring.rewardMult, int256(Ring.RingValue));

            return (amountToCompound, feeAmount);
        }

        return (0, 0);
    }

    function _cashoutReward(uint256 amount) private {
        require(
            amount > 0,
            "Rings: You don't have enough reward to cash out"
        );
        address to = _msgSender();
        (uint256 amountToReward, uint256 feeAmount) = getProcessingFee(amount);
        universe.accountReward(to, amountToReward);
        // Send the fee to the contract where liquidity will be added later on
        universe.liquidityReward(feeAmount);
    }

    function logTier(uint256 mult, int256 amount) private {
        TierStorage storage tierStorage = _tierTracking[mult];
        if (tierStorage.exists) {
            require(
                tierStorage.rewardMult == mult,
                "Rings: rewardMult does not match in TierStorage"
            );
            uint256 amountLockedInTier = uint256(
                int256(tierStorage.amountLockedInTier) + amount
            );
            require(
                amountLockedInTier >= 0,
                "Rings: amountLockedInTier cannot underflow"
            );
            tierStorage.amountLockedInTier = amountLockedInTier;
        } else {
            // Tier isn't registered exist, register it
            require(
                amount > 0,
                "Rings: Fatal error while creating new TierStorage. Amount cannot be below zero."
            );
            _tierTracking[mult] = TierStorage({
                rewardMult: mult,
                amountLockedInTier: uint256(amount),
                exists: true
            });
            _tiersTracked.push(mult);
        }
    }

    // Private view functions

    function getProcessingFee(uint256 rewardAmount)
        private
        view
        returns (uint256, uint256)
    {
        uint256 feeAmount = 0;
        if (processingFee > 0) {
            feeAmount = (rewardAmount * processingFee) / 100;
        }
        return (rewardAmount - feeAmount, feeAmount);
    }

    function increaseMultiplier(uint256 prevMult)
        private
        view
        returns (uint256)
    {
        if (prevMult >= tierLevel[5]) {
            return tierSlope[5];
        } else if (prevMult >= tierLevel[4]) {
            return tierSlope[4];
        } else if (prevMult >= tierLevel[3]) {
            return tierSlope[2];
        } else if (prevMult >= tierLevel[2]) {
            return tierSlope[2];
        } else if (prevMult >= tierLevel[1]) {
            return tierSlope[1];
        } else {
            return tierSlope[0];
        }
    }

    function isCompoundable(RingEntity memory Ring)
        private
        view
        returns (bool)
    {
        return
            block.timestamp >= Ring.lastProcessingTimestamp + compoundDelay;
    }

    function calculateReward(RingEntity memory Ring)
        private
        view
        returns (uint256)
    {
        return
            _calculateRewardsFromValue(
                Ring.RingValue,
                Ring.rewardMult,
                block.timestamp - Ring.lastProcessingTimestamp,
                rewardPerDay
            );
    }

    function rewardPerDayFor(RingEntity memory Ring)
        private
        view
        returns (uint256)
    {
        return
            _calculateRewardsFromValue(
                Ring.RingValue,
                Ring.rewardMult,
                ONE_DAY,
                rewardPerDay
            );
    }

    function _calculateRewardsFromValue(
        uint256 _RingValue,
        uint256 _rewardMult,
        uint256 _timeRewards,
        uint256 _rewardPerDay
    ) private pure returns (uint256) {
        uint256 rewards = (_timeRewards * _rewardPerDay) / 1000000;
        uint256 rewardsMultiplicated = (rewards * _rewardMult) / 100000;
        return (rewardsMultiplicated * _RingValue) / 100000;
    }

    function RingExists(uint256 _RingId) private view returns (bool) {
        require(_RingId > 0, "Rings: Id must be higher than zero");
        RingEntity memory Ring = _Rings[_RingId];
        if (Ring.exists) {
            return true;
        }
        return false;
    }

    // Public view functions

    function calculateTotalDailyEmission() external view returns (uint256) {
        uint256 dailyEmission = 0;
        for (uint256 i = 0; i < _tiersTracked.length; i++) {
            TierStorage memory tierStorage = _tierTracking[_tiersTracked[i]];
            dailyEmission += _calculateRewardsFromValue(
                tierStorage.amountLockedInTier,
                tierStorage.rewardMult,
                ONE_DAY,
                rewardPerDay
            );
        }
        return dailyEmission;
    }

    function isNameAvailable(address account, string memory RingName)
        public
        view
        returns (bool)
    {
        uint256[] memory RingsOwned = getRingIdsOf(account);
        for (uint256 i = 0; i < RingsOwned.length; i++) {
            RingEntity memory Ring = _Rings[RingsOwned[i]];
            if (keccak256(bytes(Ring.name)) == keccak256(bytes(RingName))) {
                return false;
            }
        }
        return true;
    }

    function isOwnerOfRings(address account) public view returns (bool) {
        return balanceOf(account) > 0;
    }

    function isOwnerOfRing(address account, uint256 _RingId)
        public
        view
        returns (bool)
    {
        uint256[] memory RingIdsOf = getRingIdsOf(account);
        for (uint256 i = 0; i < RingIdsOf.length; i++) {
            if (RingIdsOf[i] == _RingId) {
                return true;
            }
        }
        return false;
    }

    function getRingIdsOf(address account)
        public
        view
        returns (uint256[] memory)
    {
        uint256 numberOfRings = balanceOf(account);
        uint256[] memory RingIds = new uint256[](numberOfRings);
        for (uint256 i = 0; i < numberOfRings; i++) {
            uint256 RingId = tokenOfOwnerByIndex(account, i);
            require(
                RingExists(RingId),
                "Rings: This Ring doesn't exist"
            );
            RingIds[i] = RingId;
        }
        return RingIds;
    }

    function getRingsByIds(uint256[] memory _RingIds)
        external
        view
        returns (RingInfoEntity[] memory)
    {
        RingInfoEntity[] memory RingsInfo = new RingInfoEntity[](
            _RingIds.length
        );
        for (uint256 i = 0; i < _RingIds.length; i++) {
            uint256 RingId = _RingIds[i];
            RingEntity memory Ring = _Rings[RingId];
            RingsInfo[i] = RingInfoEntity(
                Ring,
                RingId,
                calculateReward(Ring),
                rewardPerDayFor(Ring),
                compoundDelay
            );
        }
        return RingsInfo;
    }

    // Owner functions

    function changeNodeMinPrice(uint256 _creationMinPrice) public onlyOwner {
        require(
            _creationMinPrice > 0,
            "Rings: Minimum price to create a Ring must be above 0"
        );
        creationMinPrice = _creationMinPrice;
    }

    function changeCompoundDelay(uint256 _compoundDelay) public onlyOwner {
        require(
            _compoundDelay > 0,
            "Rings: compoundDelay must be greater than 0"
        );
        compoundDelay = _compoundDelay;
    }

    function changeRewardPerDay(uint256 _rewardPerDay) public onlyOwner {
        require(
            _rewardPerDay > 0,
            "Rings: rewardPerDay must be greater than 0"
        );
        rewardPerDay = _rewardPerDay;
    }

    function changeTierSystem(
        uint24[6] memory _tierLevel,
        uint16[6] memory _tierSlope
    ) public onlyOwner {
        require(
            _tierLevel.length == 6,
            "Rings: newTierLevels length has to be 6"
        );
        require(
            _tierSlope.length == 6,
            "Rings: newTierSlopes length has to be 6"
        );
        tierLevel = _tierLevel;
        tierSlope = _tierSlope;
    }

    function changeProcessingFee(uint8 _processingFee) public onlyOwner {
        require(_processingFee <= 30, "Cashout fee can never exceed 30%");
        processingFee = _processingFee;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    // Mandatory overrides

    function _burn(uint256 tokenId)
        internal
        override(ERC721URIStorageUpgradeable, ERC721Upgradeable)
    {
        ERC721Upgradeable._burn(tokenId);
        ERC721URIStorageUpgradeable._burn(tokenId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    )
        internal
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        whenNotPaused
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}