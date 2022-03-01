// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

import "../libraries/History.sol";
import "../libraries/Storage.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ICToken.sol";
import "../interfaces/IComptroller.sol";
import "../interfaces/IVotingVault.sol";
import "../libraries/CompoundVaultStorage.sol";

abstract contract AbstractCompoundVault is IVotingVault {
    // bring in libraries
    using History for *;
    using Storage for *;

    /************************************************
     *  STORAGE UTILITIES
     ***********************************************/
    /// Note: We utilize the Storage.sol library to avoid storage collisions
    /// Thus there are no storage variables in this contract directly, but we will list some of the used storage 
    /// variables out for clarity's sake. 
    /// Note: "TWAR" stands for Time Weighted Average (Borrow) Rate and functions similar to a TWAP

    /// (uint256) lastUpdatedAt - timestamp when our TWAR was last updated
    string public constant LAST_UPDATED_AT = "lastUpdatedAt";

    /// twarSnapshot[] twarSnapshots - array of twarSnapshots
    string public constant TWAR_SNAPSHOTS = "twarSnapshots";

    /// (uint256) twarIndex - current index in twarSnapshots which we will update/overwrite next
    string public constant TWAR_INDEX = "twarIndex";

    // (uint256) - latest multiplier to use per unit of underlying, scaled by a factor of 10^18
    /// e.g a multiplier of 0.97 would be represented as 0.97 * 10^18
    string public constant TWAR_MULTIPLIER = "twarMultiplier";

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    /// @notice underlying governance token
    IERC20 public immutable underlying;

    /// @notice cToken of the governance token
    ICToken public immutable cToken;

    /// @notice minimum time delay between updating TWAR
    uint256 public immutable period;

    /// @notice how far (in blocks) back we define stale blocks to be
    uint256 public immutable staleBlockLag;

    /// @notice the max length of the twarSnapshots array
    uint256 public immutable twarSnapshotsMaxLength;

    /// @notice number of blocks per year, based on avg block time of 14 seconds
    uint256 public constant BLOCKS_PER_YEAR = 2252857;

    /************************************************
     *  EVENTS & MODIFIERS
     ***********************************************/

    /// @notice emitted on vote power change
    event VoteChange(address indexed from, address indexed to, int256 amount);

    /// @notice emitted on TWAR multiplier change
    event MultiplierChanged(uint256 oldMultiplier, uint256 newMultiplier);

    /**
     * @notice constructor that sets the immutables
     * @param _underlying the underlying governance token
     * @param _cToken the cToken of the governance token
     * @param comptroller the address of the Compound Comptroller
     * @param _period the minimum delay period between sampling the borrow rate
     * @param _staleBlockLag stale block lag in units of blocks
     * @param _twarSnapshotsMaxLength the max length of the twarSnapshots array
     */
    constructor(
        IERC20 _underlying,
        ICToken _cToken,
        IComptroller comptroller,
        uint256 _period,
        uint256 _staleBlockLag,
        uint256 _twarSnapshotsMaxLength
    ) {
        underlying = _underlying;
        cToken = _cToken;
        period = _period;
        staleBlockLag = _staleBlockLag;
        twarSnapshotsMaxLength = _twarSnapshotsMaxLength;

        // In order to interact with compound, we must first enter the market
        // See https://compound.finance/docs/comptroller#enter-markets
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(_cToken);
        uint[] memory responses = comptroller.enterMarkets(cTokens);
        require(responses[0] == 0, "Couldn't enter market for cToken");
    }

    /************************************************
     *  VAULT LOGIC
     ***********************************************/

    /**
     * @notice A single function endpoint for loading storage for deposits
     * @return returns a storage mapping which can be used to look up deposit data
     */
    function _deposits()
        internal
        pure
        returns (mapping(address => Storage.AddressUint) storage)
    {
        // This call returns a storage mapping with a unique non overwrite-able storage location
        // which can be persisted through upgrades, even if they change storage layout
        return (Storage.mappingAddressToPackedAddressUint("deposits"));
    }

    /**
     * @notice Getter for deposits mapping
     * @param who the user to query the balance of
     * @return (address delegated to, amount of deposit in cToken)
     */
    function deposits(address who) external view returns (address, uint96) {
        Storage.AddressUint storage userData = _deposits()[who];
        return (userData.who, userData.amount);
    }

    /**
     * @notice Deposits underlying amount in Compound and delegates voting power to firstDelegation
     * @param fundedAccount the address to credit this deposit to
     * @param amount The amount in underlying to deposit to compound
     * @param firstDelegation first delegation address
     * @dev requires that user has already called approve() on this contract for specified amount or more
     */
    function deposit(address fundedAccount, uint256 amount, address firstDelegation) external {
        // Check if we need to update our TWAR
        if ((block.timestamp - Storage.uint256Ptr(LAST_UPDATED_AT).data) > period) {
            _updateTwar();
        }

        // No delegating to zero
        require(firstDelegation != address(0), "Zero addr delegation");
        // transfer underlying to this address
        underlying.transferFrom(msg.sender, address(this), amount);

        // Now let's go ahead and deposit to compound
        // Allow the cToken access to the newly deposited balance
        underlying.approve(address(cToken), amount);
        uint256 balanceBefore = cToken.balanceOf(address(this));
        require(cToken.mint(amount) == 0, "Error minting cToken");
        uint256 cTokensMinted = cToken.balanceOf(address(this)) - balanceBefore;

        // Load our deposits storage
        Storage.AddressUint storage userData = _deposits()[fundedAccount];
        // Load who has the user's votes
        address delegate = userData.who;

        if (delegate == address(0)) {
            // If the user is un-delegated we delegate to their indicated address
            delegate = firstDelegation;
            // Set the delegation
            userData.who = delegate;
            // Now we increase the user's recorded deposit (in cTokens)
            userData.amount += uint96(cTokensMinted);
        } else {
            userData.amount += uint96(cTokensMinted);
        }

        // Next we increase the delegation to their delegate
        // Get the storage pointer
        History.HistoricalBalances memory votingPower = _votingPower();
        // Load the most recent voter power stamp
        uint256 delegateeVotes = votingPower.loadTop(delegate);

        // Let's calculate the voting power of the minted cTokens
        uint256 weightedVotingPower = _calculateCTokenVotingPower(cTokensMinted);
        // Add the newly deposited votes to the delegate
        votingPower.push(delegate, delegateeVotes + weightedVotingPower);
        // Emit event for vote change
        emit VoteChange(fundedAccount, delegate, weightedVotingPower);
    }

    /**
     * @notice Uses the time weighted borrow rate to calculate the voting power of the given number of cTokens
     * @param numCTokens the number of cTokens
     * @return the voting power of this number of cTokens at the current block
     */
    function _calculateCTokenVotingPower(uint256 numCTokens) internal returns (uint256) {
        // First let's see how much of the underlying numCTokens is worth
        // exchangeRate is scaled by 10^(10 + underlying.decimals()) so we need to divide appropriately at end
        // see https://compound.finance/docs/ctokens#exchange-rate
        uint256 underlyingAmount = (numCTokens * cToken.exchangeRateCurrent()) / (10 ** (10 + cToken.decimals()));

        // Ok, now let's weight the underlyingAmount according to the TWAR
        uint256 twarMultiplier = Storage.uint256Ptr(TWAR_MULTIPLIER).data;
        // TWAR is scaled by a factor of 10^18, so let's divide that out 
        return (underlyingAmount * twarMultiplier) / (10**18);
    }

    /**
     * @notice updates the TWAR state (twarSnapshots, twarIndex, twarMultiplier, etc.)
     */
    function _updateTwar() internal {
        // Let's fetch the most recent twarSnapshot created
        CompoundVaultStorage.twarSnapshot[] storage twarSnapshots = CompoundVaultStorage.arrayPtr(TWAR_SNAPSHOTS);
        CompoundVaultStorage.twarSnapshot memory lastSnapshot;
        uint256 twarIndex = Storage.uint256Ptr(TWAR_INDEX).data;
        if (twarSnapshots.length > 0) {
            // grab the last snapshot
            lastSnapshot = twarSnapshots[twarIndex];
        } else {
            // This means that we have never added to the twarArray
            // Let's construct a dummy twarSnapshot struct in this case
            lastSnapshot = CompoundVaultStorage.twarSnapshot(
                0, // set cumulative rate to 0 
                block.timestamp - period // set the last timestamp to be 'period' seconds in the past
            );
        }
        
        // Now let's construct our new snapshot 
        uint256 elapsedTime = block.timestamp - lastSnapshot;
        // Let's query for the current cToken borrow rate
        uint256 currBorrowRate = cToken.borrowRatePerBlock();
        uint256 newCumulativeRate = lastSnapshot.cumulativeRate + (currBorrowRate * elapsedTime);

        CompoundVaultStorage.twarSnapshot memory newSnapshot = CompoundVaultStorage.twarSnapshot(
            newCumulativeRate,
            block.timestamp
        );

        // Let's figure out where we should place this new snapshot (increment, wrap around, or expand array)
        uint256 newTwarIndex;
        if (twarSnapshots.length < twarSnapshotsMaxLength) {
            // We should expand in the array in this case
            twarSnapshots.push(newSnapshot);
            newTwarIndex = twarSnapshots.length - 1;
            Storage.set(Storage.uint256Ptr(TWAR_INDEX), newTwarIndex);
        } else {
            // in this case our array is the max size, and we simply need to increment the index, possibly wrapping around
            // to the beginning of the array
            newTwarIndex = (twarIndex + 1) % twarSnapshots.length;
            Storage.set(Storage.uint256Ptr(TWAR_INDEX), newTwarIndex);
            twarSnapshots[newTwarIndex] = newSnapshot;
        }

        // Now let's update our current twarMultiplier
        // If we don't have maxLength # of snapshots in our array, just default to 0 
        uint256 subtractIndex = (twarSnapshots.length == twarSnapshotsMaxLength) ? ((newTwarIndex + 1) % twarSnapshots.length) : 0;
        CompoundVaultStorage.twarSnapshot memory subtractSnapshot = twarSnapshots[subtractIndex];

        // The borrow rate is given per block, so let's multiply by blocks per year to get the projected annual borrow rate
        uint256 weightedAnnualBorrowRate = (newSnapshot.cumulativeRate - subtractSnapshot.cumulativeRate) / (newSnapshot.timestamp - subtractSnapshot.timestamp)
            * BLOCKS_PER_YEAR;

        // Because of annual borrow rate is an estimate there is a (very unlikely) chance that the first subtraction expression is negative
        // if the borrow rate is extremeley (close to 100%) for a prolonged period of time
        // we prevent a revert in this extreme edge case via the ternary expression below
        uint256 newMultiplier = (10**18 - weightedAnnualBorrowRate) > 0 ? (10**18 - weightedAnnualBorrowRate) : 0;
        uint256 oldMultiplier = Storage.uint256Ptr(TWAR_MULTIPLIER).data;
        Storage.set(Storage.uint256Ptr(TWAR_MULTIPLIER), newMultiplier);

        emit MultiplierChanged(oldMultiplier, newMultiplier);

        // Finally, let's update the LAST_UPDATED_AT storage var
        Storage.set(Storage.uint256Ptr(LAST_UPDATED_AT), block.timestamp);
    }
}
