# Compound Voting Vaults
Compound Voting Vault for Element Finance that assigns voting power to cTokens weighted by the Time-weighted Average Borrow Rate (TWAR). 

## Background

Element Finance recently announced a new [governance framework](https://medium.com/element-finance/an-introduction-to-elements-governance-model-efea13d1c7ee) that aims to provide similar security guarantees of existing frameworks, while allowing for increased flexibility. 

Voting Vaults are one aspect of this new governance design. The current process for on-chain voting usually observes a 1 governance token: 1 vote paradigm. This architecture limits the ability for governance token holders to utilize their tokens as financial assets. Voting Vaults expand upon the existing model, and allow for arbitrary logic to be executed when assigning voting power to users. Examples of voting vaults can be found in [Element's Council github](https://github.com/element-fi/council). This repo contains a Voting Vault that assigns voting power to cTokens (assuming Element's future token were to be listed on Compound). 

## Vault Details
This vault serves as a proxy to Compound's system and handles the logic of depositing & withdrawing gov tokens. Most notably, the vault exposes a `queryVotePower` function that the core governance contract will call to determine the voting power a user receives from this vault. Compound is external to the governance system, and thus represents a leakage of governance tokens. Someone could lend out their Element token to receive cElement, and then borrow the Element token from Compound to essentially "double spend" a governance vote. 

To prevent this, we leverage the borrow utilization rate of cElement to weight the voting power of a cToken appropriately. To mitigate governance attacks that invovle manipulating this borrow rate, we utilize the Time-weighted Average Borrow Rate (TWAR). TWAR operates similarly to [Uniswap's TWAP](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/oracles). Thus, when the borrow rate is high (meaning more Element tokens have been borrowed), cTokens have less voting power (and vice-versa). 

## Build Repo
This repo uses Hardhat for both compiling & testing. You can fork the repo and run `npm install` to install all dependencies, and then run `npm run build` and `npm run test`. 

## Improvements
The design space for Voting Vaults is still nascent, and using the TWAR is only way of mitigating governance attacks. There may be a cleaner solution, and indeed other attack vectors that we have not considered here. 

## Disclaimer
When/if appropriate, the changes represented in this repo will be opened as a PR in Element Finance's Council repo, where they will undergo review by Element core team members. The contracts in this repo as they are now should not be deployed to production without more thorough review. 
