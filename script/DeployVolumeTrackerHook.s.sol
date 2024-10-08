// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {VolumeTrackerHook, PoolKey} from "src/VolumeTrackerHook.sol";
import {NarrativeController} from "src/NarrativeController.sol";
import {HookMiner} from "test/utils/HookMiner.sol";

contract DeployVolumeTrackerHook is Script, Deployers {
    uint256 deployerPrivateKey = vm.envUint("deployerPrivateKey");
    address internal deployer = vm.addr(deployerPrivateKey);
    PoolKey poolKey;
    address create2DeployerProxy = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    MockERC20 OK;
    PoolManager poolManager = PoolManager(0x75E7c1Fd26DeFf28C7d1e82564ad5c24ca10dB14);
    PoolSwapTest poolSwapTest = PoolSwapTest(0xB8b53649b87F0e1eb3923305490a5cB288083f82);
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency = Currency.wrap(address(OK));
    VolumeTrackerHook hook;

    PoolModifyLiquidityTest poolModifyLiquidityRouter =
        PoolModifyLiquidityTest(0x2b925D1036E2E17F79CF9bB44ef91B95a3f9a084);

    function run() public {
        vm.startBroadcast(deployerPrivateKey);
        console2.log("Deploying $OK");
        OK = new MockERC20("OK Token", "OK", 18);
        console2.log("Deployed $OK at address", address(OK));
        tokenCurrency = Currency.wrap(address(OK));

        (address hookAddress, bytes32 salt) = findAddress(address(create2DeployerProxy));
        bytes memory deployBytecode = type(VolumeTrackerHook).creationCode;
        console2.log("Deploying VolumeTrackerHook");
        require(deployBytecode.length != 0, "VolumeTrackerHook bytecode not found");

        hook = new VolumeTrackerHook{salt: salt}(poolManager, "", 1, address(OK), deployer);
        console2.log("Deployed VolumeTrackerHook at address", address(hook));
        require(hookAddress == address(hook), "VolumeTrackerHook address mismatch");

        console2.log("Initialize Pool");
        poolKey = PoolKey(ethCurrency, tokenCurrency, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);

        console2.log("Mint OK tokens for adding liquidity");
        OK.mint(deployer, 1000 ether);
        OK.approve(address(poolModifyLiquidityRouter), type(uint256).max);
        OK.approve(address(poolSwapTest), type(uint256).max);

        console2.log("Adding liquidity to the pool");
        poolModifyLiquidityRouter.modifyLiquidity{value: 0.5 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function findAddress(address deployer_) public view returns (address, bytes32) {
        console2.log("finding address");
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer_,
            flags,
            type(VolumeTrackerHook).creationCode,
            abi.encode(address(poolManager), "", 1, address(OK), deployer)
        );

        console2.log("found address", hookAddress);
        console2.logBytes32(salt);

        return (hookAddress, salt);
    }
}
