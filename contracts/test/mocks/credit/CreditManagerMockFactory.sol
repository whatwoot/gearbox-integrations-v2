// SPDX-License-Identifier: UNLICENSED
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import { ContractsRegister } from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import { PriceOracle } from "@gearbox-protocol/core-v2/contracts/oracles/PriceOracle.sol";
import { Adapter } from "../../../factories/CreditManagerFactory.sol";

import { IConvexV1BaseRewardPoolAdapter } from "../../../interfaces/convex/IConvexV1BaseRewardPoolAdapter.sol";
import { IConvexV1BoosterAdapter } from "../../../interfaces/convex/IConvexV1BoosterAdapter.sol";

import { PoolService } from "@gearbox-protocol/core-v2/contracts/pool/PoolService.sol";
import { CreditManagerLiveMock } from "./CreditManagerLiveMock.sol";
import { CreditFacade } from "@gearbox-protocol/core-v2/contracts/credit/CreditFacade.sol";
import { CreditConfigurator, CreditManagerOpts } from "@gearbox-protocol/core-v2/contracts/credit/CreditConfigurator.sol";

import { ContractUpgrader } from "@gearbox-protocol/core-v2/contracts/support/ContractUpgrader.sol";

import "@gearbox-protocol/core-v2/contracts/interfaces/adapters/IAdapter.sol";

/// @title CreditManagerFactory
/// @notice Deploys 3 core interdependent contracts: CreditManage, CreditFacade and CredigConfigurator
///         and setup them by following options
contract CreditManagerMockFactory is ContractUpgrader {
    CreditManagerLiveMock public creditManager;
    CreditFacade public creditFacade;
    CreditConfigurator public creditConfigurator;
    PoolService public immutable pool;

    Adapter[] public adapters;

    constructor(
        address _pool,
        CreditManagerOpts memory opts,
        uint256 salt
    ) ContractUpgrader(address(PoolService(_pool).addressProvider())) {
        pool = PoolService(_pool);

        creditManager = new CreditManagerLiveMock(_pool);
        creditFacade = new CreditFacade(
            address(creditManager),
            opts.degenNFT,
            opts.expirable
        );

        bytes memory configuratorByteCode = abi.encodePacked(
            type(CreditConfigurator).creationCode,
            abi.encode(creditManager, creditFacade, opts)
        );

        address creditConfiguratorAddr = getAddress(configuratorByteCode, salt);

        creditManager.setConfigurator(creditConfiguratorAddr);

        deploy(configuratorByteCode, salt);

        creditConfigurator = CreditConfigurator(creditConfiguratorAddr);

        require(
            address(creditConfigurator.creditManager()) ==
                address(creditManager),
            "Incorrect CM"
        );
    }

    function getAddress(bytes memory bytecode, uint256 _salt)
        public
        view
        returns (address)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt,
                keccak256(bytecode)
            )
        );

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint256(hash)));
    }

    function deploy(bytes memory bytecode, uint256 _salt) public payable {
        address addr;

        /*
        NOTE: How to call create2

        create2(v, p, n, s)
        create new contract with code at memory p to p + n
        and send v wei
        and return the new address
        where new address = first 20 bytes of keccak256(0xff + address(this) + s + keccak256(mem[p…(p+n)))
              s = big-endian 256-bit value
        */
        assembly {
            addr := create2(
                callvalue(), // wei sent with current call
                // Actual code starts after skipping the first 32 bytes
                add(bytecode, 0x20),
                mload(bytecode), // Load the size of code contained in the first 32 bytes
                _salt // Salt from function arguments
            )

            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
    }

    /// @dev adds adapters to public array to provide ability for DAO to
    /// check the list before running configure command
    function addAdapters(Adapter[] memory _adapters) external onlyOwner {
        uint256 len = _adapters.length;
        for (uint256 i = 0; i < len; ) {
            adapters.push(_adapters[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _configure() internal override {
        ContractsRegister cr = ContractsRegister(
            addressProvider.getContractsRegister()
        );

        PriceOracle priceOracle = PriceOracle(addressProvider.getPriceOracle());

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; ) {
            creditConfigurator.allowContract(
                adapters[i].targetContract,
                adapters[i].adapter
            );
            unchecked {
                ++i;
            }
        }

        cr.addCreditManager(address(creditManager)); // T:[PD-2]

        pool.connectCreditManager(address(creditManager));

        address[] memory allowedContracts = creditConfigurator
            .allowedContracts();
        len = allowedContracts.length;

        for (uint256 i = 0; i < len; ) {
            address allowedContract = allowedContracts[i];
            address adapter = creditManager.contractToAdapter(allowedContract);
            AdapterType aType = IAdapter(adapter)._gearboxAdapterType();

            if (aType == AdapterType.CONVEX_V1_BASE_REWARD_POOL) {
                address stakedPhantomToken = IConvexV1BaseRewardPoolAdapter(
                    adapter
                ).stakedPhantomToken();

                address curveLPtoken = IConvexV1BaseRewardPoolAdapter(adapter)
                    .curveLPtoken();
                address cvxLPToken = address(
                    IConvexV1BaseRewardPoolAdapter(adapter).stakingToken()
                );

                priceOracle.addPriceFeed(
                    cvxLPToken,
                    priceOracle.priceFeeds(curveLPtoken)
                );

                priceOracle.addPriceFeed(
                    stakedPhantomToken,
                    priceOracle.priceFeeds(curveLPtoken)
                );

                creditConfigurator.addCollateralToken(
                    stakedPhantomToken,
                    creditManager.liquidationThresholds(curveLPtoken)
                ); // F:
            }

            if (aType == AdapterType.CONVEX_V1_BOOSTER) {
                IConvexV1BoosterAdapter(adapter).updateStakedPhantomTokensMap();
            }

            unchecked {
                ++i;
            }
        }
    }
}
