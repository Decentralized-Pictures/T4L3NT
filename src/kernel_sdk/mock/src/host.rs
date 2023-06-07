// SPDX-FileCopyrightText: 2022-2023 TriliTech <contact@trili.tech>
// SPDX-FileCopyrightText: 2023 Marigold <contact@marigold.dev>
// SPDX-FileCopyrightText: 2022-2023 Nomadic Labs <contact@nomadic-labs.com>
//
// SPDX-License-Identifier: MIT

//! Contains an implementation of [SmartRollupCore] suitable for running the
//! kernel standalone for experiements and testing purposes. Used when
//! _not_ compiling to **wasm**.

use crate::state::{HostState, NextInput};
use crate::MockHost;
use core::{
    cell::RefCell,
    ptr,
    slice::{from_raw_parts, from_raw_parts_mut},
};
use tezos_smart_rollup_core::smart_rollup_core::{ReadInputMessageInfo, SmartRollupCore};
use tezos_smart_rollup_core::PREIMAGE_HASH_SIZE;
use tezos_smart_rollup_host::metadata::METADATA_SIZE;
use tezos_smart_rollup_host::Error;

impl From<HostState> for MockHost {
    fn from(state: HostState) -> Self {
        Self {
            info: super::info_for_level(state.curr_level as i32),
            state: RefCell::new(state),
        }
    }
}

impl AsMut<HostState> for MockHost {
    fn as_mut(&mut self) -> &mut HostState {
        self.state.get_mut()
    }
}

unsafe impl SmartRollupCore for MockHost {
    unsafe fn read_input(
        &self,
        message_info: *mut ReadInputMessageInfo,
        dst: *mut u8,
        max_bytes: usize,
    ) -> i32 {
        if let Some(NextInput { level, id, payload }) =
            self.state.borrow_mut().handle_read_input(max_bytes)
        {
            let input_message_info = ReadInputMessageInfo {
                level: level as i32,
                id: id as i32,
            };
            ptr::write(message_info, input_message_info);

            // safe as payload.len() <= max_bytes
            let slice = from_raw_parts_mut(dst, payload.len());
            slice.copy_from_slice(payload.as_slice());

            payload.len().try_into().unwrap()
        } else {
            0_i32
        }
    }

    unsafe fn write_debug(&self, src: *const u8, num_bytes: usize) {
        let debug_out = from_raw_parts(src, num_bytes).to_vec();

        let debug = String::from_utf8(debug_out).expect("unexpected non-utf8 debug log");

        eprintln!("DEBUG: {}", &debug);
    }

    unsafe fn write_output(&self, src: *const u8, num_bytes: usize) -> i32 {
        let output = from_raw_parts(src, num_bytes).to_vec();

        self.state
            .borrow_mut()
            .handle_write_output(output)
            .map(|_| 0)
            .unwrap_or_else(Error::code)
    }

    unsafe fn store_has(&self, path: *const u8, len: usize) -> i32 {
        let path = from_raw_parts(path, len);
        self.state
            .borrow()
            .handle_store_has(path)
            .unwrap_or_else(Error::code)
    }

    unsafe fn store_read(
        &self,
        path: *const u8,
        len: usize,
        offset: usize,
        dst: *mut u8,
        max_bytes: usize,
    ) -> i32 {
        let path = from_raw_parts(path, len);

        let bytes = self
            .state
            .borrow()
            .handle_store_read(path, offset, max_bytes);

        match bytes {
            Ok(bytes) => {
                assert!(bytes.len() <= max_bytes);

                let slice = from_raw_parts_mut(dst, bytes.len());
                slice.copy_from_slice(bytes.as_slice());

                bytes.len().try_into().unwrap()
            }
            Err(e) => e.code(),
        }
    }

    unsafe fn store_write(
        &self,
        path: *const u8,
        len: usize,
        offset: usize,
        src: *const u8,
        num_bytes: usize,
    ) -> i32 {
        let path = from_raw_parts(path, len);
        let bytes = from_raw_parts(src, num_bytes);

        self.state
            .borrow_mut()
            .handle_store_write(path, offset, bytes)
            .map(|_| 0)
            .unwrap_or_else(Error::code)
    }

    unsafe fn store_delete(&self, path: *const u8, len: usize) -> i32 {
        let path = from_raw_parts(path, len);

        self.state
            .borrow_mut()
            .handle_store_delete(path)
            .map(|_| 0)
            .unwrap_or_else(Error::code)
    }

    unsafe fn store_list_size(&self, path: *const u8, len: usize) -> i64 {
        let path = from_raw_parts(path, len);

        self.state
            .borrow()
            .handle_store_list_size(path)
            .unwrap_or_else(|e| e.code() as i64)
    }

    unsafe fn store_move(
        &self,
        from_path: *const u8,
        from_path_len: usize,
        to_path: *const u8,
        to_path_len: usize,
    ) -> i32 {
        let from_path = from_raw_parts(from_path, from_path_len);
        let to_path = from_raw_parts(to_path, to_path_len);

        self.state
            .borrow_mut()
            .handle_store_move(from_path, to_path)
            .map(|_| 0)
            .unwrap_or_else(Error::code)
    }

    unsafe fn store_copy(
        &self,
        from_path: *const u8,
        from_path_len: usize,
        to_path: *const u8,
        to_path_len: usize,
    ) -> i32 {
        let from_path = from_raw_parts(from_path, from_path_len);
        let to_path = from_raw_parts(to_path, to_path_len);

        self.state
            .borrow_mut()
            .handle_store_copy(from_path, to_path)
            .map(|_| 0)
            .unwrap_or_else(Error::code)
    }

