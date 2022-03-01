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

    before(async function() {
        // Create a before snapshot
        await createSnapshot(provider);
        signers = await ethers.getSigners();
        // deploy the underlying token;
        const erc20Deployer = await ethers.getContractFactory(
            "MockERC20",
            signers[0]
        );
        underlying = await erc20Deployer.deploy("Ele", "test ele", signers[0].address);

        // deploy the cToken token;
        const cTokenDeployer = await ethers.getContractFactory(
            "MockCToken",
            signers[0]
        );
        cToken = await cTokenDeployer.deploy("cEle", "cEle test", signers[0].address, underlying.address);

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
});

