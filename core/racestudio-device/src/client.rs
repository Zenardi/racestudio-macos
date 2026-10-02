//! The live download client (issue #179): drive one MyChron conversation over
//! any byte stream — a `TcpStream` in the app, an in-process fake device in the
//! tests.
//!
//! [`DeviceClient::handshake`] replays the opening the AiM app performs (hello,
//! session-open with the client clock, the three info reads), then
//! [`DeviceClient::list_sessions`] reads the catalog and
//! [`DeviceClient::download`] reads one session file and inflates it to `.xrk`.
//! Every exchange is the transaction documented on [`crate::command`]; the chunk
//! loop reuses [`download_session`] so chunk verification, offset reassembly,
//! retry and stall budgets are shared with the 6.5 path.
//!
//! The client sends only read commands. Nothing it can send modifies what the
//! device stores.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::catalog::{parse_catalog, session_path, Catalog};
use crate::command::{
    build_ack, build_catalog_request, build_clock_upload, build_close, build_hello,
    build_read_file, build_read_request, build_session_open, is_device_hello, opcode, parse_echo,
    tag, CommandEcho,
};
use crate::error::DeviceError;
use crate::framing::verified_frame;
use crate::session::SessionDate;
use crate::stream::read_frame;
use crate::transfer::{download_session, inflate_session, DownloadPlan, ProgressSink, Transport};
use crate::{transfer_chunk_data, transfer_chunk_offset};

/// The clock the client hands the device when it opens a session: the local
/// wall-clock time and the same instant in UTC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceClock {
    /// The local time.
    pub local: SessionDate,
    /// The same instant in UTC.
    pub utc: SessionDate,
}

/// A shared flag that stops a running exchange. The transport owner also closes
/// the socket so a blocked read returns; the client then reports
/// [`DeviceError::Cancelled`] rather than the socket error.
#[derive(Debug, Clone, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    /// A token that has not been cancelled.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Ask every exchange holding this token to stop.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Has [`Self::cancel`] been called?
    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// The largest reply accepted for the session-open and info reads (observed:
/// 4268, 12816, 2728 and 500 bytes). A hostile header must not drive a large
/// reassembly allocation.
const SMALL_REPLY_LIMIT: u32 = 1024 * 1024;

/// The largest catalog accepted (observed: 7698 bytes for 60 sessions).
const CATALOG_LIMIT: u32 = 8 * 1024 * 1024;

/// The largest session file accepted; [`download_session`] bounds it again.
const FILE_LIMIT: u32 = u32::MAX;

/// A progress sink that ignores every sample (the handshake and catalog reads).
struct NoProgress;

impl ProgressSink for NoProgress {
    fn on_progress(&mut self, _bytes_done: u64, _total: u64) {}
}

/// One open conversation with a MyChron.
pub struct DeviceClient<S> {
    stream: S,
    cancel: CancelToken,
}

impl<S: Read + Write> DeviceClient<S> {
    /// Open a conversation on `stream`: hello, session-open with `clock`, then
    /// the info reads, discarding their replies.
    ///
    /// # Errors
    /// [`DeviceError::UnexpectedResponse`] when the device's hello or an echo is
    /// not the observed one; any socket or frame error.
    pub fn handshake(
        stream: S,
        clock: &DeviceClock,
        cancel: CancelToken,
    ) -> Result<Self, DeviceError> {
        let mut client = DeviceClient { stream, cancel };
        client.send(&build_hello())?;
        let hello = client.receive()?;
        if !is_device_hello(verified_frame(&hello)?.payload) {
            return Err(DeviceError::UnexpectedResponse);
        }
        let upload = build_clock_upload(&clock.local, &clock.utc);
        client.transact(
            &build_session_open(),
            opcode::SESSION_OPEN,
            Some(&upload),
            SMALL_REPLY_LIMIT,
            &mut NoProgress,
        )?;
        for code in opcode::INFO {
            client.transact(
                &build_read_request(code),
                code,
                None,
                SMALL_REPLY_LIMIT,
                &mut NoProgress,
            )?;
        }
        Ok(client)
    }

    /// Read the catalog of stored sessions.
    ///
    /// # Errors
    /// Any exchange error, or [`DeviceError::MalformedRecord`] when the catalog
    /// has no usable header.
    pub fn list_sessions(&mut self) -> Result<Catalog, DeviceError> {
        let csv = self.transact(
            &build_catalog_request(),
            opcode::CATALOG,
            None,
            CATALOG_LIMIT,
            &mut NoProgress,
        )?;
        parse_catalog(&csv)
    }