    unsafe fn reveal_preimage(
        &self,
        hash_addr: *const u8,
        hash_len: usize,
        destination_addr: *mut u8,
        max_bytes: usize,
    ) -> i32 {
        // only `Reveal_hash` supported for now.
        let hash = from_raw_parts(hash_addr, hash_len)
            .try_into()
            .unwrap_or_else(|_| panic!("Hash is not {} bytes", PREIMAGE_HASH_SIZE));

        let bytes = self
            .state
            .borrow()
            .handle_reveal_preimage(&hash, max_bytes)
            .to_vec();

        assert!(bytes.len() <= max_bytes);

        let slice = from_raw_parts_mut(destination_addr, bytes.len());
        slice.copy_from_slice(bytes.as_slice());

        bytes.len().try_into().unwrap()
    }

    unsafe fn store_value_size(&self, path: *const u8, path_len: usize) -> i32 {
        let path = from_raw_parts(path, path_len);
        self.state
            .borrow()
            .handle_store_value_size(path)
            .unwrap_or_else(Error::code)
    }

    unsafe fn reveal_metadata(&self, destination_addr: *mut u8, max_bytes: usize) -> i32 {
        assert!(METADATA_SIZE <= max_bytes);
        let metadata: [u8; METADATA_SIZE] =
            self.state.borrow().get_metadata().clone().into();
        let slice = from_raw_parts_mut(destination_addr, metadata.len());
        slice.copy_from_slice(metadata.as_slice());
        metadata.len().try_into().unwrap()
    }
}

#[cfg(test)]
mod tests {

    use super::MockHost;

    use crate::state::HostState;
    use tezos_smart_rollup_core::MAX_INPUT_MESSAGE_SIZE;
    use tezos_smart_rollup_host::input::Message;
    use tezos_smart_rollup_host::{
        metadata::RollupMetadata,
        path::RefPath,
        runtime::{Runtime, RuntimeError},
    };

    #[test]
    fn test_read_input_message() {
        // Arrange
        let mut mock_host = MockHost::default();

        mock_host
            .as_mut()
            .add_input(vec![5; MAX_INPUT_MESSAGE_SIZE / 2]);

        // Act
        let result = mock_host.read_input();

        // Assert
        let expected = Ok(Some(Message::new(
            mock_host.level(),
            0,
            vec![5; MAX_INPUT_MESSAGE_SIZE / 2],
        )));

        assert_eq!(expected, result);
    }

    #[test]
    fn test_reveal_preimage() {
        // Arrange
        let mut state = HostState::default();

        let data = vec![b'a'; 3 * 1024];

        let hash = state.set_preimage(data);

        let mock_host = MockHost::from(state);

        let mut buffer = [0; 300];
        // Act
        let _result = mock_host.reveal_preimage(&hash, &mut buffer);

        // Assert

        assert_eq!(buffer, [b'a'; 300]);
    }

    #[test]
    fn test_reveal_metadata() {
        // Arrange

        let metadata_bytes = [
            // sr1 as 20 bytes
            b'M', 165, 28, b']', 231, 161, 205, 212, 148, 193, b'[', b'S', 129, b'^', 31,
            170, b'L', 26, 150, 202, // origination level as 4 bytes
            0, 0, 0, 42,
        ];

        let expected_metadata = RollupMetadata::from(metadata_bytes);
        let state = HostState::default_with_metadata(expected_metadata.clone());
        let mock_host = MockHost::from(state); // Act

        // Act
        let result = mock_host.reveal_metadata().unwrap();

        // Assert
        assert_eq!(expected_metadata, result);
    }

    #[test]
    fn read_value_slice_not_found() {
        let mock = MockHost::default();
        const PATH: RefPath<'static> = RefPath::assert_from(b"/some/path");
        let mut buffer = [0_u8; 16];

        assert_eq!(
            mock.store_read_slice(&PATH, 0, &mut buffer),
            Err(RuntimeError::HostErr(
                tezos_smart_rollup_host::Error::StoreNotAValue
            ))
        );
    }

    #[test]
    fn read_value_slice_partial_buffer_fill() {
        let mut mock = MockHost::default();
        const PATH: RefPath<'static> = RefPath::assert_from(b"/some/path");
        let value = [1_u8; 8];
        let mut buffer = [0_u8; 16];

        mock.store_write(&PATH, &value, 0)
            .expect("Could not write value to store");

        assert_eq!(mock.store_read_slice(&PATH, 0, &mut buffer), Ok(8_usize));

        assert_eq!(buffer, [1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn read_value_slice_complete_buffer_fill() {
        let mut mock = MockHost::default();
        const PATH: RefPath<'static> = RefPath::assert_from(b"/some/path");
        let value = [1_u8; 16];
        let mut buffer = [0_u8; 16];

        mock.store_write(&PATH, &value, 0)
            .expect("Could not write value to store");

        assert_eq!(mock.store_read_slice(&PATH, 0, &mut buffer), Ok(16_usize));

        assert_eq!(buffer, [1_u8; 16]);
    }

    #[test]
    fn test_store_write() {
        let mut state = HostState::default();
        let size = 256_i32;
        let data = vec![b'a'; size as usize];
        let path = b"/a/b";

        state.handle_store_write(path, 0, &data).unwrap();
        let value_size = state.handle_store_value_size(path).unwrap();

        assert_eq!(size, value_size)
    }
}
