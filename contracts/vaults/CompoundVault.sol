// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.3;

import "../libraries/History.sol";
import "../libraries/Storage.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ICToken.sol";
import "../interfaces/IComptroller.sol";
import "../interfaces/IVotingVault.sol";

abstract contract AbstractCompoundVault is IVotingVault {
    // bring in libraries
    using History for *;
    using Storage for *;

    /************************************************
     *  STORAGE & STRUCTS
     ***********************************************/
    /// Note: We utilize the Storage.sol library to avoid storage collisions
    /// Thus there are no storage variables in this contract, but we will list some of them 
    /// out for clarity's sake. 

    /// Note: "TWAR" stands for Time Weighted Average (Borrow) Rate and functions similar to a TWAP

    /// uint256 lastUpdatedAt - timestamp when our TWAR was last updated
    /// twarSnapshot[] twarSnapshots - array of twapSnapshots
    /// uint256 twarIndex - current index in twarSnapshots which we will update/overwrite next
    /// uint256 weightedBorrowRate - the TWAR borrow rate, scaled to an annual rate (3% annual rate = 0.03*10^18)

    struct twarSnapshot {
        uint256 cumulativeRate; // cumulative rate of borrow rate at time of struct creation
        uint256 timestamp; // timestamp this struct was created
    }

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

    /************************************************
     *  EVENTS & MODIFIERS
     ***********************************************/

    /// @notice emitted on vote power change
    event VoteChange(address indexed from, address indexed to, int256 amount);

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
     *  SHARES LOGIC
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
        /// TODO: TWAP logic (check if we can update it)
            here
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
        emit VoteChange(fundedAccount, delegate, weightedVotingPower)
    }

    /**
     * @notice Uses the time weighted borrow rate to calculate the voting power of the given number of cTokens
     * @param numCTokens the number of cTokens
     * @return the voting power weightage of this number of cTokens at this specific block
     */
    function _calculateCTokenVotingPower(uint256 numCTokens) internal returns (uint256) {
        /// TODO
        // First let's see how much of the underlying numCTokens is worth
        // exchangeRate is scaled by 10^(10 + underlying.decimals()) so we need to divide that out at the end
        // see https://compound.finance/docs/ctokens#exchange-rate
        uint256 underlyingAmount = (numCTokens * cToken.exchangeRateCurrent()) / (10 ** (10 + underlying.decimals()));

        // Ok, now let's weight the underlyingAmount according to the TWAR
        // TODO: Need to create our own custom storage similar to VestingVaultStorage
        Storage.

    }

}
