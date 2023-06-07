use evm_execution::storage::blocks::EvmBlockStorageError;
use evm_execution::EthereumError;
use host::runtime::RuntimeError;
use rlp::DecoderError;
use tezos_data_encoding::nom::error::DecodeError;
use tezos_ethereum::signatures::TransactionError;
use thiserror::Error;
// TODO:  https://gitlab.com/tezos/tezos/-/issues/5557
// to be replaced by anyhow

/// Anything that can go wrong on the application level
#[derive(Error, Debug)]
pub enum ApplicationError<'a> {
    /// Error parsing inbox message
    #[error("unable to parse header inbox message {0}")]
    MalformedInboxMessage(nom::Err<DecodeError<&'a [u8]>>),
    /// Error happened during interaction with the storage
    #[error("EVM storage failed: {0}")]
    EvmStorage(#[from] EvmBlockStorageError),
    /// Error fetching rollup metadata from host
    #[error("Failed to fetch rollup metadata: {0:?}")]
    FailedToFetchRollupMetadata(RuntimeError),
    /// Error executing ethereum transaction
    #[error("Failed to execute ethereum transaction: {0:?}")]
    EthereumError(#[from] EthereumError),
    /// Error parsing inbox message
    #[error("unable to parse header inbox message {0}")]
    MalformedRlpTransaction(DecoderError),
    /// Error executing ethereum transaction
    #[error("Failed to use transaction operations: {0:?}")]
    TransactionError(#[from] TransactionError),
}
