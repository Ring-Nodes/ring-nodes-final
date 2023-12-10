// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../../contracts/interfaces/INode.sol";

abstract contract NodeImplementationPointer is Ownable {
    INode internal Node;

    event UpdateNode(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    modifier onlyNode() {
        require(
            address(Node) != address(0),
            "Implementations: Node is not set"
        );
        address sender = _msgSender();
        require(
            sender == address(Node),
            "Implementations: Not Node"
        );
        _;
    }

    function getNodeImplementation() public view returns (address) {
        return address(Node);
    }

    function changeNodeImplementation(address newImplementation)
        public
        virtual
        onlyOwner
    {
        address oldImplementation = address(Node);
        require(
            Address.isContract(newImplementation) ||
                newImplementation == address(0),
            "Node: You can only set 0x0 or a contract address as a new implementation"
        );
        Node = INode(newImplementation);
        emit UpdateNode(oldImplementation, newImplementation);
    }

    uint256[49] private __gap;
}