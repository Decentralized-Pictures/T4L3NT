// SPDX-FileCopyrightText: 2022-2023 TriliTech <contact@trili.tech>
// SPDX-FileCopyrightText: 2023 Nomadic Labs <contact@nomadic-labs.com>
// SPDX-FileCopyrightText: 2023 Marigold <contact@marigold.dev>
//
// SPDX-License-Identifier: MIT

//! Michelson-ticket encoding.

use crate::{
    contract::Contract,
    michelson::{
        Michelson, MichelsonBytes, MichelsonContract, MichelsonInt, MichelsonPair,
        MichelsonString, MichelsonUnit,
    },
};
use core::{
    cmp::Ordering,
    fmt::{Display, Formatter, Result as FmtResult},
};
use crypto::blake2b::{digest_256, Blake2bError};
use hex::FromHexError;
use nom::combinator::map;
use num_bigint::BigInt;
use num_traits::Signed;
use std::fmt::Debug;
use tezos_data_encoding::{
    enc::{BinError, BinResult, BinWriter},
    encoding::HasEncoding,
    nom::{NomReader, NomResult},
    types::{SizedBytes, Zarith},
};
use thiserror::Error;

#[cfg(feature = "testing")]
pub mod testing;

/// The length of a Tezos ticket ID
pub const TICKET_HASH_SIZE: usize = 32;

/// The hash of a string ticket - identifying a ticket by creator and contents.
#[derive(Clone, PartialEq, Eq, NomReader, BinWriter, HasEncoding)]
pub struct TicketHash {
    inner: SizedBytes<TICKET_HASH_SIZE>,
}

impl PartialOrd for TicketHash {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        self.inner.as_ref().partial_cmp(other.inner.as_ref())
    }
}

impl Ord for TicketHash {
    fn cmp(&self, other: &Self) -> Ordering {
        self.inner.as_ref().cmp(other.inner.as_ref())
    }
}

impl Debug for TicketHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TicketId(")?;
        for &byte in self.inner.as_ref() {
            write!(f, "{:02x?}", byte)?;
        }
        write!(f, ")")
    }
}

impl Display for TicketHash {
    fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
        write!(f, "{}", hex::encode(&self.inner))
    }
}

#[allow(clippy::from_over_into)]
impl Into<String> for TicketHash {
    fn into(self) -> String {
        hex::encode(self.inner)
    }
}

impl TryFrom<String> for TicketHash {
    type Error = FromHexError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let mut result = Self {
            inner: SizedBytes([0; TICKET_HASH_SIZE]),
        };
        hex::decode_to_slice(value, result.inner.as_mut())?;
        Ok(result)
    }
}

