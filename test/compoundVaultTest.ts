import "module-alias/register";

import { expect } from "chai";
import { ethers, network, waffle } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { BigNumberish, BigNumber } from "ethers";
import { CompoundVault } from "typechain/CompoundVault";
import { MockERC20 } from "typechain/MockERC20";
import { createSnapshot, restoreSnapshot } from "./helpers/snapshots";

const { provider } = waffle;

describe("Compound Vault", function () {
    let vault: CompoundVault;
    let token: MockERC20;
    const [wallet] = provider.getWallets();
    let signers: SignerWithAddress[];
    const one = ethers.utils.parseEther("1");
    const zeroAddress = "0x0000000000000000000000000000000000000000";

    
});

