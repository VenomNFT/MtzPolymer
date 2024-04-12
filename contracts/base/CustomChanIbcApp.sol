//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.9;

import "@open-ibc/vibc-core-smart-contracts/contracts/libs/Ibc.sol";
import "@open-ibc/vibc-core-smart-contracts/contracts/interfaces/IbcReceiver.sol";
import "@open-ibc/vibc-core-smart-contracts/contracts/interfaces/IbcDispatcher.sol";
import "@open-ibc/vibc-core-smart-contracts/contracts/interfaces/ProofVerifier.sol";

// CustomChanIbcApp is a contract that can be used as a base contract
// for IBC-enabled contracts that send packets over a custom IBC channel.
contract CustomChanIbcApp is IbcReceiverBase, IbcReceiver {
    // received packet as chain B
    IbcPacket[] public recvedPackets;
    // received ack packet as chain A
    AckPacket[] public ackPackets;
    // received timeout packet as chain A
    IbcPacket[] public timeoutPackets;
    string public constant VERSION = "1.0";

    struct ChannelMapping {
        bytes32 channelId;
        bytes32 cpChannelId;
    }

    // ChannelMapping array with the channel IDs of the connected channels
    bytes32[] public connectedChannels;

    // add supported versions (format to be negotiated between apps)
    string[] supportedVersions = ["1.0"];

    constructor(IbcDispatcher _dispatcher) IbcReceiverBase(_dispatcher) {}

    function updateDispatcher(IbcDispatcher _dispatcher) external onlyOwner {
        dispatcher = _dispatcher;
    }

    function getConnectedChannels() external view returns (bytes32[] memory) {
        return connectedChannels;
    }

    function updateSupportedVersions(string[] memory _supportedVersions) external onlyOwner {
        supportedVersions = _supportedVersions;
    }

    /**
     * @dev Implement a function to send a packet that calls the dispatcher.sendPacket function
     *      It has the following function handle:
     *          function sendPacket(bytes32 channelId, bytes calldata payload, uint64 timeoutTimestamp) external;
     */

    /**
     * @dev Packet lifecycle callback that implements packet receipt logic and returns and acknowledgement packet.
     *      MUST be overriden by the inheriting contract.
     *
     * @param packet the IBC packet encoded by the source and relayed by the relayer.
     */
    function onRecvPacket(IbcPacket memory packet)
        external
        virtual
        onlyIbcDispatcher
        returns (AckPacket memory ackPacket)
    {
        recvedPackets.push(packet);
        // do logic
        return AckPacket(true, abi.encodePacked('{ "account": "account", "reply": "got the message" }'));
    }

    /**
     * @dev Packet lifecycle callback that implements packet acknowledgment logic.
     *      MUST be overriden by the inheriting contract.
     *
     * @param packet the IBC packet encoded by the source and relayed by the relayer.
     * @param ack the acknowledgment packet encoded by the destination and relayed by the relayer.
     */
    function onAcknowledgementPacket(IbcPacket calldata packet, AckPacket calldata ack)
        external
        virtual
        onlyIbcDispatcher
    {
        ackPackets.push(ack);
        // do logic
    }

    /**
     * @dev Packet lifecycle callback that implements packet receipt logic and return and acknowledgement packet.
     *      MUST be overriden by the inheriting contract.
     *      NOT SUPPORTED YET
     *
     * @param packet the IBC packet encoded by the counterparty and relayed by the relayer
     */
    function onTimeoutPacket(IbcPacket calldata packet) external virtual onlyIbcDispatcher {
        timeoutPackets.push(packet);
        // do logic
    }

    /**
     * @dev Create a custom channel between two IbcReceiver contracts
     * @param local a ChannelEnd struct with the local chain's portId and version (channelId can be empty)
     * @param ordering the channel ordering (NONE, UNORDERED, ORDERED) equivalent to (0, 1, 2)
     * @param feeEnabled in production, you'll want to enable this to avoid spamming create channel calls (costly for relayers)
     * @param connectionHops 2 connection hops to connect to the destination via Polymer
     * @param counterparty the address of the destination chain contract you want to connect to
     */
    function createChannel(
        string calldata local,
        uint8 ordering,
        bool feeEnabled,
        string[] calldata connectionHops,
        string calldata counterparty
    ) external virtual onlyOwner {
        dispatcher.channelOpenInit(local, ChannelOrder(ordering), feeEnabled, connectionHops, counterparty);
    }

    function onOpenIbcChannel(
        string calldata version,
        ChannelOrder,
        bool,
        string[] calldata,
        ChannelEnd calldata counterparty
    ) external view virtual onlyIbcDispatcher returns (string memory selectedVersion) {
        if (bytes(counterparty.portId).length <= 8) {
            revert IBCErrors.invalidCounterPartyPortId();
        }
        /**
         * Version selection is determined by if the callback is invoked on behalf of ChanOpenInit or ChanOpenTry.
         * ChanOpenInit: self version should be provided whereas the counterparty version is empty.
         * ChanOpenTry: counterparty version should be provided whereas the self version is empty.
         * In both cases, the selected version should be in the supported versions list.
         */
        bool foundVersion = false;
        selectedVersion =
            keccak256(abi.encodePacked(version)) == keccak256(abi.encodePacked("")) ? counterparty.version : version;
        for (uint256 i = 0; i < supportedVersions.length; i++) {
            if (keccak256(abi.encodePacked(selectedVersion)) == keccak256(abi.encodePacked(supportedVersions[i]))) {
                foundVersion = true;
                break;
            }
        }
        require(foundVersion, "Unsupported version");
        // if counterpartyVersion is not empty, then it must be the same foundVersion
        if (keccak256(abi.encodePacked(counterparty.version)) != keccak256(abi.encodePacked(""))) {
            require(
                keccak256(abi.encodePacked(counterparty.version)) == keccak256(abi.encodePacked(selectedVersion)),
                "Version mismatch"
            );
        }

        // do logic

        return selectedVersion;
    }

    function onConnectIbcChannel(bytes32 channelId, bytes32 counterpartyChannelId, string calldata counterpartyVersion)
        external
        virtual
        onlyIbcDispatcher
    {
        // ensure negotiated version is supported
        bool foundVersion = false;
        for (uint256 i = 0; i < supportedVersions.length; i++) {
            if (keccak256(abi.encodePacked(counterpartyVersion)) == keccak256(abi.encodePacked(supportedVersions[i]))) {
                foundVersion = true;
                break;
            }
        }
        require(foundVersion, "Unsupported version");

        // do logic

        ChannelMapping memory channelMapping =
            ChannelMapping({channelId: channelId, cpChannelId: counterpartyChannelId});
        connectedChannels.push(channelId);
    }

    function onCloseIbcChannel(bytes32 channelId, string calldata, bytes32) external virtual onlyIbcDispatcher {
        // logic to determin if the channel should be closed
        bool channelFound = false;
        for (uint256 i = 0; i < connectedChannels.length; i++) {
            if (connectedChannels[i] == channelId) {
                for (uint256 j = i; j < connectedChannels.length - 1; j++) {
                    connectedChannels[j] = connectedChannels[j + 1];
                }
                connectedChannels.pop();
                channelFound = true;
                break;
            }
        }
        require(channelFound, "Channel not found");

        // do logic
    }

    /**
     * This func triggers channel closure from the dApp.
     * Func args can be arbitary, as long as dispatcher.closeIbcChannel is invoked propperly.
     */
    function triggerChannelClose(bytes32 channelId) external virtual onlyOwner {
        dispatcher.closeIbcChannel(channelId);
    }

    /*
    IbcChannelReceiver Interface Functions
    */

    function onChanOpenInit(string calldata version) external override returns (string memory selectedVersion) {
        // do logic
        return _openChannel(version);
    }

    function onChanOpenTry(string calldata counterpartyVersion)
        external
        pure
        override
        returns (string memory selectedVersion)
    {
        // do logic
        return _openChannel(counterpartyVersion);
    }

    function onChanOpenAck(bytes32 channelId, string calldata counterpartyVersion) external override {
        // do logic
        _connectChannel(channelId, counterpartyVersion);
    }

    function onChanOpenConfirm(bytes32 channelId, string calldata counterpartyVersion) external override {
        // do logic
        _connectChannel(channelId, counterpartyVersion);
    }

    function _connectChannel(bytes32 channelId, string calldata version) private {
        if (keccak256(abi.encodePacked(version)) != keccak256(abi.encodePacked(VERSION))) {
            revert UnsupportedVersion();
        }
        connectedChannels.push(channelId);
    }

    function _openChannel(string calldata version) private pure returns (string memory selectedVersion) {
        if (keccak256(abi.encodePacked(version)) != keccak256(abi.encodePacked(VERSION))) {
            revert UnsupportedVersion();
        }
        return VERSION;
    }
}