    /// Download the stored session `file_name` and inflate it to the `.xrk` the
    /// decoder reads, reporting progress in stored (compressed) bytes.
    ///
    /// # Errors
    /// [`DeviceError::InvalidPath`] for a file name the catalog could not have
    /// listed; [`DeviceError::UnexpectedResponse`] when the device answers with
    /// an empty file (no session is empty); any exchange error;
    /// [`DeviceError::CorruptArchive`] when the download does not inflate. No
    /// partial file is ever returned.
    pub fn download(
        &mut self,
        file_name: &str,
        progress: &mut dyn ProgressSink,
    ) -> Result<Vec<u8>, DeviceError> {
        let request = build_read_file(&session_path(file_name)?)?;
        let stored = self.transact(&request, opcode::READ_FILE, None, FILE_LIMIT, progress)?;
        if stored.is_empty() {
            return Err(DeviceError::UnexpectedResponse);
        }
        inflate_session(&stored)
    }

    /// End the conversation politely. The device sends no reply.
    ///
    /// # Errors
    /// A socket error while sending the close command.
    pub fn close(mut self) -> Result<(), DeviceError> {
        self.send(&build_close())
    }

    /// Run one command transaction and return the response bytes, refusing a
    /// declared response longer than `limit` before anything is allocated.
    fn transact(
        &mut self,
        request: &[u8],
        code: u32,
        upload: Option<&[u8]>,
        limit: u32,
        progress: &mut dyn ProgressSink,
    ) -> Result<Vec<u8>, DeviceError> {
        self.send(request)?;
        match upload {
            Some(data) => {
                self.expect_echo(code, tag::REQUEST)?;
                self.send(data)?;
                // The device acknowledges the upload with a bare u32.
                if verified_frame(&self.receive()?)?.payload.len() != 4 {
                    return Err(DeviceError::UnexpectedResponse);
                }
            }
            None => {
                self.expect_echo(code, tag::ACCEPTED)?;
            }
        }
        let header = self.expect_echo(code, tag::RESPONSE_HEADER)?;
        if header.length > limit {
            return Err(DeviceError::MalformedRecord);
        }
        let plan = DownloadPlan {
            session_id: code,
            total_len: u64::from(header.length),
            whole_file_checksum: None,
        };
        let mut chunks = AckingTransport {
            client: self,
            next_offset: 0,
        };
        download_session(&plan, &mut chunks, progress)
    }

    /// Read the next frame and require it to be `code`'s echo with `tag`.
    fn expect_echo(&mut self, code: u32, tag: u32) -> Result<CommandEcho, DeviceError> {
        let raw = self.receive()?;
        let echo = parse_echo(verified_frame(&raw)?.payload)?;
        if echo.code != code || echo.tag != tag {
            return Err(DeviceError::UnexpectedResponse);
        }
        Ok(echo)
    }

    fn send(&mut self, frame: &[u8]) -> Result<(), DeviceError> {
        self.check_cancelled()?;
        let sent = self
            .stream
            .write_all(frame)
            .and_then(|()| self.stream.flush());
        sent.map_err(|err| self.socket_error(err))
    }

    fn receive(&mut self) -> Result<Vec<u8>, DeviceError> {
        self.check_cancelled()?;
        read_frame(&mut self.stream).map_err(|err| {
            if self.cancel.is_cancelled() {
                DeviceError::Cancelled
            } else {
                err
            }
        })
    }

    fn check_cancelled(&self) -> Result<(), DeviceError> {
        if self.cancel.is_cancelled() {
            Err(DeviceError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// A socket failure, reported as a cancellation when the caller cancelled
    /// (closing the socket is how a blocked read is woken).
    fn socket_error(&self, err: std::io::Error) -> DeviceError {
        if self.cancel.is_cancelled() {
            DeviceError::Cancelled
        } else {
            err.into()
        }
    }
}

/// Feeds [`download_session`]: before each chunk it sends the ACK naming the
/// offset it still needs. A chunk that fails its checksum leaves the offset
/// where it was, so the next ACK asks for it again.
struct AckingTransport<'a, S> {
    client: &'a mut DeviceClient<S>,
    next_offset: u32,
}

impl<S: Read + Write> Transport for AckingTransport<'_, S> {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, DeviceError> {
        self.client.send(&build_ack(self.next_offset))?;
        let raw = self.client.receive()?;
        if let Ok(frame) = verified_frame(&raw) {
            let offset = transfer_chunk_offset(frame.payload);
            let len = transfer_chunk_data(frame.payload).map(<[u8]>::len);
            if let (Some(offset), Some(len)) = (offset, len) {
                if offset == self.next_offset {
                    let len = u32::try_from(len).map_err(|_| DeviceError::MalformedRecord)?;
                    self.next_offset = offset.saturating_add(len);
                }
            }
        }
        Ok(Some(raw))
    }
}
