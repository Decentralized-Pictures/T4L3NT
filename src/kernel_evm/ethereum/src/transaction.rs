// SPDX-FileCopyrightText: 2023 Nomadic Labs <contact@nomadic-labs.com>
//
// SPDX-License-Identifier: MIT

use crate::address::EthereumAddress;
use primitive_types::{H160, H256, U256};

pub const TRANSACTION_HASH_SIZE: usize = 32;
pub type TransactionHash = [u8; TRANSACTION_HASH_SIZE];

pub enum TransactionType {
    Legacy,
    Eip2930,
    Eip1559,
}

#[derive(PartialEq)]
pub enum TransactionStatus {
    Success,
    Failure,
}

pub enum TransactionStatusDecodingError {
    InvalidEncoding,
    InvalidVectorLength,
}

impl TryFrom<&u8> for TransactionStatus {
    type Error = TransactionStatusDecodingError;

    fn try_from(v: &u8) -> Result<Self, Self::Error> {
        if *v == 0 {
            Ok(Self::Failure)
        } else if *v == 1 {
            Ok(Self::Success)
        } else {
            Err(TransactionStatusDecodingError::InvalidEncoding)
        }
    }
}

impl TryFrom<&Vec<u8>> for TransactionStatus {
    type Error = TransactionStatusDecodingError;

    fn try_from(v: &Vec<u8>) -> Result<Self, Self::Error> {
        if v.len() == 1 {
            TransactionStatus::try_from(&v[0])
        } else {
            Err(TransactionStatusDecodingError::InvalidVectorLength)
        }
    }
}

/// Transaction receipt, see https://ethereum.org/en/developers/docs/apis/json-rpc/#eth_gettransactionreceipt
pub struct TransactionReceipt {
    /// Hash of the transaction.
    pub hash: TransactionHash,
    /// Integer of the transactions index position in the block.
    pub index: u32,
    /// Hash of the block where this transaction was in.
    pub block_hash: H256,
    /// Block number where this transaction was in.
    pub block_number: U256,
    /// Address of the sender.
    pub from: EthereumAddress,
    /// Address of the receiver. null when its a contract creation transaction.
    pub to: Option<EthereumAddress>,
    /// The total amount of gas used when this transaction was executed in the block
    pub cumulative_gas_used: U256,
    /// The sum of the base fee and tip paid per unit of gas.
    pub effective_gas_price: U256,
    /// The amount of gas used by this specific transaction alone.
    pub gas_used: U256,
    /// The contract address created, if the transaction was a contract creation, otherwise null.
    pub contract_address: Option<H160>,
    // The two following fields can be ignored for now
    // pub logs : unit,
    // pub logs_bloom : unit,
    pub type_: TransactionType,
    /// Transaction status
    pub status: TransactionStatus,
}

#[allow(clippy::from_over_into)]
impl Into<&'static [u8]> for &TransactionType {
    fn into(self) -> &'static [u8] {
        match self {
            TransactionType::Legacy => [0u8].as_slice(),
            TransactionType::Eip2930 => [1u8].as_slice(),
            TransactionType::Eip1559 => [2u8].as_slice(),
        }
    }
}

#[allow(clippy::from_over_into)]
impl Into<&'static [u8]> for &TransactionStatus {
    fn into(self) -> &'static [u8] {
        match self {
            TransactionStatus::Success => [1u8].as_slice(),
            TransactionStatus::Failure => [0u8].as_slice(),
        }
    }
}