/// Errors occurring when identifying tickets.
#[derive(Error, Debug)]
pub enum TicketHashError {
    /// Unable to serialize ticket creator and contents.
    #[error("Unable to serialize ticket for hashing: {0}")]
    Serialization(#[from] BinError),
    /// Unable to hash serialized ticket.
    #[error("Unable to hash ticket bytes: {0}")]
    Hashing(#[from] Blake2bError),
}

/// Errors occurring when identifying tickets.
#[derive(Error, Debug, Clone)]
pub enum TicketError {
    /// Invalid amount in ticket repr.
    #[error("ticket amount out of range")]
    InvalidAmount(BigInt),
}

// Expr is guarantee by construction to implement `Michelson` even though
// rust does not enforce it in type aliases `type TicketRepr<Expr: Michelson>`.
type TicketRepr<Expr> =
    MichelsonPair<MichelsonContract, MichelsonPair<Expr, MichelsonInt>>;

/// Michelson ticket representative.
#[derive(Debug, PartialEq, Eq)]
pub struct Ticket<Expr: Michelson>(pub TicketRepr<Expr>);

impl<Expr: Michelson> Michelson for Ticket<Expr> {}

impl<Expr: Michelson> NomReader for Ticket<Expr> {
    fn nom_read(bytes: &[u8]) -> NomResult<Self> {
        map(<TicketRepr<Expr>>::nom_read, Ticket)(bytes)
    }
}

impl<Expr: Michelson> BinWriter for Ticket<Expr> {
    fn bin_write(&self, output: &mut Vec<u8>) -> BinResult {
        self.0.bin_write(output)
    }
}

impl<Expr: Michelson> HasEncoding for Ticket<Expr> {
    fn encoding() -> tezos_data_encoding::encoding::Encoding {
        <TicketRepr<Expr>>::encoding()
    }
}

impl<Expr: Michelson> Ticket<Expr> {
    /// creates a new ticket with `creator`, `contents` and `amount`.
    pub fn new<Val: Into<Expr>, Amount: Into<BigInt>>(
        creator: Contract,
        contents: Val,
        amount: Amount,
    ) -> Result<Self, TicketError> {
        let amount: BigInt = amount.into();
        if amount.is_positive() {
            Ok(Ticket(MichelsonPair(
                MichelsonContract(creator),
                MichelsonPair(contents.into(), MichelsonInt(Zarith(amount))),
            )))
        } else {
            Err(TicketError::InvalidAmount(amount))
        }
    }

    /// Return an identifying hash of the ticket creator and contents.
    ///
    /// Calculated as the `blake2b` hash of a tezos-encoded `obj2`:
    /// - creator contract
    /// - string contents
    pub fn hash(&self) -> Result<TicketHash, TicketHashError> {
        let mut bytes = Vec::new();
        self.creator().bin_write(&mut bytes)?;
        self.contents().bin_write(&mut bytes)?;

        let digest = digest_256(bytes.as_slice())?;
        let digest: [u8; TICKET_HASH_SIZE] = digest.try_into().unwrap();

        Ok(TicketHash {
            inner: SizedBytes(digest),
        })
    }

    /// The L1 ticketer's address.
    pub fn creator(&self) -> &MichelsonContract {
        &self.0 .0
    }
    /// The ticket's content
    pub fn contents(&self) -> &Expr {
        &self.0 .1 .0
    }
    /// The ticket's amount
    pub fn amount(&self) -> &BigInt {
        &self.0 .1 .1 .0 .0
    }

    /// same as `amount()` but returns it as a `T`
    pub fn amount_as<T: TryFrom<BigInt, Error = E>, E>(&self) -> Result<T, E> {
        self.amount().to_owned().try_into()
    }
}

/// Specialized version of ticket where the content must be an int
pub type IntTicket = Ticket<MichelsonInt>;

/// Specialized version of ticket where the content must be a string
pub type StringTicket = Ticket<MichelsonString>;

impl Ticket<MichelsonString> {
    /// clone used in testing
    #[cfg(feature = "testing")]
    pub fn testing_clone(&self) -> Self {
        Ticket(MichelsonPair(
            MichelsonContract(self.creator().0.clone()),
            MichelsonPair(
                MichelsonString(self.contents().0.clone()),
                MichelsonInt(Zarith(self.amount().clone())),
            ),
        ))
    }
}

/// Specialized version of ticket where the content must be byte
pub type BytesTicket = Ticket<MichelsonBytes>;

/// Specialized version of ticket where the content must be unit
pub type UnitTicket = Ticket<MichelsonUnit>;

#[cfg(test)]
mod test {
    use super::*;
    use tezos_data_encoding::enc::BinWriter;
    use tezos_data_encoding::nom::NomReader;

    #[test]
    fn content_bytes() {
        let ticket = BytesTicket::new(
            Contract::from_b58check("KT1NgXQ6Mwu3XKFDcKdYFS6dkkY3iNKdBKEc").unwrap(),
            MichelsonBytes(vec![1, 2, 3, 4, 5]),
            500,
        )
        .unwrap();

        assert_encode_decode(ticket);
    }

    #[test]
    fn content_string() {
        let ticket = StringTicket::new(
            Contract::from_b58check("KT1NgXQ6Mwu3XKFDcKdYFS6dkkY3iNKdBKEc").unwrap(),
            MichelsonString("Hello, Ticket".to_string()),
            900,
        )
        .unwrap();

        assert_encode_decode(ticket);
    }

    #[test]
    fn content_unit() {
        let ticket = UnitTicket::new(
            Contract::from_b58check("KT1NgXQ6Mwu3XKFDcKdYFS6dkkY3iNKdBKEc").unwrap(),
            MichelsonUnit,
            900,
        )
        .unwrap();

        assert_encode_decode(ticket);
    }

    #[test]
    fn content_int() {
        let ticket = IntTicket::new::<i32, i32>(
            Contract::from_b58check("KT1NgXQ6Mwu3XKFDcKdYFS6dkkY3iNKdBKEc").unwrap(),
            -25,
            900,
        )
        .unwrap();

        assert_encode_decode(ticket);
    }

    #[test]
    fn content_pair() {
        type NestedPair = MichelsonPair<
            MichelsonUnit,
            MichelsonPair<MichelsonPair<MichelsonString, MichelsonBytes>, MichelsonInt>,
        >;
        let ticket: Ticket<NestedPair> = Ticket::new::<_, i32>(
            Contract::from_b58check("KT1NgXQ6Mwu3XKFDcKdYFS6dkkY3iNKdBKEc").unwrap(),
            MichelsonPair(
                MichelsonUnit,
                MichelsonPair(
                    MichelsonPair(
                        MichelsonString("hello".to_string()),
                        MichelsonBytes(b"a series of bytes".to_vec()),
                    ),
                    MichelsonInt::from(19),
                ),
            ),
            17,
        )
        .unwrap();

        assert_encode_decode(ticket);
    }

    fn assert_encode_decode<T: Michelson>(ticket: Ticket<T>) {
        let mut bin = Vec::new();
        ticket.bin_write(&mut bin).unwrap();

        let (remaining, parsed) = Ticket::nom_read(&bin).unwrap();

        assert_eq!(ticket, parsed);
        assert!(remaining.is_empty());
    }
}
