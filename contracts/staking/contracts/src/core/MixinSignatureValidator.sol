/*
  Copyright 2018 ZeroEx Intl.
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

pragma solidity ^0.5.5;

import "@0x/contracts-utils/contracts/src/LibBytes.sol";
import "../interfaces/IStructs.sol";
import "../interfaces/IWallet.sol";
import "../immutable/MixinConstants.sol";


contract MixinSignatureValidator is
    IStructs,
    MixinConstants
{
    using LibBytes for bytes;

    /// @dev Verifies that a hash has been signed by the given signer.
    /// @param hash Any 32 byte hash.
    /// @param signerAddress Address that should have signed the given hash.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if the address recovered from the provided signature matches the input signer address.
    function _isValidSignature(
        bytes32 hash,
        address signerAddress,
        bytes memory signature
    )
        internal
        view
        returns (bool isValid)
    {
        require(
            signature.length > 0,
            "LENGTH_GREATER_THAN_0_REQUIRED"
        );

        // Pop last byte off of signature byte array.
        uint8 signatureTypeRaw = uint8(signature.popLastByte());

        // Ensure signature is supported
        require(
            signatureTypeRaw < uint8(SignatureType.NSignatureTypes),
            "SIGNATURE_UNSUPPORTED"
        );

        SignatureType signatureType = SignatureType(signatureTypeRaw);

        // Variables are not scoped in Solidity.
        uint8 v;
        bytes32 r;
        bytes32 s;
        address recovered;

        // Always illegal signature.
        // This is always an implicit option since a signer can create a
        // signature array with invalid type or length. We may as well make
        // it an explicit option. This aids testing and analysis. It is
        // also the initialization value for the enum type.
        if (signatureType == SignatureType.Illegal) {
            revert("SIGNATURE_ILLEGAL");

        // Always invalid signature.
        // Like Illegal, this is always implicitly available and therefore
        // offered explicitly. It can be implicitly created by providing
        // a correctly formatted but incorrect signature.
        } else if (signatureType == SignatureType.Invalid) {
            require(
                signature.length == 0,
                "LENGTH_0_REQUIRED"
            );
            isValid = false;
            return isValid;

        // Signature using EIP712
        } else if (signatureType == SignatureType.EIP712) {
            require(
                signature.length == 65,
                "LENGTH_65_REQUIRED"
            );
            v = uint8(signature[0]);
            r = signature.readBytes32(1);
            s = signature.readBytes32(33);
            recovered = ecrecover(
                hash,
                v,
                r,
                s
            );
            isValid = signerAddress == recovered;
            return isValid;

        // Signed using web3.eth_sign
        } else if (signatureType == SignatureType.EthSign) {
            require(
                signature.length == 65,
                "LENGTH_65_REQUIRED"
            );
            v = uint8(signature[0]);
            r = signature.readBytes32(1);
            s = signature.readBytes32(33);
            recovered = ecrecover(
                keccak256(abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    hash
                )),
                v,
                r,
                s
            );
            isValid = signerAddress == recovered;
            return isValid;

        // Signature verified by wallet contract.
        // If used with an order, the maker of the order is the wallet contract.
        } else if (signatureType == SignatureType.Wallet) {
            isValid = _isValidWalletSignature(
                hash,
                signerAddress,
                signature
            );
            return isValid;
        }

        // Anything else is illegal (We do not return false because
        // the signature may actually be valid, just not in a format
        // that we currently support. In this case returning false
        // may lead the caller to incorrectly believe that the
        // signature was invalid.)
        revert("SIGNATURE_UNSUPPORTED");
    }

    /// @dev Verifies signature using logic defined by Wallet contract.
    /// @param hash Any 32 byte hash.
    /// @param walletAddress Address that should have signed the given hash
    ///                      and defines its own signature verification method.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if signature is valid for given wallet..
    function _isValidWalletSignature(
        bytes32 hash,
        address walletAddress,
        bytes memory signature
    )
        internal
        view
        returns (bool isValid)
    {
        // contruct hash as bytes, so that it is a valid EIP-1271 payload
        bytes memory hashAsBytes = new bytes(32);
        assembly {
            mstore(add(hashAsBytes, 32), hash)
        }

        // Static call `isValidSignature` in the destination wallet
        bytes memory callData = abi.encodeWithSelector(
            IWallet(walletAddress).isValidSignature.selector,
            hash,
            signature
        );
        (bool success, bytes memory result) = walletAddress.staticcall(callData);

        // Sanity check call and extract the magic value
        require(
            success,
            "WALLET_ERROR"
        );
        bytes4 magicValue = result.readBytes4(0);

        isValid = (magicValue == EIP1271_MAGIC_VALUE);
        return isValid;
    }
}