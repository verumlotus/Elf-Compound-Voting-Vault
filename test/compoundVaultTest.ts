import "module-alias/register";

import { expect } from "chai";
import { ethers, network, waffle } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { BigNumberish, BigNumber } from "ethers";
import { CompoundVault } from "typechain/CompoundVault";
import { MockERC20 } from "typechain/MockERC20";
import { MockCToken } from "typechain/MockCToken";
import { MockComptroller } from "typechain/MockComptroller";
import { createSnapshot, restoreSnapshot } from "./helpers/snapshots";

const { provider } = waffle;

describe("Compound Vault", function () {
    let vault: CompoundVault;
    let underlying: MockERC20;
    let cToken: MockCToken;
    let comptroller: MockComptroller;
    const [wallet] = provider.getWallets();
    let signers: SignerWithAddress[];
    const one = ethers.utils.parseEther("1");
    const zeroAddress = "0x0000000000000000000000000000000000000000";
    // margin of error for checking retur values
    // set to 0.01% due to solidity vs JS math differences
    const marginOfError = 10000;
    // 1 cToken is worth 0.5 underlying
    const cTokenToUnderlyingRate = 0.5;
    const underlyingToCTokenRate = 2;

    const calcVotePowerFromUnderlying = (underlyingAmount: BigNumber) => {
      const twarMultiplier = ethers.utils.parseEther("0.9");
      return underlyingAmount.mul(twarMultiplier).div(one);
    };

    const assertBigNumberWithinRange = (actualVal: BigNumber, expectedVal: BigNumber) => {
      const upperBound: BigNumber = expectedVal.add(expectedVal.div(marginOfError));
      const lowerBound: BigNumber = expectedVal.sub(expectedVal.div(marginOfError));
      expect(actualVal).to.be.lte(upperBound);
      expect(actualVal).to.be.gte(lowerBound);
    }

    before(async function() {
        // Create a before snapshot
        await createSnapshot(provider);
        signers = await ethers.getSigners();
        // deploy the underlying token;
        const erc20Deployer = await ethers.getContractFactory(
            "MockERC20",
            signers[0]
        );
        underlying = await erc20Deployer.deploy("Ele test", "Ele", signers[0].address);

        // deploy the cToken token;
        const cTokenDeployer = await ethers.getContractFactory(
            "MockCToken",
            signers[0]
        );
        cToken = await cTokenDeployer.deploy("cEle", "cEle test", signers[0].address, underlying.address);

        // deploy a comptroller
        const comptrollerDeployer = await ethers.getContractFactory(
            "MockComptroller", 
            signers[0]
        );
        comptroller = await comptrollerDeployer.deploy();

        // deploy the contract
        const deployer = await ethers.getContractFactory(
            "CompoundVault",
            signers[0]
        );
        vault = await deployer.deploy(underlying.address, cToken.address, comptroller.address, 86400, 199350, 30);

        // Give users some balance and set their allowance
        for (const signer of signers) {
            await underlying.setBalance(signer.address, ethers.utils.parseEther("100000"));
            await underlying.setAllowance(
                signer.address,
                vault.address,
                ethers.constants.MaxUint256
            );
        }
    });

  // After we reset our state in the fork
  after(async () => {
    await restoreSnapshot(provider);
  });
  // Before each we snapshot
  beforeEach(async () => {
    await createSnapshot(provider);
  });
  // After we reset our state in the fork
  afterEach(async () => {
    await restoreSnapshot(provider);
  });

  describe("Deposit Sequence", async () => {
    beforeEach(async () => {
      await createSnapshot(provider);
    });
    // After we reset our state in the fork
    afterEach(async () => {
      await restoreSnapshot(provider);
    });
    // Test the deposit by user for user
    it("Allows a user's first deposit to set gov power", async () => {
      // Before each we snapshot
      // Deposit by calling from address 0 and delegating to address 1
      const tx = await (
        await vault.deposit(signers[0].address, one, signers[1].address)
      ).wait();
      const votingPower = await vault.callStatic.queryVotePowerView(
        signers[1].address,
        tx.blockNumber
      );
      const expectedVotingPower = calcVotePowerFromUnderlying(one);
      assertBigNumberWithinRange(votingPower, expectedVotingPower);
      // expect user 0 to have a deposits
      let userData = await vault.deposits(signers[0].address);
      expect(userData[0]).to.be.eq(signers[1].address);
      expect(userData[1]).to.be.eq(one.mul(underlyingToCTokenRate));
      // expect address 1/2 to have zero deposit
      userData = await vault.deposits(signers[1].address);
      expect(userData[0]).to.be.eq(zeroAddress);
      expect(userData[1]).to.be.eq(0);
      userData = await vault.deposits(signers[2].address);
      expect(userData[0]).to.be.eq(zeroAddress);
      expect(userData[1]).to.be.eq(0);
    });
  });
    
});

